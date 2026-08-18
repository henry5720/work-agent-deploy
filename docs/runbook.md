# Deployment Host 部署手冊

## 1. 準備專用 GitHub SSH key

登入準備執行服務的 deployment user，建立一把只供 snapshot sync 使用的 key：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/work-agent-github -C work-agent@deployment-host
chmod 600 ~/.ssh/work-agent-github
cat ~/.ssh/work-agent-github.pub
ssh -T -i ~/.ssh/work-agent-github -o IdentitiesOnly=yes git@github.com
```

把 public key 加到一個能讀 `config/repos.conf` 內四個 private repos的 GitHub account。這裡不用單一 repo 的 deploy key，因為同一把 key要跨多個 repos。

Private key不得放進這個 repo、Docker env、volume或 container。

## 2. 放置部署 repo

systemd unit 固定使用：

```text
$HOME/code/work-agent-deploy
```

尚未發布 GitHub remote 前，可先從 local 安全傳到 deployment host；發布 private repo 後改用 host 的專用 SSH key clone。不要把 deploy repo 掛進 agent container。

## 3. 啟用 snapshot sync

```bash
cd "$HOME/code/work-agent-deploy"
./scripts/install-sync-timer.sh
systemctl list-timers "work-agent-snapshots@$(id -un).timer"
```

首次執行會建立：

```text
/srv/work-agent/repos/work-helper         main
/srv/work-agent/repos/work-docs           main
/srv/work-agent/repos/teamsync-frontend    dev
/srv/work-agent/repos/teamsync-backend     master
```

確認同步狀態：

```bash
sudo systemctl status "work-agent-snapshots@$(id -un).service"
sudo journalctl -u "work-agent-snapshots@$(id -un).service" -n 100 --no-pager
```

同步 script 會 fetch 所有 remote branches/tags，但 working snapshot只 reset到 `config/repos.conf` 指定 branch。這些目錄是機器產物，任何手動修改都會在下次同步被清掉。

## 4. 設定 Slack app

沿用 `work-helper` app，顯示名稱改成「派大星教授加博士先生」。

### Socket Mode

1. 開啟 Socket Mode。
2. 建立 app-level token，scope選 `connections:write`。
3. 保存新的 `xapp-...`。

### Bot events

- `app_mention`
- `message.groups`
- `message.im`

若未來要進 public channel，再加 `message.channels`。

### Bot token scopes

- `app_mentions:read`
- `chat:write`
- `files:read`
- `files:write`
- `groups:history`
- `groups:read`
- `im:history`
- `lists:read`
- `lists:write`
- `reactions:write`
- `users:read`

Scope或 event有變更後，必須 **Reinstall to Workspace** 並換掉舊 `xoxb-...`。

只把 app 邀進以下兩個 private channels：

- `C0BPZRN6H3R`，`#你為什麼不問問神奇海螺ㄋ`
- `C0B9PSESQ2U`，Bug/需求總表的 item 留言 backing channel

`config/openab.toml` 明列 `#神奇海螺` 目前五位人類成員：

```text
U0B54FKJ93R
U0B85LX4KKP
U0B8ASE0ARX
U0B8B04R57T
U0B8CNK8GNQ
```

OpenAB `0.10.0-beta.3` 把 channel allowlist同時套到 DM channel ID。DM ID事前未知，所以設定為 `allow_all_channels = true`，再用上述 user allowlist及「只邀進兩個 channel」限制入口。邀 app進其他 channel會擴大入口，不能當一般操作。

`assistant_mode = false`，因此不需要把 Slack app改成 AI app，也不需要 `assistant:write`。

## 5. 寫入 secrets

```bash
cd "$HOME/code/work-agent-deploy"
cp env/openab.env.example env/openab.env
chmod 600 env/openab.env
```

填入 `SLACK_BOT_TOKEN` 與 `SLACK_APP_TOKEN`。保留：

```text
WORK_HELPER_ISSUE_MODE=manual
```

不要加入 GitHub token、GitHub SSH key或 Anthropic API key。Claude Code subscription使用下一步的 device login。

## 6. 啟動與登入 Claude Code

```bash
./scripts/deploy.sh
docker compose exec backlog-agent claude auth login
```

Login資料存在 named volume `claude-credentials`，container重建後仍保留。不要把該 volume export進 repo或備份到不受控位置。

## 7. 驗證安全邊界

```bash
docker compose ps
docker compose exec backlog-agent sh -lc 'test ! -w /home/node/code/teamsync-frontend'
docker compose exec backlog-agent sh -lc 'test ! -w /home/node/code/teamsync-backend'
docker compose exec backlog-agent sh -lc 'test -w /home/node/code/work-helper/drafts'
docker compose exec backlog-agent sh -lc 'test ! -e /home/node/.ssh'
docker compose exec backlog-agent sh -lc 'gh auth status; test $? -ne 0'
```

接著依序測：

1. 授權使用者從 DM問一個只讀 repo問題。
2. 在 `#你為什麼不問問神奇海螺ㄋ` @ bot查待辦。
3. 在既有待辦列的 item 留言串 @ bot，確認它能用 sender context反查 `Rec...`。
4. 要求偵察一列，確認它只上傳 Markdown草稿與人工 GitHub連結，沒有建立 issue或改狀態。
5. 用不在 `allowed_users` 的帳號測試，確認 bot不處理訊息。

## 日常操作

更新部署設定：

```bash
git pull --ff-only
./tests/static.sh
./scripts/deploy.sh
```

看 log：

```bash
docker compose logs -f --tail=200 backlog-agent
```

手動更新 snapshots：

```bash
sudo systemctl start "work-agent-snapshots@$(id -un).service"
```

停止 agent不會刪 credentials、state或草稿：

```bash
docker compose down
```

不要執行 `docker compose down -v`，那會刪 Claude login。OpenAB state與草稿在 `/srv/work-agent/`，不由 Compose刪除。
