# Shared Product-Context Bot System Design

## 目標

在 Slack 提供一個多人共用的唯讀 product-context bot，讓授權使用者能直接建立指派給自己的待辦、查待辦、讀 repo、偵察既有待辦列並取得可 review 的 issue 草稿與 handoff，不必經由另一個人轉述。

這個 bot 停在 product context 與 handoff 層。它不修改產品 code、不建立 GitHub issue、不 push，也不通知 PM 驗收。

## 角色

| 角色 | 能做什麼 | 不能做什麼 |
|---|---|---|
| 授權使用者 | 從 Slack 發問、要求偵察、核准或退回草稿 | 透過遠端 bot 修改 code或取得 GitHub credential |
| product-context bot | 建立 self-assigned Slack 待辦、讀待辦與 repo snapshot、交付草稿與 handoff | 實作、建立 issue、查 private issues、回報驗收 |
| snapshot 同步者 | 在 deployment host 從 GitHub 更新 snapshots | 進入 container或代表 agent發布內容 |
| 實作 agent | 在 local 建 issue、修改 code、測試、push、回報驗收 | 假裝遠端草稿已核准或已實作 |

Slack 待辦角色如回報對象、核准者、負責人，沿用 `work-helper/CONTEXT.md` 的定義。

## 系統邊界

```text
授權使用者
  -> Slack DM / private channel / item 留言串
    -> deployment host
      -> 單一 OpenAB container
        -> OpenCode ACP + OMO plugin（預設 agent runtime）
          -> Slack Lists API
          -> 公司 OpenAI-compatible gateway（模型與生圖）
          -> 唯讀 repo snapshots
          -> 可寫 `/home/node/drafts` 目錄

GitHub
  -> deployment host 的 snapshot 同步者
    -> 唯讀 repo snapshots

local 實作 agent
  -> GitHub issues / 可寫 worktree / push
```

只有一個 container，沒有獨立 broker 或 relay。Slack bot token 與公司 gateway key
都在這個 container 內，由 OpenAB 依 `config/openab.toml` 的 `inherit_env` 傳給 agent process。
這是明確接受的取捨：邊界靠 Slack allowlist、唯讀 mount 與 agent runtime 的 permission 設定，
不靠 token 隔離。詳見 [`adr/0007-single-container-opencode-runtime.md`](adr/0007-single-container-opencode-runtime.md)。

GitHub credential只到 deployment host 與 local 實作環境，不跨進 product-context bot container。詳見 [`adr/0001-github-access-stops-at-the-host-boundary.md`](adr/0001-github-access-stops-at-the-host-boundary.md)。

Deployment host就是實體host，Compose以維護者自己的帳號執行。第一版曾把它包在restricted Incus instance內，後來因為該帳號本來就在`docker` group而取消。詳見 [`adr/0003-deploy-directly-on-the-fedora-host.md`](adr/0003-deploy-directly-on-the-fedora-host.md)。

## 互動入口

第一版支援：

- 授權使用者與 Slack app 的 DM。
- private channel `C0BPZRN6H3R`。
- Bug/需求總表 item 留言所在的 backing channel `C0B9PSESQ2U`。

只有 `config/openab.toml` 明列的 Slack user ID能驅動 agent。OpenAB `0.10.0-beta.3` 會把 channel allowlist也套到 DM channel ID，而 DM ID事前未知，因此 channel gate保持開放，實際 channel邊界由「只把 app 邀進上述兩個 channel」維持。新增 app所在 channel等於擴大互動入口，必須當成權限變更 review。

**已知缺口**：實際部署的 bot token 帶有 `chat:write.public`、`channels:manage`、`groups:write.invites` 等遠多於 [`runbook.md`](runbook.md) 所列的 scope，其中 `chat:write.public` 讓 app 不必被邀請就能貼文到任何公開 channel，「靠邀請維持 channel 邊界」因此不成立。要讓這條邊界成立必須移除多餘 scope 並重新安裝 app（token 會換一組）。

