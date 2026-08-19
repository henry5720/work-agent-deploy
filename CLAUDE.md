# work-agent-deploy

這個 repo 部署 Slack 上的共享 backlog agent。它只做待辦查詢、repo偵察與草稿交付；產品實作和 GitHub issue發布留在 local。

## 先讀

1. `CONTEXT.md`：本 repo的角色與詞彙。
2. `docs/system-design.md`：需求、信任邊界、流程、明確不做與驗收情境。
3. `docs/adr/`：不容易從設定本身看懂的決策理由。
4. `docs/runbook.md`：只有部署或排障時需要讀。

## 兩份 CLAUDE.md 不同

- `/CLAUDE.md` 是給維護這個 deployment repo的 agent，也就是你正在讀的檔案。
- `/agents/CLAUDE.md` 會 mount成 container內 `/home/node/CLAUDE.md`，是 backlog agent的 runtime contract。

不要把維護指令寫進 `agents/CLAUDE.md`，也不要把 Slack runtime prompt塞進 root `CLAUDE.md`。

## 唯一正本

| 要改什麼 | 正本 |
|---|---|
| 領域詞彙 | `CONTEXT.md` |
| 系統行為與能力邊界 | `docs/system-design.md` |
| Container資源、mount與 image | `compose.yaml` |
| Slack allowlist、session與 agent process | `config/openab.toml` |
| Snapshot remote與基準 branch | `config/repos.conf` |
| Backlog agent行為 | `agents/CLAUDE.md` |
| Backlog agent可用的 skill | `work-helper/.claude/skills`（不在這個 repo） |
| Deployment host操作步驟 | `docs/runbook.md` |

同一個值若必須出現在文件和設定，設定是機器正本；文件要連回設定，不要另造可獨立修改的清單。

## 不可破壞的邊界

- Container不得取得 GitHub token、SSH key、Docker socket或可寫 repo checkout。
- Snapshot root以單一 mount掛成 `/home/node/code`，必須維持 read-only。Project資料中只有 `/home/node/drafts` 與 `/home/node/code/.index`（CodeGraph索引）可寫；repo源碼永遠不可寫。索引由 host維護，agent只能查詢。
- `WORK_HELPER_ISSUE_MODE` 必須是 `manual`。遠端 agent不建立 GitHub issue，也不執行驗收回報。
- GitHub SSH key只供 deployment host的 snapshot同步使用，不能進 Compose env或 volume。
- OpenAB image必須固定 immutable digest。升級時先確認新版本 Slack config與 multi-arch manifest，再同時更新 spec和驗證。
- Slack `allowed_users` 是權限設定。增刪 ID時要確認人的身分，不從顯示名稱猜。
- `allow_all_channels = true` 是為了讓未知 ID的 DM可用；channel邊界依賴 app invitation。改這一項前先讀 `docs/system-design.md` 的「互動入口」。

## 修改規則

- 不提交 `env/openab.env`、credentials、private key或真實 token。
- 改 Compose mount時，同步檢查 root filesystem、nested mount與 host目錄 ownership。
- 改 snapshot路徑或 branch時，同時更新 `config/repos.conf`、preflight與 runbook。
- 改 Slack能力時，同時檢查 bot events、OAuth scopes、OpenAB config及人工驗收情境。
- 不直接在 deployment host修 repo內檔案；這個 repo是部署設定的正本。
- 沒有使用者明確要求，不建立 remote、不 commit、不 push、不部署。

## 驗證

Local每次至少跑：

```bash
./tests/static.sh
bash -n scripts/*.sh tests/*.sh
docker compose -f compose.yaml config --quiet
```

有可用 deployment host secrets與 snapshots時，再跑：

```bash
./scripts/preflight.sh
```

涉及 runtime權限的改動，必須再跑 `docs/runbook.md` 的「驗證安全邊界」，不能只看 Compose render成功。
