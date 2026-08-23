# Work Agent Deployment

這個 context 定義 product-context bot、handoff pack 與 Slack 互動資料的領域詞彙和關係。

## Language

**product-context bot**:
在 Slack 提供唯讀產品脈絡與交接整理的 bot。它讀取 product context、回答問題並整理 handoff
pack；它不是 remote executor，也不修改 repo 或代替人執行工作。
_Avoid_: backlog agent、execution agent、remote executor

**product context**:
描述產品現況、決策、限制與相關來源的共享脈絡。product-context bot 以它作為回答與 handoff
pack 的共同依據。
_Avoid_: 個人工作筆記、可寫 checkout

**handoff pack**:
把產品脈絡與來源關係整理成可交接的內容單位。它由 product-context bot 產生，供人接續判斷
或處理，不代表 bot 已完成實作。
_Avoid_: remote execution、已套用的 patch、完成宣告

**repo snapshot**:
供 product-context bot 查閱的唯讀 repo 視圖。它是 product context 的工程來源之一，不是
開發中的 checkout；bot 與 repo snapshot 的關係只有讀取。
_Avoid_: clone、worktree、可寫 snapshot

**Slack query scope**:
Slack 查詢的來源範圍。預設是 current thread，也可以是綁定的 List，或使用者明確提供的
permalink／channel 來源；product-context bot 不把其他對話自動視為查詢來源。
_Avoid_: 全域搜尋、隱含跨 thread 查詢

**native attachment**:
Slack v1 只直接理解文字、圖片與音訊附件。PDF、Office、video 與 ZIP 不屬於這個 bot 的
支援輸入。
_Avoid_: 未宣告的附件格式

**image artifact**:
product-context bot 透過 `company-image` 向公司 gateway 產生或編輯的圖片產物。格式一定是 PNG，
一定先落在 `/home/node/drafts/<UTC 日期>/`；只有使用者明確要求時，才改輸出 self-contained HTML
prototype。artifact 上傳成功後立即刪除暫存；上傳失敗時保留給 host 每小時的 cleanup，壽命 24 到
25 小時（保留期限 24 小時，但檢查每小時才一次）。
_Avoid_: 未說明格式、永久保留暫存、bot 自己組 gateway 請求、宣稱剛好 24 小時

**sender context**:
OpenAB 寫進 prompt 的當次 sender、`channel_id` 與 `thread_ts`。它是 prompt content，不是 ACP
side-channel，也不是不可竄改的授權資料。「產物回原本那個 thread」是 OpenAB、agent 與受限 CLI 在
**同一個 container** 內的信任約定，靠 `agents/CLAUDE.md` 的規則維持，不是可驗證的安全保證。
_Avoid_: 說成身分驗證、token isolation、防 prompt injection、broker 或 relay

**company-image**:
container 內生圖／改圖的唯一入口。它是一支受限 CLI：mode 只有 `generate` 與 `edit`，參數只有
prompt、允許清單內的 size 與來源圖片，沒有 endpoint、header、model 或輸出路徑。gateway 位置與
key 只從 runtime env 讀。兩個 agent runtime 共用同一支。
_Avoid_: broker、upload helper、任意 gateway 呼叫

**handoff output**:
回覆包含目前 thread 的摘要，並可附上 Markdown handoff，讓人接續判斷或處理。這不代表 bot
已完成實作。
_Avoid_: 已套用的 patch、完成宣告

**skill catalog**:
`work-helper/.claude/skills` 整個目錄，以唯讀 mount 進 container。部署層不裁這份 catalog，
所以「skill 在 container 內讀得到」不等於「這個環境可以跑它」。哪些 skill 不准跑寫在
`agents/CLAUDE.md`，那是行為限制，不是 mount 或設定上的 allowlist。
_Avoid_: skill registry、registry allowlist、catalog 等於授權

**agent runtime**:
 container 內實際接 ACP 的 CLI。預設 OpenAB process 是 OpenCode（`opencode acp`）搭 OMO plugin；
  OMO 另可委派固定版本的 Claude Code ACP specialist。Claude ACP rollback 仍可透過
  `config/versions.env` 的 `OPENAB_AGENT_RUNTIME` 切換。首次需要時執行一次 `claude auth login`；
  之後由 OMO 委派。
_Avoid_: Claude 作為預設執行層、runtime npx download

**model roles**:
 單一 OpenAB container 使用 OpenCode 搭配 OMO remote profile；OMO 由 Luna 負責 retrieval、
 Terra 負責 synthesis，Claude Code 只作受控 specialist。每輪 OMO 不設 hard cap，但記錄 model、
 subagent 與 image calls 14 天並在異常時告警。這些角色服務 product-context bot，不改變 bot 的唯讀定位。
_Avoid_: Claude 作為預設執行層、因方便而 delegate

**runtime secret**:
container 內 agent process 拿得到的憑證，目前包含 Slack bot token 與公司 gateway key。它們
共用同一個失效邊界：沒有 broker、也沒有 token 隔離層。唯讀邊界靠 Slack allowlist、唯讀
snapshot mount 與 agent runtime 的 permission 設定維持，不靠 token 放在哪個 process。
_Avoid_: 已隔離、broker、upload helper

**Slack scope security debt**:
功能先上線不等於現有 Slack 實作已完成縮權。現有 Slack 過度 scope 是高優先 follow-up security
debt，必須持續追蹤至完成縮權。
_Avoid_: 已縮權、已完成安全邊界