所有授權使用者的遠端能力相同。核准草稿不代表負責實作，也不會讓核准者取得 GitHub credential。

## Repo Snapshots

清單的正本是 [`config/repos.conf`](../config/repos.conf)，一行一個 repo。整個 snapshot root以單一 read-only mount掛成 container內的 `/home/node/code`，所以新增 repo只改那一個檔案，不動 Compose。

Host每小時 fetch所有 remote refs，再把每個 working snapshot reset到基準 branch。所有 OpenAB sessions共用同一份內容。

Snapshot代表最近一次同步成功的狀態，不保證和 GitHub當下完全同步。偵察結論若依賴剛 push的 commit，必須先確認 snapshot同步完成。

product-context bot查符號與影響範圍時用CodeGraph索引，找字串才用grep。索引內容對應snapshot當下的基準branch。

Working tree停在基準 branch，但 `.git`內保有完整的 `origin/*` refs。product-context bot可以用 `git show origin/<branch>:<path>` 這類唯讀方式讀還沒合併的 branch，不能 checkout；引用時必須標明 branch與 commit。

## 待辦流程

### 從 item 留言串開始

1. OpenAB把 sender、`channel_id` 與 `thread_ts` 放進 prompt 的 `<sender_context>`；它不是 ACP side-channel。
2. product-context bot用 `slack-list context` 反查唯一的待辦列。
3. agent讀待辦列、完整 item 留言串與相關 repo snapshots。
4. agent依該 snapshot 自己的 issue 規範寫 issue body草稿（含改動檔案、驗過的 code 錨點、驗證方式）。
5. agent用 `slack-list draft` 把 Markdown附件、來源指紋搜尋頁與 New issue頁放回同一個 item 留言串。
6. 核准者決定建立任務、直接派工或退回修改。

### 從 DM 或一般 channel 開始

口述需求不能直接變成草稿。product-context bot先找對應的既有待辦列；找不到而使用者明確要求建立時，
用`openab.sender.v1`的sender、channel與thread context建立一筆指派給sender的待辦列。標題由agent濃縮時先確認，
使用者明確提供標題時可直接建立；同名active列存在時加入既有assignees，不建立第二列。

`slack-list add`只由這個OpenAB instance執行，local implementation agent不執行，讓同一runtime的process lock
序列化查重與寫入。建立後的來源與回報設定留在原生item留言串；來源註記失敗時保留已建立的列並明確回報，
不直接重試。待辦列存在後才能進入偵察與草稿流程，確保每份草稿都有Slack來源指紋與回報規則。

### 「我的待辦」

這是多人共用的 agent，不能用固定的個人 ID判斷「我」。必須把當次
`openab.sender.v1.sender_id` 傳給 `slack-list assigned`，精確比對待辦列的 assignee user ID。

## 草稿邊界

草稿交付不是 issue發布，也不是 GitHub查重完成。遠端環境只能提供 GitHub搜尋頁供核准者人工確認；不能聲稱 private issue不存在。

草稿是消耗品。核准者看完後應選擇建立任務、當天直接派工或退回修改，不把 drafts目錄養成第二套 backlog。

## 輸入與輸出邊界

Slack v1 只接受 native 的 text、image、audio。PDF、Office 檔、video 與 ZIP 不支援，收到時
bot 直接說明不支援，不進入任何自訂下載或解析流程。

輸出限於三種：Slack 訊息本文、PNG 圖片產物、Markdown（handoff 或 issue 草稿附件）。
self-contained HTML 只有在使用者明確要求 prototype 或可互動頁面時才輸出，而且必須是單一檔案。
所有產物回到發問的那個 Slack thread；`slack-thread-artifact` 成功上傳才刪暫存，失敗保留交 host cleanup。
「回原 thread」是同一個 container 內的信任約定，不是安全保證，細節見下面「『回原 thread』靠的是什麼」。

Slack 傳進來的圖片要到得了模型，靠的是
[`../config/opencode/opencode.json`](../config/opencode/opencode.json) 裡模型的
`modalities.input` 含 `image`。

