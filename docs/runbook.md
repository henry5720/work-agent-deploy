# Work Agent Runbook

Local與deployment host共用同一份 Compose及runtime設定。State與草稿都放在本 repo的 `runtime/`；
兩邊都要建立 root `.env`，指定 snapshot root與執行 docker的使用者 uid/gid。

Deployment host是實體 Linux host，Compose以維護者自己的帳號執行，不需要sudo。該帳號必須在`docker` group裡，
並且host要有Git、SSH client、Python 3、curl、jq與cron。SELinux enforcing的host不需要額外設定，Compose的
bind mount已經帶`:z`。

**所有 compose 指令都走 `./scripts/compose.sh`。** 它會先載入 root `.env` 與
`config/versions.env`，再把參數原樣交給 `docker compose`。直接打 `docker compose` 會因為
`OPENAB_IMAGE` 未設定而中止 —— 這是刻意的，版本只有 `config/versions.env` 一份正本。

Compose service 仍然叫 `backlog-agent`，container 叫 `work-agent`。這是識別字，不是產品定位；
改名會讓現有部署的 volume 與 crontab 對不上，所以沒有跟著文件一起改。

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
./scripts/compose.sh build --pull
./scripts/compose.sh up -d
./scripts/compose.sh ps
./scripts/compose.sh logs --tail=100 backlog-agent
```

預設 runtime 是 OpenCode，模型走公司 gateway 的 API key，**不需要互動式登入**。只有切回
Claude ACP rollback 時才要 `./scripts/compose.sh exec backlog-agent claude auth login`。

`env/openab.env` 至少要填入 `SLACK_BOT_TOKEN`、`SLACK_APP_TOKEN`、`SLACK_LIST_ID`、
`SLACK_TEAM_ID`（後兩個 `slack-list` 與 `publish-slack-home.sh` 都會用，缺了會直接中止），
以及公司 gateway 的 `COMPANY_GATEWAY_BASE_URL` 與 `COMPANY_GATEWAY_API_KEY`（兩個 runtime 都
必填：OpenCode 用它跑模型，`company-image` 用它生圖，preflight 會擋），並保留：

```text
WORK_HELPER_ISSUE_MODE=manual
```

這些 runtime secret 全部住在同一個 container，沒有 broker 也沒有 token 隔離層。理由與取捨見
[`adr/0007-single-container-opencode-runtime.md`](adr/0007-single-container-opencode-runtime.md)。

`config/opencode/opencode.json` 裡的模型 ID（`company/gpt-5.6-terra`、`company/gpt-5.6-luna`）
必須對得上公司 gateway 實際 expose 的名稱。第一次接上 gateway 時先確認：

```bash
./scripts/compose.sh exec backlog-agent opencode models
```

對不上就改 `config/opencode/opencode.json` 的 `provider.company.models` 與
`config/opencode/oh-my-opencode-slim.json` 的 preset，兩邊要一致（`tests/static.sh` 會比對
preset 用到的模型都在 provider 裡）。

Root `.env` 只給 Compose用（snapshot root與 uid）；`env/openab.env` 才會傳進 container。
`.env`、`env/openab.env` 與 `runtime/` 都不進 Git。Claude login存在 named volume
`claude-credentials`，重建 container後仍保留。

在 Slack確認：

1. DM詢問一個 repo問題。
2. 在 `#你為什麼不問問神奇海螺ㄋ` @ bot建立一筆實際要保留的待辦，確認指派給sender並保存來源。
3. 再次要求建立同名待辦，確認沒有新增第二列。
4. 在待辦列的 item留言串 @ bot，確認它能找到正確的 `Rec...`。
5. 傳一張截圖問問題，確認圖片有被讀到；再傳一個 PDF，確認 bot 明確回不支援。
6. 要一張圖，確認 bot 用 `company-image` 產出 PNG，再用 `slack-thread-artifact` 回同一個 thread；明確要求
   「可互動 prototype」時才上傳單一檔案 HTML。上傳成功後確認 drafts 原檔被刪；讓 Slack API 故意失敗一次，
   確認原檔保留給 cleanup。

