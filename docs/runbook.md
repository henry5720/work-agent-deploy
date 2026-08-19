# Work Agent Runbook

Local與deployment host共用同一份 Compose及runtime設定。State與草稿都放在本 repo的 `runtime/`；
Local用 root `.env` 掛載現有 repos，deployment host不建立 root `.env`，使用 `/srv/work-agent/repos`。

正式的deployment host是restricted Incus container，不是實體host。Incus instance需啟用nesting與開機自動啟動，內部提供systemd、Docker Compose、Git、SSH client、Python 3、curl與jq。以下deployment host命令都在該instance內、以專用deployment user執行；實體host只負責啟停或進入Incus instance。

Incus instance必須有可用的IPv4 route與DNS，並能連線到GitHub、Slack、Claude及Linux套件來源。不要把實體host目錄bind mount進instance來傳遞credentials；secrets、snapshot key與Claude credential直接建立或匯入instance內。

## 1. 設定 Slack App

這只需做一次，local與deployment host共用。

1. 開啟 **Socket Mode**。
2. 建立 App-Level Token，scope選 `connections:write`，取得 `xapp-...`。
3. 開啟 **Event Subscriptions**，訂閱 bot events：`app_mention`、`message.groups`、`message.im`。
4. 到 **App Home** 開啟 **Messages Tab**，並允許使用者從 Messages Tab傳送訊息。
5. 加入 bot token scopes：

```text
app_mentions:read
chat:write
files:read
files:write
groups:history
groups:read
im:history
lists:read
lists:write
reactions:write
users:read
```

6. **Reinstall to Workspace**，取得新的 `xoxb-...`。
7. 只把 app邀進 `C0BPZRN6H3R` 與 `C0B9PSESQ2U`。

Socket Mode用 WebSocket接收 events，所以不用填 Event Subscriptions的 Request URL，也不用設定
Incoming Webhook。OpenAB使用 `xoxb-...` 透過 Slack Web API回覆訊息。

發布功能首頁給 `config/openab.toml` 內的授權使用者：

```bash
./scripts/publish-slack-home.sh
```

文案放在 `config/slack-home.json`。修改後重跑同一指令即可；不需要訂閱 `app_home_opened`。

授權使用者維護在 `config/openab.toml`。因 OpenAB目前需要 `allow_all_channels = true` 才能收 DM，
不可把 app邀進其他 channel，否則會擴大入口。

## 2. Local 首次啟動

同一個 Slack app同時只能跑一個 OpenAB instance；local測試前先停止正式 instance。

```bash
cd "$HOME/code/work-agent-deploy"

test -f .env || cp .env.example .env
test -f env/openab.env || cp env/openab.env.example env/openab.env
chmod 600 env/openab.env
$EDITOR env/openab.env

mkdir -p \
  runtime/openab \
  runtime/drafts

./tests/static.sh
docker compose build --pull
docker compose up -d
docker compose exec backlog-agent claude auth login
docker compose ps
docker compose logs --tail=100 backlog-agent
```

`env/openab.env` 至少要填入 `SLACK_BOT_TOKEN` 與 `SLACK_APP_TOKEN`，並保留：

```text
WORK_HELPER_ISSUE_MODE=manual
```

Root `.env` 只指定四個 repos的共同根目錄；`env/openab.env` 才會傳進 container。
`.env`、`env/openab.env` 與 `runtime/` 都不進 Git。Claude login存在 named volume
`claude-credentials`，重建 container後仍保留。

在 Slack確認：

1. DM詢問一個 repo問題。
2. 在 `#你為什麼不問問神奇海螺ㄋ` @ bot查待辦。
3. 在待辦列的 item留言串 @ bot，確認它能找到正確的 `Rec...`。

停止 local instance：

```bash
docker compose down
```

## 3. Deployment Host 首次部署

### GitHub 讀取權限

使用 deployment user建立只能讀 snapshots的 SSH key：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/work-agent-github -C work-agent@deployment-host
chmod 600 ~/.ssh/work-agent-github
cat ~/.ssh/work-agent-github.pub
```

把 public key加到能讀 `config/repos.conf` 內四個 private repos的 GitHub account。
Private key只留在 host，不得放進 repo、Docker env或 container。

```bash
ssh -T -i ~/.ssh/work-agent-github -o IdentitiesOnly=yes git@github.com
```

### 安裝

Deployment repo必須放在 `$HOME/code/work-agent-deploy`，而且不要建立 root `.env`。

```bash
cd "$HOME/code/work-agent-deploy"

./scripts/install-sync-timer.sh

test -f env/openab.env || cp env/openab.env.example env/openab.env
chmod 600 env/openab.env
$EDITOR env/openab.env