圖片**產出**是另一件事，走 `company-image`：一支裝在 image 內的受限 CLI，在同一個 container 完成，
沒有獨立的 artifact broker。它只有 `generate` 與 `edit` 兩個 mode，只收 prompt、允許清單內的 size
與（`edit` 用的）來源圖片路徑；沒有 endpoint、header、model 或輸出路徑參數，gateway 位置與 key
只從 runtime env 讀。請求固定用公司 gateway 的 Responses API `image_generation` tool，輸出固定是
PNG，固定寫到 `/home/node/drafts/<UTC 日期>/`。介面就是能力上限：多一個尺寸都要改 repo 重新
build。理由與拒絕的替代方案見
[`adr/0008-restricted-company-image-cli.md`](adr/0008-restricted-company-image-cli.md)。

兩個 agent runtime 共用這一支 —— image 由同一份 `Dockerfile` 建置，兩份 OpenAB config 都把
`COMPANY_GATEWAY_*` 放進 `inherit_env`，兩份 permission 清單都明列允許執行它。所以「Claude ACP
是可用的 rollback」這句話在生圖上也成立，不是只在文件上成立。

產圖後用 `slack-thread-artifact` 回原 thread。它固定執行 `files.getUploadURLExternal → upload →
files.completeUploadExternal`，只讀 drafts 下的 regular PNG、Markdown、HTML，且成功才刪檔。

### 「回原 thread」靠的是什麼

**這是信任約定，不是安全保證。** 說清楚它由什麼組成：

- OpenAB 把當次的 sender、`channel_id`、`thread_ts` 寫進 prompt 裡的 `<sender_context>`。那是
  **prompt content**，不是 ACP side-channel，也不是不可竄改的授權資料。
- agent 讀那段文字，再把 `--channel`、`--thread-ts` 逐字交給 CLI。這一步由 `agents/CLAUDE.md`
  的文字約束，不由任何機制強制。
- CLI 只檢查格式（`C/D/G` 開頭的 channel ID、Slack timestamp），不能判斷這組值是不是本次
  sender 真正的 thread。
- 三者在**同一個 container** 內，共用同一個 `SLACK_BOT_TOKEN`。

所以能被信任的原因是「這三段都在同一個信任域內」，不是任何一段驗證了另一段。**不宣稱**
token isolation、cryptographic binding，也**不宣稱**擋得住 prompt injection：能改變 agent 送出什麼
值的輸入，就能改變檔案送到哪個 thread（限於這個 bot token 本來就進得去的 conversation）。

CLI 的價值只在縮小可造成的副作用：拿掉任意 URL、header、命令與輸出路徑的自由度，並且
把檔案來源鎖在 drafts。這不是把 prompt context 變成安全邊界。

刻意**不**改成 broker 或 relay：那要另一個 process 持有 token 並自己判斷 thread 歸屬，而
判斷依據仍然只有 OpenAB 給的同一份 context，換不到新的保證，只多一層要維護的東西。完整取捨見
[`adr/0009-thread-artifact-upload-and-optional-stt.md`](adr/0009-thread-artifact-upload-and-optional-stt.md)
與 [`adr/0007-single-container-opencode-runtime.md`](adr/0007-single-container-opencode-runtime.md)。

上傳失敗時草稿保留，由 deployment host 的 `# work-agent-artifact-cleanup` crontab entry
（`scripts/cleanup-artifacts.sh` → container 內 `slack-list cleanup`，每小時 :17）收掉；保留期限
24 小時，檢查每小時一次，所以實際壽命是 24 到 25 小時。

Audio 只有獨立的 OpenAI-compatible STT endpoint 已被確認、設定 `STT_BASE_URL`／`STT_API_KEY` 並把兩份
OpenAB config 的 `[stt].enabled` 改成 `true` 時才可轉錄。OpenAB 固定使用該 base URL 的
`/audio/transcriptions`；不假設 company gateway 支援。預設未啟用時 bot 明確拒絕 audio。