停止 local instance：

```bash
./scripts/compose.sh down
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
./scripts/compose.sh logs --tail=100 backlog-agent
```

`install-sync-cron.sh` 會建立 snapshot root與 repo內的 `runtime/`、寫入**兩個**每小時的 crontab entry，並跑第一次同步：

| Marker | 時間 | 做什麼 |
|---|---|---|
| `# work-agent-snapshots` | 每小時 :00 | `scripts/update-snapshots.sh`：同步 snapshot、重建 CodeGraph 索引 |
| `# work-agent-artifact-cleanup` | 每小時 :17 | `scripts/cleanup-artifacts.sh`：在 container 內跑 `slack-list cleanup` |

兩行都由 `scripts/lib.sh` 的 `render_crontab` 產生，`tests/static.sh` 會 render 同一個函式來確認
cleanup 真的有排程。上傳失敗的 artifact 是刻意留在 drafts 的，第二行是唯一會把它們收掉的東西；
只裝第一行的 host 會讓 drafts 無限長大。

保留期限是 24 小時，但檢查每小時才一次，所以實際壽命是 **24 到 25 小時**，不是剛好 24。

`deploy.sh` 會先執行 preflight，再 build及啟動 container，最後印出它**沒有**驗到的項目（見下面
「人工 release gate」）。

### 驗證安全邊界

```bash
./scripts/compose.sh ps
crontab -l | grep work-agent-snapshots
./scripts/compose.sh exec backlog-agent sh -lc \
  'python3 --version >/dev/null &&
   git --version >/dev/null &&
   /home/node/code/work-helper/bin/slack-list --help >/dev/null &&
   test -w /home/node/.openab &&
   test -w /home/node/drafts &&
   test ! -w /home/node/code/teamsync-frontend &&
   test ! -w /home/node/code/teamsync-backend &&
   test -d /home/node/.claude/skills/slack-list &&
   test ! -e /home/node/.ssh &&
   test ! -e /home/node/.config/gh &&
   ! gh auth status >/dev/null 2>&1 &&
    command -v company-image >/dev/null &&
    command -v slack-thread-artifact >/dev/null &&
   test ! -w /usr/local/bin/company-image &&
   codegraph explore boot -p /home/node/code/work-helper >/dev/null'
```

生圖那條路徑要真的打一次公司 gateway 才算驗過（會產生一次計費呼叫）：

```bash
./scripts/compose.sh exec backlog-agent \
  company-image generate --prompt 'a plain grey square' --name smoke
./scripts/compose.sh exec backlog-agent sh -lc \
  'head -c 8 "$(ls -t /home/node/drafts/*/smoke*.png | head -1)" | od -c | head -1'
```

第一行會印出 drafts 內的 PNG 路徑，第二行確認開頭是 PNG magic。驗完把那個檔刪掉。
`tests/image-runtime.py` 只驗請求 shape、兩種回應形狀（JSON body 與 `text/event-stream`）與拒絕
不合法輸入，**不會**證明公司 gateway 接受這個請求，也不會告訴你它這次回哪一種；gateway 沒實際
回過圖之前不要說生圖已經可用。

OpenCode runtime 另外驗這幾項（`deploy.sh` 也會跑同一組）：

```bash
./scripts/compose.sh exec backlog-agent sh -lc \
  'opencode --version &&
   npm ls -g --depth=0 oh-my-opencode-slim &&
   test ! -w /home/node/.config/opencode/opencode.json &&
   test ! -w /home/node/.config/opencode/oh-my-opencode-slim.json &&
   test -w /home/node/.config/opencode &&
   touch /home/node/.config/opencode/.probe && rm /home/node/.config/opencode/.probe &&
   test -w /home/node/.opencode &&
   touch /home/node/.opencode/.probe && rm /home/node/.opencode/.probe &&
   test ! -w /home/node &&
   test -w /home/node/.cache &&
   test -w /home/node/.local/share/opencode &&
   grep -q "^command = \"opencode\"" /etc/openab/config.toml'
```

`test -w` 這幾項是SELinux label與uid都正確才會過的，Compose render成功不代表通過。

