# GitHub access stops at the host boundary

Backlog agent需要看 private repos，但不需要代表人修改 GitHub。我們讓 deployment host用專用 SSH身分更新唯讀 repo snapshots，container不取得 GitHub token或 SSH key；issue草稿回到 Slack由人或 local實作 agent發布。這犧牲即時 GitHub狀態、遠端 private issue查重與自動發布，換到 credential不受 prompt驅動 agent支配，且偵察與實作之間有可驗證的權限邊界。

## Consequences

- Snapshot可能落後 GitHub到下一次同步。
- 遠端只能提供指紋搜尋頁，不能聲稱完成 private issue查重。
- 建立 issue、修改 code、push與驗收回報都必須交給有 GitHub權限的 local流程。
