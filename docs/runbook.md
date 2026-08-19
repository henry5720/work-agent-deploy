# Work Agent Runbook

Local與deployment host共用同一份 Compose及runtime設定。State與草稿都放在本 repo的 `runtime/`；
兩邊都要建立 root `.env`，指定 snapshot root與執行 docker的使用者 uid/gid。

Deployment host是實體 Linux host，Compose以維護者自己的帳號執行，不需要sudo。該帳號必須在`docker` group裡，
並且host要有Git、SSH client、Python 3、curl、jq與cron。SELinux enforcing的host不需要額外設定，Compose的
bind mount已經帶`:z`。

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

Local不掛開發用的 checkout，而是自己建一份乾淨 snapshot，避免把各 repo的 `.env` 掛進 container：

```bash
cd "$HOME/code/work-agent-deploy"

test -f .env || cp .env.example .env
sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/; s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env

test -f env/openab.env || cp env/openab.env.example env/openab.env
chmod 600 env/openab.env
$EDITOR env/openab.env

# Local用自己的 GitHub key即可，不必另外產一把。
GITHUB_SSH_KEY="$HOME/.ssh/<你的 GitHub key>" ./scripts/update-snapshots.sh
mkdir -p runtime/openab runtime/drafts

./tests/static.sh
./scripts/preflight.sh
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

Root `.env` 只給 Compose用（snapshot root與 uid）；`env/openab.env` 才會傳進 container。
`.env`、`env/openab.env` 與 `runtime/` 都不進 Git。Claude login存在 named volume
`claude-credentials`，重建 container後仍保留。

在 Slack確認：

1. DM詢問一個 repo問題。
2. 在 `#你為什麼不問問神奇海螺ㄋ` @ bot建立一筆實際要保留的待辦，確認指派給sender並保存來源。
3. 再次要求建立同名待辦，確認沒有新增第二列。
4. 在待辦列的 item留言串 @ bot，確認它能找到正確的 `Rec...`。

停止 local instance：

```bash
docker compose down
```

## 3. Deployment Host 首次部署

### GitHub 讀取權限

建立只能讀 snapshots的 SSH key：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/work-agent-github -C work-agent@deployment-host
chmod 600 ~/.ssh/work-agent-github
cat ~/.ssh/work-agent-github.pub
```

把 public key加到能讀 `config/repos.conf` 內所有 private repos的 GitHub account。
Private key只留在 host，不得放進 repo、Docker env或 container。

```bash
ssh -T -i ~/.ssh/work-agent-github -o IdentitiesOnly=yes git@github.com
```

### 安裝

```bash
cd "$HOME/code/work-agent-deploy"

test -f .env || cp .env.example .env
sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/; s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env

test -f env/openab.env || cp env/openab.env.example env/openab.env
chmod 600 env/openab.env
$EDITOR env/openab.env

./scripts/install-sync-cron.sh
./scripts/deploy.sh
docker compose exec backlog-agent claude auth login
docker compose logs --tail=100 backlog-agent
```

`install-sync-cron.sh` 會建立 snapshot root與 repo內的 `runtime/`、寫入每小時一次的 crontab entry，並跑第一次同步。
`deploy.sh` 會先執行 preflight，再 build及啟動 container。

### 驗證安全邊界

```bash
docker compose ps
crontab -l | grep work-agent-snapshots
docker compose exec backlog-agent sh -lc \
  'python3 --version >/dev/null &&
   /home/node/code/work-helper/bin/slack-list --help >/dev/null &&
   test -w /home/node/.openab &&
   test -w /home/node/drafts &&
   test ! -w /home/node/code/teamsync-frontend &&
   test ! -w /home/node/code/teamsync-backend &&
   test -d /home/node/.claude/skills/slack-todo &&
   test ! -e /home/node/.ssh &&
   test ! -e /home/node/.config/gh &&
   ! gh auth status >/dev/null 2>&1 &&
   codegraph explore boot -p /home/node/code/work-helper >/dev/null'
```

`test -w` 這幾項是SELinux label與uid都正確才會過的，Compose render成功不代表通過。

`gh` 這個 binary本身存在於 OpenAB base image內，拿掉它不是這裡的邊界。邊界是它沒有任何憑證，
加上 `managed-claude-settings.json` 的 `Bash(gh *)` deny規則。上面驗的是憑證，不是 binary。

接著重做 local段落的 Slack測試，再確認未授權帳號的訊息不會被處理。

## 4. 日常操作

不要直接在 deployment host修改repo檔案。所有設定與文件都先在local修改、commit及push；host只執行`git pull --ff-only`與部署命令。

更新部署：

```bash
cd "$HOME/code/work-agent-deploy"
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
crontab -l | grep work-agent-snapshots
tail -n 50 "${XDG_STATE_HOME:-$HOME/.local/state}/work-agent/snapshots.log"
./scripts/update-snapshots.sh
```

`update-snapshots.sh` 同步完會用 runtime image重建 CodeGraph索引，所以 host不需要安裝 Node。
索引放在 `$SNAPSHOT_ROOT/.index/<repo>`，每個 snapshot內的 `.codegraph` 是指過去的相對 symlink。
第一次部署時 image還沒 build，那一輪的索引會被跳過並印出訊息，`deploy.sh` 之後再跑一次同步即可。

停止 agent：

```bash
docker compose down
```

不要執行 `docker compose down -v`，它會刪除 Claude login。`runtime/` 不會被 `down` 刪除。

### 更新或新增 Skill

`/home/node/.claude/skills` 是 `work-helper/.claude/skills` 整個目錄的 read-only mount。修改或新增 skill只要 commit並 push到
`work-helper` 的 `main`，下一次同步（每小時）之後就會生效，**不需要改這個 repo，也不需要重新 build或 deploy**。

要立即生效就在 host上執行 `./scripts/update-snapshots.sh`。

第三方 skill在 work-helper用 `npx skills add <repo> -s <skill> -a claude-code --copy` 安裝，來源與 hash記在
`work-helper/skills-lock.json`，更新用 `npx skills update -p`。**一定要 `--copy`**：預設的 symlink會指到
mount範圍以外，在 container內是斷的。

唯一需要改這個 repo的情況：新 skill在這個環境跑不動（需要 `gh`、`git worktree`、可寫 repo或 local 專用工具），
或它的行為會撞到 Slack回覆規則。那要在 `agents/CLAUDE.md` 的「Skill 邊界」寫明，否則 agent會在 Slack上嘗試然後失敗。

已啟動的Claude session可能已把舊skill內容讀進context。同步後使用新的Slack thread或等待session回收再驗證，不用以舊session判斷同步失敗。

### 新增唯讀 Repo

新增repo會擴大backlog agent可讀資料的範圍，必須當成能力與權限變更review。整個 snapshot root是單一 mount，所以只改一個檔案：

| 正本 | 要改什麼 |
|---|---|
| `config/repos.conf` | 新增一行 `name\|SSH remote\|基準branch` |

Snapshot key對應的GitHub帳號必須先取得新repo的read權限。Push deployment repo後，在host執行：

```bash
git pull --ff-only
./scripts/update-snapshots.sh
./scripts/preflight.sh
./scripts/deploy.sh
```

`preflight.sh` 會擋下 snapshot root裡出現不在 `config/repos.conf` 的目錄，避免有東西被掛進 container卻沒有經過review。

最後依「驗證安全邊界」確認所有repo snapshot不可寫、drafts可寫，並從新的Slack thread詢問新repo內容。
