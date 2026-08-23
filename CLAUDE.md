# work-agent-deploy

這個 repo 部署 Slack 上的共享 product-context bot。它只做待辦查詢、repo偵察、草稿與 handoff 交付；產品實作和 GitHub issue發布留在 local。

## 先讀

1. `CONTEXT.md`：本 repo的角色與詞彙。
2. `docs/system-design.md`：需求、信任邊界、流程、明確不做與驗收情境。
3. `docs/adr/`：不容易從設定本身看懂的決策理由。
4. `docs/runbook.md`：只有部署或排障時需要讀。

## 兩份 CLAUDE.md 不同

- `/CLAUDE.md` 是給維護這個 deployment repo的 agent，也就是你正在讀的檔案。
- `/agents/CLAUDE.md` 會 mount成 container內 `/home/node/CLAUDE.md`，是 product-context bot 的 runtime contract。

不要把維護指令寫進 `agents/CLAUDE.md`，也不要把 Slack runtime prompt塞進 root `CLAUDE.md`。

## 唯一正本

| 要改什麼 | 正本 |
|---|---|
| 領域詞彙 | `CONTEXT.md` |
| 系統行為與能力邊界 | `docs/system-design.md` |
| 所有版本與 agent runtime 選擇 | `config/versions.env` |
| Container資源與 mount | `compose.yaml` |
| Slack allowlist、session與預設 agent process | `config/openab.toml` |
| Claude ACP rollback | `config/openab.claude-acp.toml`（`[slack]`／`[pool]`／`[reactions]` 必須與上面逐字相同） |
| OpenCode provider、模型、permission | `config/opencode/opencode.json` |
| OMO 模型分工 | `config/opencode/oh-my-opencode-slim.json` |
| Claude rollback 的 deny 規則 | `managed-claude-settings.json`（OpenCode runtime 下不生效） |
| 生圖／改圖能力邊界 | `agents/bin/company-image`（兩個 runtime 共用，改介面等於改能力） |
| Snapshot remote與基準 branch | `config/repos.conf` |
| Host 排程（snapshot 同步、artifact cleanup） | `scripts/lib.sh` 的 `render_crontab` |
| PM 在 Slack Home 看到的能力說明 | `config/slack-home.json`（改 `repos.conf` 要一起看這份） |
| Bot行為 | `agents/CLAUDE.md` |
| Bot可用的 skill | `work-helper/.claude/skills`（不在這個 repo，部署層不裁這份 catalog） |
| Deployment host操作步驟 | `docs/runbook.md` |

同一個值若必須出現在文件和設定，設定是機器正本；文件要連回設定，不要另造可獨立修改的清單。

## 不可破壞的邊界

- Container不得取得 GitHub token、SSH key、Docker socket或可寫 repo checkout。
- Snapshot root以單一 mount掛成 `/home/node/code`，必須維持 read-only。Project資料中只有 `/home/node/drafts` 與 `/home/node/code/.index`（CodeGraph索引）可寫；repo源碼永遠不可寫。索引由 host維護，agent只能查詢。
- `WORK_HELPER_ISSUE_MODE` 必須是 `manual`。遠端 agent不建立 GitHub issue，也不執行驗收回報。
- GitHub SSH key只供 deployment host的 snapshot同步使用，不能進 Compose env或 volume。
- OpenAB image必須固定 immutable digest，正本在 `config/versions.env`。升級時先確認新版本 Slack config與 multi-arch manifest，兩個 variant（`-opencode`、`-claude`）一起換，再同時更新 spec和驗證。
- Build不得出現 `latest`、`beta`、`stable` 或任何浮動 tag。所有 compose 指令走 `scripts/compose.sh`。
- `config/versions.env` 是唯一正本，環境變數不能覆蓋它。ambient 值和檔案不一致時 `load_versions` 直接中止；要不改檔案試另一個 runtime 只有 `./scripts/compose.sh --runtime <opencode|claude>` 這一條路。
- 生圖／改圖只走 `company-image`。不要加 endpoint、header、model、輸出路徑這類參數，也不要在文件裡教 agent 直接 `curl` gateway。理由見 `docs/adr/0008-restricted-company-image-cli.md`。
- Claude ACP 是 rollback，不是可刪的死路徑。`config/openab.claude-acp.toml` 要跟著 `config/openab.toml` 一起維護。
- Slack bot token 與公司 gateway key 共用同一個 container，這是已決定的取捨。不要在文件裡宣稱有 broker 或 token 隔離。
- 「產物回原本那個 Slack thread」只能寫成單一 container 內 OpenAB `sender_context`、agent 與受限 CLI 之間的信任約定，**不是安全保證**。不要升級成 token isolation、cryptographic binding 或防 prompt injection 的說法，也不要改成 broker／relay。理由見 `docs/adr/0009-thread-artifact-upload-and-optional-stt.md`。
- `agents/bin/` 兩支 CLI 的路徑處理不得回頭用 `resolve()` 或字串比對後再開檔。固定從 root 開 dirfd、逐段 `O_DIRECTORY|O_NOFOLLOW`；刪除用同一個 parent fd 並比對檔案 identity；寫入用 `O_CREAT|O_EXCL|O_NOFOLLOW` 加 temp→fsync→rename。`tests/artifact-path-safety.py` 會擋。
- 上傳失敗的 artifact 由 host crontab 收，不是由文件收。`scripts/cleanup-artifacts.sh` 必須維持呼叫 container 內的 `/home/node/code/work-helper/bin/slack-list cleanup`，刪除規則的正本在 work-helper，部署層不要自己寫第二份。
- `tests/static.sh` 與 `scripts/deploy.sh` 都不得聲稱驗過 Slack、公司 gateway、STT 或 cron 觸發。那些是 `docs/runbook.md`「人工 release gate」的項目。
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
./tests/static.sh                       # 含 tests/image-runtime.py
bash -n scripts/*.sh tests/*.sh
./scripts/compose.sh config --quiet
./scripts/compose.sh --runtime claude config --quiet
```

沒有 Docker 的機器上，`tests/static.sh` 會改用本機解析 `compose.yaml`，並在最後印出
「LIMITED VERIFICATION」列出沒驗到的項目。那不是 smoke test 通過，回報時要照實說。

有可用 deployment host secrets與 snapshots時，再跑：

```bash
./scripts/preflight.sh
```

涉及 runtime權限的改動，必須再跑 `docs/runbook.md` 的「驗證安全邊界」，不能只看 Compose render成功。

`tests/static.sh` 會跑三支 mocked 測試（`tests/image-runtime.py`、`tests/slack-thread-artifact.py`、
`tests/artifact-path-safety.py`），沒有一支呼叫 Slack 或公司 gateway。

跑得過**不代表**這一版可以放給人用。這些只有人工能驗，清單在 `docs/runbook.md`「人工 release gate」：

- 真的 Slack 往返與授權邊界。
- `slack-thread-artifact` 打真的 Slack（含刻意失敗一次確認留檔）。
- `company-image generate` 打真的公司 gateway（會計費）。
- artifact cleanup 的 crontab entry 真的觸發過（`artifact-cleanup.log` 沒有 `FAILED`）。
- STT（只有 `[stt].enabled = true` 時）。

回報時要照實說哪些沒驗到，不要把 `static.sh` 或 `deploy.sh` 退出 0 講成 smoke test 通過。