OpenCode 有**兩個**必須可寫的目錄，各撞死過 `opencode acp` 一次。兩次的症狀一樣：OpenAB 端只
看得到 ACP 連線關掉，真正的原因要看 container log。

| 目錄 | volume | container log |
|---|---|---|
| `/home/node/.config/opencode`（`OPENCODE_CONFIG_DIR`） | `opencode-config` | `Unexpected error: FileSystem.writeFile (/home/node/.config/opencode/.gitignore)` |
| `/home/node/.opencode`（OpenCode state root） | `opencode-state` | `Unexpected error; Unknown: FileSystem.writeFile (/home/node/.opencode/.gitignore)` |

修好第一個不會順便修好第二個 —— 第二個是在第一個修完之後才浮出來的。

config dir 那個目錄**必須可寫**，裡面兩個設定檔**必須不可寫**，兩邊都要成立：設定正本用單檔
唯讀 mount 疊在可寫的 named volume 上，agent 才改不掉 provider 與 permission。
在 `config/opencode/` 新增設定檔時要一起在 `compose.yaml` 加一行單檔 mount，否則那個檔不會
進 container；`tests/static.sh` 會比對目錄內容與 mount 清單，漏了會擋下來。

`/home/node/.opencode` 沒有設定正本要疊，整個 named volume 可寫就好。不要改成把 `/home/node`
掛成可寫來一次解決，那會讓底下的唯讀設定、skills 與 snapshot mount 全部失效；`test ! -w
/home/node` 就是在擋這條捷徑。這個路徑不是 `/home/node/.openab`（OpenAB 自己的 state，bind 到
`runtime/openab`），兩個都要在。

`opencode-config` 與 `opencode-state` 只放 OpenCode 自己生成的檔。兩個都可以安全刪掉重建
（`docker volume rm work-agent_opencode-config work-agent_opencode-state`，container 停著時
做），設定不會跟著掉 —— 正本在 repo。`opencode-state` 重建會掉 OpenCode 自己的 state，不會掉
auth（那在 `opencode-data`）。

`gh` 這個 binary本身存在於 OpenAB base image內，拿掉它不是這裡的邊界。邊界是它沒有任何憑證，
加上 runtime 的 deny 規則 —— OpenCode runtime 是 `config/opencode/opencode.json` 的
`permission.bash`，Claude rollback 是 `managed-claude-settings.json`。上面驗的是憑證，不是 binary。

接著重做 local段落的 Slack測試，再確認未授權帳號的訊息不會被處理。

### 切回 Claude ACP

Claude ACP 是保留的 rollback，不需要改 code：

```bash
$EDITOR config/versions.env       # OPENAB_AGENT_RUNTIME=claude
./tests/static.sh
./scripts/deploy.sh
./scripts/compose.sh exec backlog-agent claude auth login
```

`deploy.sh` 會換成 `OPENAB_IMAGE_CLAUDE`、改掛 `config/openab.claude-acp.toml`，並驗
`claude-agent-acp` 存在、config 指向它。Slack allowlist 不會因為 rollback 改變 ——
兩份 config 的 `[slack]`、`[pool]`、`[reactions]` 由 `tests/static.sh` 比對逐字相同。

**改 `config/openab.toml` 的 Slack 設定時要同步改 `config/openab.claude-acp.toml`**，否則
static test 會擋下來。

不預先 build 也能先確認 rollback 路徑是通的（不啟動任何東西）：

```bash
./scripts/compose.sh --runtime claude config --quiet
```

`--runtime` 只是不改檔案地 render 另一個 runtime，正式切換仍然要改 `config/versions.env`。
**環境變數不能拿來覆蓋 runtime 或版本**：在指令前面塞 `OPENAB_AGENT_RUNTIME=...`（或任何一個
`config/versions.env` 內的 key）會直接中止並要求改用這個 flag，理由是版本只有一份正本。

Rollback 也有生圖：`company-image` 是 image 裡的一支 CLI，兩個 variant 都有，而
`config/openab.claude-acp.toml` 同樣把 `COMPANY_GATEWAY_*` 放進 `inherit_env`。
Rollback 也能回傳檔案：同一份 Dockerfile 會裝 `slack-thread-artifact`，兩份 permission 設定都允許它。