## 對話回覆

一般 Slack 對話先回答產品結論、使用者目前會遇到什麼，以及期望改成什麼。除非授權使用者明確追問，否則不在對話回覆附檔名、行號、函式名、state、payload 或 API；這些工程細節留在 issue 草稿。

Runtime或部署故障造成工具不能執行時，product-context bot只告知哪項查詢暫時不可用，並指出需要部署維護者修復，不要求 Slack 使用者執行 container排障或安裝套件。

## Agent Runtime 與版本

預設 agent runtime 是 OpenCode 的原生 ACP（`opencode acp`），加上 oh-my-opencode-slim（OMO）
plugin。OMO 的模型分工是 Luna retrieval、Terra synthesis，設定在
[`../config/opencode/oh-my-opencode-slim.json`](../config/opencode/oh-my-opencode-slim.json)。

Claude ACP 沒有被刪掉，是保留的 rollback。切換只改
[`../config/versions.env`](../config/versions.env) 的 `OPENAB_AGENT_RUNTIME`：

| 值 | base image | OpenAB config |
|---|---|---|
| `opencode`（預設） | `OPENAB_IMAGE_OPENCODE` | `config/openab.toml` |
| `claude` | `OPENAB_IMAGE_CLAUDE` | `config/openab.claude-acp.toml` |

兩份 OpenAB config 的 `[slack]`、`[pool]`、`[reactions]` 必須逐字相同，`tests/static.sh` 會
比對；只有 `[agent]` 允許不同，這樣 rollback 不會順手改掉誰能用這個 bot。

所有版本（兩個 image 的 immutable digest、OpenCode、OMO、CodeGraph）集中在
`config/versions.env`，build 不得使用 `latest`、`beta` 或 `stable`。`docker compose` 一律經
`scripts/compose.sh` 進入，直接呼叫會因缺變數中止。Dockerfile 會在 build 時驗證 base image
內的 OpenCode 版本等於 `OPENCODE_VERSION`。

「唯一正本」是可執行的，不是慣例：環境變數和 `config/versions.env` 不一致時 `load_versions`
直接中止，不讓 ambient 值覆蓋 pin 或 runtime 選擇，否則 build 出來的 image 會和被 review 的檔案
不同而且沒有任何地方會說。唯一支援的例外是 `./scripts/compose.sh --runtime <opencode|claude>`，
它明確、只影響這一次 render，也不動檔案。

唯讀邊界在兩個 runtime 由不同機制維持，兩份清單要一起維護：

| runtime | 唯讀與 deny 規則正本 |
|---|---|
| `opencode` | `config/opencode/opencode.json` 的 `permission`（`edit: deny` 加 bash deny 清單） |
| `claude` | `managed-claude-settings.json` |

`managed-claude-settings.json` 在 OpenCode runtime 下不生效，只服務 rollback 路徑。

## 執行與持久化

- 一個 OpenAB instance，共用最多 10 個 sessions。
- 閒置 session 4 小時後回收。
- Claude Code login存在獨立 credential volume；OpenCode 的 auth、session storage 與 plugin
  cache 各有一個 named volume（`opencode-data`、`opencode-cache`），因為 rootfs 是唯讀的。
- `/home/node/.config/opencode` 是可寫的 named volume（`opencode-config`），`config/opencode`
  內的每個設定檔以**單檔唯讀** mount 疊在上面。OpenCode 會在自己的 config dir 寫 `.gitignore`
  與 state，整個目錄唯讀時 `opencode acp` 起不來；單檔唯讀讓 agent 仍然改不掉 provider 與
  permission 設定。OMO plugin 由 image 提供並固定版本，runtime 不上網抓 plugin，`autoUpdate`
  與 OpenCode `autoupdate` 都關掉。
