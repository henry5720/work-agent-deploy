# Work Agent Deployment

這個 context 描述共享 backlog agent 與它周圍的人、資料和權限邊界。Slack 待辦本身的詞彙仍以 `work-helper` 的 `CONTEXT.md` 為準。

## Language

**backlog agent**:
Slack 上供多人共用、把既有待辦列準備到可決策狀態的 agent。它可以查現況與交付草稿，但不負責實作。
_Avoid_: work agent、implementation agent、bot

**維護 agent**:
修改這個 deployment repo、驗證設定並安排部署的 local agent。它不等於 container 裡的 backlog agent。
_Avoid_: backlog agent、遠端 agent

**授權使用者**:
可以向 backlog agent 發出指令的 Slack 人類成員。每位授權使用者擁有相同的遠端能力。
_Avoid_: 管理員、特定個人、PM

**互動入口**:
授權使用者能叫到 backlog agent 的 Slack 對話位置，包括 DM 與明確納入操作範圍的 channel。
_Avoid_: allowed channel、監聽範圍

**repo snapshot**:
供 backlog agent 偵察的唯讀 repo 視圖。它代表某個基準 branch 最近一次同步成功的內容，不是開發中的 checkout。
_Avoid_: clone、worktree、工作目錄

**deployment host**:
執行 backlog agent container、並持有 snapshot private key 與 Slack secrets 的實體主機。它本身不是 container，也不在任何虛擬化層之內。
_Avoid_: Incus instance、宿主、伺服器

**snapshot 同步者**:
唯一能從 GitHub 更新 repo snapshot、並維護 repo 索引的 host 身分。它不進入 backlog agent 的執行環境。
_Avoid_: agent GitHub 帳號、container credential

**repo 索引**:
CodeGraph 為每個 repo snapshot 建立的符號與呼叫關係資料庫，是 backlog agent 查現況的第一手依據。它由 snapshot 同步者維護，不屬於 repo 內容。
_Avoid_: 快取、cache、資料庫

**草稿交付**:
backlog agent 把 issue body 草稿、來源指紋與人工發布連結放回原待辦列的 item 留言串，交給核准者決定下一步。
_Avoid_: 開 issue、發布 issue、完成

**對話回覆**:
backlog agent 在 Slack 對問題的直接回答。預設用產品操作和使用者可觀察的結果說明；工程細節屬於草稿交付，除非提問者明確追問。
_Avoid_: 草稿、偵察報告、issue body

**實作 agent**:
在 local、有 GitHub 與可寫 repo 權限，接手已核准工作並修改 code 的 agent。
_Avoid_: backlog agent、維護 agent