### 人工 release gate

`tests/static.sh` 是靜態檢查，`scripts/deploy.sh` 只驗到「container 起得來、runtime 版本對、
唯讀與可寫邊界成立」。**兩支都不會呼叫 Slack、公司 gateway 或 STT，也不會證明 crontab 真的觸發過。**
沒有 Docker 的機器上 `tests/static.sh` 連 Compose render 都是本機解析（它會印 LIMITED VERIFICATION）。

所以下面這幾項是人工 gate，每次 release 都要重跑一遍，不能因為 `deploy.sh` 退出 0 就當它們過了：

| # | 要驗什麼 | 怎麼驗 | 為什麼自動化驗不到 |
|---|---|---|---|
| 1 | Slack 授權邊界 | 授權帳號 DM 有回應；未授權帳號沒有 | 需要真的 Slack workspace 與兩個身分 |
| 2 | Artifact 回原 thread | 上面「Local 首次啟動」第 6 項，含刻意失敗一次確認留檔 | 需要真的 `SLACK_BOT_TOKEN` 與真的 thread |
| 3 | 生圖 | 下面那兩行 `company-image generate`（會產生一次計費呼叫） | 離線測試只驗 request shape |
| 4 | Artifact cleanup 排程 | `./scripts/cleanup-artifacts.sh` 手動跑一次，再確認 crontab entry 與 log 沒有 `FAILED` | 靜態測試只證明排程被寫進去，不證明 cron 觸發過 |
| 5 | STT（`[stt].enabled = true` 時才要） | 用真實音檔打一次 `/audio/transcriptions` | 靜態檢查不發請求 |
| 6 | 模型推論打得到 gateway | 下面那行 `opencode run --pure`，要回文字而不是 HTTP 405 | `tests/provider-route.py` 只推導 endpoint，不發請求 |

第 4 項的兩個指令：

```bash
crontab -l | grep work-agent-artifact-cleanup
./scripts/cleanup-artifacts.sh
```

第 6 項。這是 `provider.company.npm` 曾經寫成 `@ai-sdk/openai-compatible` 時整台 bot 問不動的
那個檢查（回 HTTP 405，理由見
[ADR 0010](adr/0010-company-provider-uses-the-responses-api.md)）。改動 provider 設定、
`COMPANY_GATEWAY_BASE_URL` 或 OpenCode 版本之後都要重跑：

```bash
./scripts/compose.sh exec backlog-agent \
  opencode run --pure --model company/gpt-5.6-terra 'reply with the single word ok'
```

回文字就算過。回 HTTP 405 代表請求打到 `{baseURL}/chat/completions` 而 gateway 只收
`/responses` —— 先看 `provider.company.npm` 是不是 `@ai-sdk/openai`，再看
`COMPANY_GATEWAY_BASE_URL` 的前綴對不對。401／403 是 key 的問題，不是這條。

`deploy.sh` 結束時會把這份清單再印一次，避免只看終端機輸出的人以為已經驗完。

### 啟用 audio 轉錄（可選）