- OpenCode 另外有一個 state root `/home/node/.opencode`，也會在裡面寫 `.gitignore` 與 state。
  rootfs 唯讀而這個路徑沒有 mount 時，`opencode acp` 會用跟上面同一種方式在啟動時死掉。它有
  自己的 named volume（`opencode-state`）。這是**兩個**不同的目錄，修好 config dir 不會順便
  修好它。`/home/node` 本身維持唯讀：把 home 整層改可寫會讓底下所有唯讀 mount 失去意義。
- `/home/node/.opencode`（OpenCode state）與 `/home/node/.openab`（OpenAB state，bind 到
  `runtime/openab`）是不同程式的不同目錄，只差一個字，讀 compose 時不要看混。
- Container使用者的 uid/gid由 `HOST_UID`／`HOST_GID` build arg設定，必須等於執行 docker的 host使用者，可寫 bind mount才成立。
- Bind mount帶 `:z`，SELinux enforcing的 host才讀得到；`z` 會 relabel來源目錄，所以 snapshot root是專用目錄。
- Skills由 `work-helper/.claude/skills` 整個目錄掛成 `/home/node/.claude/skills`。Claude runtime
  當它是 personal level skill；OpenCode 由 `config/opencode/opencode.json` 的 `skills.paths`
  指過去。部署層不裁這份 catalog，跑不動的 skill 由 `agents/CLAUDE.md` 用文字擋。work-helper
  `main` 上的新 skill會在下次同步後自動生效，不需要改這個 repo。第三方 skill由
  `work-helper/skills-lock.json` 記錄來源與 hash。
- OpenAB state與草稿存在 deployment repo的 Git-ignored `runtime/`，不隨 container重建刪除。
- Project資料中可寫的只有 `/home/node/drafts` 與 `/home/node/code/.index`；repo源碼全部唯讀。
- 每個 snapshot 的 `.codegraph` 是指向 `.index/<repo>` 的相對 symlink。CodeGraph索引是WAL模式的SQLite，必須可寫；把它移出唯讀樹讓源碼的唯讀保證維持不變。索引由host每小時用runtime image重建，agent只能查詢。
- OpenAB image使用固定 multi-arch digest，不跟浮動 tag更新。
- Runtime image從固定 digest的 OpenAB image建置，額外提供 `slack-list` 所需的 Python 3、
  唯讀 git 偵察所需的 git（`-opencode` base image 沒有）、固定版本的 CodeGraph 與 OMO，以及
  生圖用的 `company-image`。
- `company-image` 由 root 擁有、mode 0755，agent 只能執行不能改寫；build 時會跑一次
  `company-image --help`，語法或 Python 版本不合會 build 失敗。

## 明確不做

- 不把 GitHub token、SSH key或 Docker socket放進 container。
- 不使用 claude.ai 的 MCP connectors。它們跟著登入帳號同步進 container，用的是該帳號的第三方身分（Slack、Gmail、Drive…），不受這個 agent 的 bot scopes 與 channel 邊界約束。由 `managed-claude-settings.json` 的 `disableClaudeAiConnectors` 關閉（只在 Claude rollback runtime 生效；OpenCode runtime 本來就不載入 claude.ai connectors）。
- 不建獨立 broker 或 relay，也不追求 Slack token 隔離。
- 不接受 PDF、Office 檔、video 或 ZIP，也不自建下載解析流程。
- 不在部署層裁 `work-helper` 的 skill catalog。
- 不讓 product-context bot clone、fetch、建立 branch/worktree、commit或 push。
- 不讓 product-context bot執行 `slack-list ready` 或宣告驗收。
- 不自動把草稿發布成 GitHub issue。
- 不為每位授權使用者部署獨立 agent instance。
- 第一版不支援 Slack slash commands或 Slack AI assistant mode。

## 驗收情境

