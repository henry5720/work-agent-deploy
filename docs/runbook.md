# Work Agent Runbook

Local與deployment host共用同一份 Compose及runtime設定。State與草稿都放在本 repo的 `runtime/`；
Local用 root `.env` 掛載現有 repos，deployment host不建立 root `.env`，使用 `/srv/work-agent/repos`。

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
docker compose pull
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
  'test ! -w /home/node/code/teamsync-frontend &&
   test ! -w /home/node/code/teamsync-backend &&
   test -w /home/node/drafts &&
   test ! -e /home/node/.ssh'
```

接著重做 local段落的三個 Slack測試，再確認未授權帳號的訊息不會被處理。

## 4. 日常操作

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