不要把 company gateway 當成 STT provider。先用一個已確認支援 OpenAI-compatible
`/audio/transcriptions` 的 endpoint 填 `STT_BASE_URL`、`STT_API_KEY`，再把 **兩份**
`config/openab*.toml` 的 `[stt].enabled` 改成 `true`，重新跑 `./tests/static.sh && ./scripts/deploy.sh`。
未做完這些步驟時 audio 必須被 bot 明確拒絕。首次驗證要以真實音檔打一次 STT endpoint；靜態檢查不會發請求。

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
./scripts/compose.sh ps
./scripts/compose.sh logs -f --tail=200 backlog-agent
```

查看或立即更新 snapshots：

```bash
crontab -l | grep work-agent-snapshots
tail -n 50 "${XDG_STATE_HOME:-$HOME/.local/state}/work-agent/snapshots.log"
./scripts/update-snapshots.sh
```

查看或立即執行 artifact cleanup：

```bash
crontab -l | grep work-agent-artifact-cleanup
tail -n 50 "${XDG_STATE_HOME:-$HOME/.local/state}/work-agent/artifact-cleanup.log"
./scripts/cleanup-artifacts.sh
```

`cleanup-artifacts.sh` 自己不刪檔，它在 container 內執行
`/home/node/code/work-helper/bin/slack-list cleanup`——刪除規則的正本在 work-helper，
host 端不要直接動 `runtime/drafts`。log 裡出現 `FAILED` 就是那一輪沒清到（多半是 container
沒在跑），artifact 會留到下一輪；持續 FAILED 要當成待處理，不是雜訊。

`update-snapshots.sh` 同步完會用 runtime image重建 CodeGraph索引，所以 host不需要安裝 Node。
索引放在 `$SNAPSHOT_ROOT/.index/<repo>`，每個 snapshot內的 `.codegraph` 是指過去的相對 symlink。
第一次部署時 image還沒 build，那一輪的索引會被跳過並印出訊息，`deploy.sh` 之後再跑一次同步即可。

停止 agent：

```bash
./scripts/compose.sh down
```

不要執行 `./scripts/compose.sh down -v`，它會刪掉 `claude-credentials`（Claude login）與
`opencode-data`（OpenCode auth 與 session storage）。`opencode-config` 與 `opencode-cache`
只有 OpenCode 自己生成的檔，刪掉會自己長回來。`runtime/` 不會被 `down` 刪除。

### 升級版本

版本正本只有 `config/versions.env` 一份。升級 OpenAB 時：

1. 取得新版本兩個 variant 的 multi-arch digest（`-opencode` 與 `-claude` 都要，rollback 才不會
   停在舊版）。
2. 更新 `OPENAB_VERSION`、`OPENAB_IMAGE_OPENCODE`、`OPENAB_IMAGE_CLAUDE`。
3. 確認新 image 內的 opencode 版本，同步更新 `OPENCODE_VERSION` —— 對不上 build 會失敗，
   這是刻意的。
4. `./tests/static.sh && ./scripts/deploy.sh`。

升級 OMO 時只改 `OMO_VERSION`，並把 `config/opencode/opencode.json` 的 plugin pin 與
`config/opencode/oh-my-opencode-slim.json` 的 `$schema` 改成同一版；三處不一致 static test 會擋。

### 更新或新增 Skill

`/home/node/.claude/skills` 是 `work-helper/.claude/skills` 整個目錄的 read-only mount。修改或新增 skill只要 commit並 push到
`work-helper` 的 `main`，下一次同步（每小時）之後就會生效，**不需要改這個 repo，也不需要重新 build或 deploy**。

要立即生效就在 host上執行 `./scripts/update-snapshots.sh`。

部署層不裁這份 catalog：整個目錄都掛進去，Claude runtime 當它是 personal level skill，
OpenCode 由 `config/opencode/opencode.json` 的 `skills.paths` 指過去。**讀得到不等於能跑**，
不該跑的 skill 寫在 `agents/CLAUDE.md`。

第三方 skill在 work-helper用 `npx skills add <repo> -s <skill> -a claude-code --copy` 安裝，來源與 hash記在
`work-helper/skills-lock.json`，更新用 `npx skills update -p`。**一定要 `--copy`**：預設的 symlink會指到
mount範圍以外，在 container內是斷的。

唯一需要改這個 repo的情況：新 skill在這個環境跑不動（需要 `gh`、`git worktree`、可寫 repo或 local 專用工具），
或它的行為會撞到 Slack回覆規則。那要在 `agents/CLAUDE.md` 的「Skill 邊界」寫明，否則 agent會在 Slack上嘗試然後失敗。

已啟動的Claude session可能已把舊skill內容讀進context。同步後使用新的Slack thread或等待session回收再驗證，不用以舊session判斷同步失敗。

### 新增唯讀 Repo

新增repo會擴大product-context bot可讀資料的範圍，必須當成能力與權限變更review。整個 snapshot root是單一 mount，所以只改一個檔案：

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