1. 授權使用者能從 DM查 repo；未授權使用者的訊息被拒絕。
2. 授權使用者能在指定 private channel @ agent，後續在同一 thread繼續對話。
3. 授權使用者從DM或指定private channel明確建立待辦時，新列指派給sender並保存來源；同名active列不重複建立。
4. 在待辦列的 item 留言串 @ agent時，agent能反查正確 `Rec...`，不要求人再貼 ID。
5. 偵察完成後，item 留言串收到 Markdown草稿與人工 GitHub連結，待辦狀態不變。
6. Container內所有 snapshots不可寫，drafts可寫，且沒有可用的 GitHub auth或 SSH key。
7. Host同步後，所有新 sessions讀到同一個基準 branch版本。
8. `./scripts/deploy.sh` 在 `OPENAB_AGENT_RUNTIME=opencode` 下能驗到 container 內的
   `opencode` 版本等於 `OPENCODE_VERSION`、OMO 版本等於 `OMO_VERSION`，且
   `/etc/openab/config.toml` 的 agent 是 `opencode acp`。
9. 把 `OPENAB_AGENT_RUNTIME` 改成 `claude` 後，同一支 `deploy.sh` 改為驗
   `claude-agent-acp` 存在且 config 指向它，Slack allowlist 不變。
10. 圖片附件能進到模型；bot 對 PDF、ZIP 明確回覆不支援。
11. 一般請求得到 PNG；明確要求 prototype 時才得到單一檔案的 HTML；兩者都由受限 uploader 回原 thread。
12. `company-image generate` 在 container 內產出 PNG 到 `/home/node/drafts/<UTC 日期>/`；
    非法 size、走出 drafts 的檔名、允許範圍外的來源圖片都被拒絕且不發出 gateway 請求。
    這一項的靜態部分由 `tests/image-runtime.py` 用假 gateway 驗，真的 gateway 回得回圖要在
    有 key 的環境實跑一次。
13. 把 `OPENAB_AGENT_RUNTIME` 改成 `claude` 後，同一支 `company-image` 仍在，
     `COMPANY_GATEWAY_*` 仍傳得到 agent process。
14. `slack-thread-artifact` 只接受 drafts 下的 regular PNG、Markdown、HTML；成功依序取得 upload URL、上傳、
    complete 到 `<sender_context>` 的 channel/thread 後刪檔。失敗不刪檔，且 Claude rollback 同樣可執行。
15. 未設定並啟用 STT 時 audio 被明確拒絕；設定獨立相容 endpoint 後才驗 `/audio/transcriptions` 真實轉錄。
16. 兩支 CLI 都走不出固定 root：父目錄被換成 symlink、檔名本身是 symlink、路徑用 `..` 逃逸，
    都被拒絕且不發出任何 Slack 或 gateway 請求。`company-image` 的目標檔名被事先種成
    指向外面的 symlink 時，寫到下一個可用檔名，不寫穿它。由 `tests/artifact-path-safety.py` 重現。
17. 上傳成功後草稿被刪；但草稿在讀取之後被換成別的檔案或 symlink 時，**不刪**那個東西，
    在 stderr 說明並仍 exit 0（檔案確實送出去了，回非零只會讓 agent 重傳）。
18. Deployment host 的 crontab 有 `# work-agent-artifact-cleanup` entry，每小時執行
    `scripts/cleanup-artifacts.sh`，它在 container 內跑 `slack-list cleanup`；container 沒在跑時
    這一輪失敗會寫進 `artifact-cleanup.log` 並回非零。排程存在由 `tests/static.sh` render
    `render_crontab` 驗；cron 真的觸發過只能人工確認。
19. `tests/static.sh` 與 `scripts/deploy.sh` 都不聲稱驗過 Slack、公司 gateway、STT 或 cron 觸發；
    `deploy.sh` 結束時印出未驗清單，對應 [`runbook.md`](runbook.md#人工-release-gate) 的
    「人工 release gate」。

## 人工前置作業

- Slack app重新安裝並取得 `xapp-...`、新 `xoxb-...`。
- 將 app顯示名稱改為「派大星教授加博士先生」。
- 把 host專用 GitHub SSH public key加入一個能讀 `config/repos.conf` 內所有 private repos的 GitHub帳號。
- 在 container內完成 Claude Code subscription login。

實際操作命令見 [`runbook.md`](runbook.md)。
