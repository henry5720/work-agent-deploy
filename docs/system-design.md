# Shared Backlog Agent System Design

## 目標

在 Slack 提供一個多人共用的 backlog agent，讓授權使用者能直接查待辦、讀 repo、偵察既有待辦列並取得可 review 的 issue 草稿，不必經由另一個人轉述。

這個 agent 停在 backlog 層。它不修改產品 code、不建立 GitHub issue、不 push，也不通知 PM 驗收。

## 角色

| 角色 | 能做什麼 | 不能做什麼 |
|---|---|---|
| 授權使用者 | 從 Slack 發問、要求偵察、核准或退回草稿 | 透過遠端 agent 修改 code或取得 GitHub credential |
| backlog agent | 讀 Slack 待辦與 repo snapshot、交付草稿 | 實作、建立 issue、查 private issues、回報驗收 |
| snapshot 同步者 | 在 deployment host 從 GitHub 更新 snapshots | 進入 container或代表 agent發布內容 |
| 實作 agent | 在 local 建 issue、修改 code、測試、push、回報驗收 | 假裝遠端草稿已核准或已實作 |

Slack 待辦角色如回報對象、核准者、負責人，沿用 `work-helper/CONTEXT.md` 的定義。

## 系統邊界

```text
授權使用者
  -> Slack DM / private channel / item 留言串
    -> OpenAB
      -> Claude Code backlog agent
        -> Slack Lists API
        -> 唯讀 repo snapshots
        -> 可寫 drafts 目錄

GitHub
  -> deployment host 的 snapshot 同步者
    -> 唯讀 repo snapshots

local 實作 agent
  -> GitHub issues / 可寫 worktree / push
```

GitHub credential只到 deployment host 與 local 實作環境，不跨進 backlog agent container。詳見 [`adr/0001-github-access-stops-at-the-host-boundary.md`](adr/0001-github-access-stops-at-the-host-boundary.md)。

## 互動入口

第一版支援：

- 授權使用者與 Slack app 的 DM。
- private channel `C0BPZRN6H3R`。
- Bug/需求總表 item 留言所在的 backing channel `C0B9PSESQ2U`。

只有 `config/openab.toml` 明列的 Slack user ID能驅動 agent。OpenAB `0.10.0-beta.3` 會把 channel allowlist也套到 DM channel ID，而 DM ID事前未知，因此 channel gate保持開放，實際 channel邊界由「只把 app 邀進上述兩個 channel」維持。新增 app所在 channel等於擴大互動入口，必須當成權限變更 review。

所有授權使用者的遠端能力相同。核准草稿不代表負責實作，也不會讓核准者取得 GitHub credential。

## Repo Snapshots

| Snapshot | 基準 branch |
|---|---|
| `work-helper` | `main` |
| `work-docs` | `main` |
| `teamsync-frontend` | `dev` |
| `teamsync-backend` | `master` |

Host定期 fetch所有 remote refs，再把每個 working snapshot reset到基準 branch。Container以 read-only bind mount看見 snapshots；所有 OpenAB sessions共用同一份內容。

Snapshot代表最近一次同步成功的狀態，不保證和 GitHub當下完全同步。偵察結論若依賴剛 push的 commit，必須先確認 snapshot同步完成。

## 待辦流程

### 從 item 留言串開始

1. OpenAB提供 sender、channel與thread context。
2. backlog agent用 `slack-list context` 反查唯一的待辦列。
3. agent讀待辦列、完整 item 留言串與相關 repo snapshots。
4. agent依 `fleet-recon` 規則寫 issue body草稿。
5. agent用 `slack-list draft` 把 Markdown附件、來源指紋搜尋頁與 New issue頁放回同一個 item 留言串。
6. 核准者決定建立任務、直接派工或退回修改。

### 從 DM 或一般 channel 開始

口述需求不能直接變成草稿。backlog agent必須先找到對應的既有待辦列；找不到時，請使用者先建立待辦列。這條限制確保每份草稿都有 Slack來源指紋與回報對象。

### 「我的待辦」

這是多人共用的 agent，不能用固定的個人 ID判斷「我」。必須把當次
`openab.sender.v1.sender_id` 傳給 `slack-list assigned`，精確比對待辦列的 assignee user ID。

## 草稿邊界

草稿交付不是 issue發布，也不是 GitHub查重完成。遠端環境只能提供 GitHub搜尋頁供核准者人工確認；不能聲稱 private issue不存在。

草稿是消耗品。核准者看完後應選擇建立任務、當天直接派工或退回修改，不把 drafts目錄養成第二套 backlog。

## 執行與持久化

- 一個 OpenAB instance，共用最多 10 個 sessions。
- 閒置 session 4 小時後回收。
- Claude Code login存在獨立 credential volume。
- OpenAB state與草稿存在 deployment host，不隨 container重建刪除。
- Project資料中只有 drafts可寫；repo snapshots全部唯讀。
- OpenAB image使用固定 multi-arch digest，不跟浮動 tag更新。

## 明確不做

- 不把 GitHub token、SSH key或 Docker socket放進 container。
- 不讓 backlog agent clone、fetch、建立 branch/worktree、commit或 push。
- 不讓 backlog agent執行 `slack-list ready` 或宣告驗收。
- 不自動把草稿發布成 GitHub issue。
- 不為每位授權使用者部署獨立 agent instance。
- 第一版不支援 Slack slash commands或 Slack AI assistant mode。

## 驗收情境

1. 授權使用者能從 DM查 repo；未授權使用者的訊息被拒絕。
2. 授權使用者能在指定 private channel @ agent，後續在同一 thread繼續對話。
3. 在待辦列的 item 留言串 @ agent時，agent能反查正確 `Rec...`，不要求人再貼 ID。
4. 偵察完成後，item 留言串收到 Markdown草稿與人工 GitHub連結，待辦狀態不變。
5. Container內四個 snapshots不可寫，drafts可寫，且沒有可用的 GitHub auth或 SSH key。
6. Host同步後，所有新 sessions讀到同一個基準 branch版本。

## 人工前置作業

- Slack app重新安裝並取得 `xapp-...`、新 `xoxb-...`。
- 將 app顯示名稱改為「派大星教授加博士先生」。
- 把 host專用 GitHub SSH public key加入一個能讀四個 private repos的 GitHub帳號。
- 在 container內完成 Claude Code subscription login。

實際操作命令見 [`runbook.md`](runbook.md)。