./scripts/deploy.sh
docker compose exec backlog-agent claude auth login
docker compose logs --tail=100 backlog-agent
```

`install-sync-timer.sh` 會建立 `/srv/work-agent/repos` 與 repo內的 `runtime/`、首次同步 repos並啟用每五分鐘一次的 timer。
`deploy.sh` 會先執行 preflight，再 pull及啟動 container。

### 驗證

```bash
docker compose ps
docker compose exec backlog-agent sh -lc \
  'python3 --version >/dev/null &&
   /home/node/code/work-helper/bin/slack-list --help >/dev/null &&
   test -w /home/node/.openab &&
   test ! -w /home/node/code/teamsync-frontend &&
   test ! -w /home/node/code/teamsync-backend &&
   test -w /home/node/drafts &&
   test ! -e /home/node/.ssh'
```

接著重做 local段落的三個 Slack測試，再確認未授權帳號的訊息不會被處理。

## 4. 日常操作

### 進入正式環境

Deployment repo在Incus instance內的 `/home/workagent/code/work-agent-deploy`，不會出現在實體host的deployment checkout。從有權管理restricted Incus project的帳號進入：

```bash
ssh -t <incus-manager> 'incus exec work-agent -- su - workagent'
cd "$HOME/code/work-agent-deploy"
```

不要直接在正式環境修改repo檔案。所有設定與文件都先在local修改、commit及push；正式環境只執行`git pull --ff-only`與部署命令。

更新部署：

```bash
git pull --ff-only
./tests/static.sh
./scripts/deploy.sh
```

查看 agent：

```bash
docker compose ps
docker compose logs -f --tail=200 backlog-agent
```

查看或立即更新 snapshots：

```bash
systemctl list-timers "work-agent-snapshots@$(id -un).timer"
sudo systemctl start "work-agent-snapshots@$(id -un).service"
sudo journalctl -u "work-agent-snapshots@$(id -un).service" -n 100 --no-pager
```

停止 agent：

```bash
docker compose down
```

不要執行 `docker compose down -v`，它會刪除 Claude login。`runtime/` 不會被 `down` 刪除。

### 更新既有 Skill

`slack-todo`與`fleet-recon`的正本在`work-helper/skills/`。修改後commit並push到`work-helper`的`main`；snapshot timer會在五分鐘內同步到`/srv/work-agent/repos/work-helper`，既有read-only bind mount會直接看到新內容，不需重新build或deploy。

要立即同步：

```bash
sudo systemctl start "work-agent-snapshots@$(id -un).service"
sudo journalctl -u "work-agent-snapshots@$(id -un).service" -n 100 --no-pager
```

已啟動的Claude session可能已把舊skill內容讀進context。同步後使用新的Slack thread或等待session回收再驗證，不用以舊session判斷同步失敗。

### 新增 Skill

新skill先加入`work-helper/skills/<skill-name>/`並push到`main`，再修改這個deployment repo：

| 正本 | 要改什麼 |
|---|---|
| `compose.yaml` | 將新skill目錄read-only mount到`/home/node/.claude/skills/<skill-name>` |
| `agents/CLAUDE.md` | 寫清楚什麼情況使用新skill |
| `tests/static.sh` | 驗證新mount存在且維持read-only |

新skill不會只因為出現在整份`work-helper` snapshot裡就自動註冊；必須有`/home/node/.claude/skills/`下的獨立mount。修改完成後push deployment repo，進入Incus instance執行：

```bash
git pull --ff-only
sudo systemctl start "work-agent-snapshots@$(id -un).service"
./tests/static.sh
./scripts/deploy.sh
```

### 新增唯讀 Repo

新增repo會擴大backlog agent可讀資料的範圍，必須當成能力與權限變更review。同步修改：

| 正本 | 要改什麼 |
|---|---|
| `config/repos.conf` | 新增SSH remote與基準branch |
| `compose.yaml` | 新增指向`/home/node/code/<repo>`的read-only snapshot mount |
| `config/openab.toml` | 需要簡短workspace名稱時新增alias |
| `agents/CLAUDE.md` | 加入工作路徑與必要的使用規則 |
| `docs/system-design.md` | 更新repo snapshots清單與能力邊界 |
| `tests/static.sh` | 驗證mount、branch及read-only要求 |
| 本runbook | 更新安全邊界驗證命令 |

Snapshot key對應的GitHub帳號必須先取得新repo的read權限。Push deployment repo後，在Incus instance執行：

```bash
git pull --ff-only
sudo systemctl start "work-agent-snapshots@$(id -un).service"
./scripts/preflight.sh
./scripts/deploy.sh
```

最後依「驗證」章節確認所有repo snapshot不可寫、drafts可寫，並從新的Slack thread詢問新repo內容。
