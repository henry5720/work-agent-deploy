# work-agent-deploy

在一台 Linux deployment host 上部署共享的 Slack product-context bot。OpenAB 接 Slack Socket Mode，agent 只讀定期更新的 repo snapshot，能讀寫 Slack 待辦、偵察 repo 並交付 issue 草稿與 handoff；不能改 code、建立 GitHub issue 或 push。

## 架構

```text
Slack
  -> OpenAB (單一 container)
    -> opencode acp + oh-my-opencode-slim (最多 10 個 session，閒置 4 小時回收)
      -> 公司 OpenAI-compatible gateway (模型)
       -> company-image -> 公司 gateway 的 Responses image_generation (生圖，輸出 PNG 到 drafts)
       -> slack-thread-artifact -> 原 Slack thread（PNG／Markdown／HTML）
      -> /home/node/code/* (read-only snapshots，單一 mount)
      -> /home/node/code/.index (CodeGraph 索引，唯一可寫的 repo 相關路徑)
      -> /home/node/drafts (草稿，可寫)
      -> /home/node/.claude/skills (work-helper/.claude/skills 的 read-only mount)

deployment host
  -> crontab 每小時 fetch/reset snapshots，再用 runtime image 重建索引
  -> 專用 GitHub SSH key，只存在 host
```

Container 沒有 GitHub token、SSH key、Docker socket或可寫的 repo checkout。Runtime image由固定 multi-arch digest的 OpenAB image建置，加上 Python 3、git、CodeGraph 與 OMO，全部固定版本，不跟浮動 tag更新。

只有一個 container：沒有獨立 broker 或 relay。Slack bot token 與公司 gateway key
共用這個 container，這是目前部署的取捨。

## Agent runtime 與 Claude specialist

預設 `opencode acp`；OMO 可依 routing guidance 委派同一個 container 內、由 Docker image
固定安裝的 Claude Code ACP specialist。Claude ACP 仍保留完整 rollback，切換只改
[`config/versions.env`](config/versions.env) 的 `OPENAB_AGENT_RUNTIME`：

| 值 | base image | OpenAB config |
|---|---|---|
| `opencode`（預設） | `OPENAB_IMAGE_OPENCODE` | `config/openab.toml` |
| `claude` | `OPENAB_IMAGE_CLAUDE` | `config/openab.claude-acp.toml` |

specialist 的 `acpAgents.claude-code` 執行固定版 `/usr/local/bin/claude-agent-acp`，不使用 runtime
`npx` 下載。Claude login state 使用 `claude-credentials` named volume；首次需要時執行一次
`./scripts/compose.sh exec backlog-agent claude auth login`，之後由 OMO orchestrator 委派。

所有 compose 指令走 `./scripts/compose.sh`；直接 `docker compose` 會中止，因為版本只有
`config/versions.env` 一份正本。

## 輸入與輸出

| 方向 | 支援 | 不支援 |
|---|---|---|
| 輸入 | text、image、audio | PDF、Office、video、ZIP |
| 輸出 | PNG、Markdown、明確要求時的 self-contained HTML | patch、repo ZIP |

產物一律回原本的 Slack thread。

## Repo 內容

- `CONTEXT.md`：角色與領域詞彙，避免把 product-context bot、維護 agent和實作 agent混在一起。
- `CLAUDE.md`：給維護這個 deployment repo的 agent；不會 mount進 container。
- `docs/system-design.md`：完整系統設計 spec、信任邊界、流程與驗收情境。
- `.env.example`：snapshot root與 container使用者 uid/gid；複製成 root `.env`。
- `config/versions.env`：所有版本的正本 —— 兩個 OpenAB image digest、runtime 選擇、OpenCode／OMO／CodeGraph、Claude ACP adapter 與 Claude Code CLI 版本。
- `Dockerfile`：在固定 OpenAB image上加入 Python 3、git、CodeGraph、OMO、固定版 Claude ACP adapter 與 Claude Code CLI，並把 container使用者的 uid對齊 host。
- `compose.yaml`：單一 OpenAB container。
- `scripts/compose.sh`：所有 compose 指令的唯一入口，先載入 `.env` 與 `config/versions.env`。
- `config/openab.toml`：Slack allowlist、session pool，以及預設的 `opencode acp` agent。
- `config/openab.claude-acp.toml`：Claude ACP rollback；`[slack]` 等三節必須與上面逐字相同。
- `config/opencode/opencode.json`：OpenCode 的 provider、模型、instructions、skills 路徑與 permission。
- `config/opencode/oh-my-opencode-slim.json`：OMO preset（Terra synthesis／Luna retrieval）與 Claude Code ACP specialist。
- `agents/bin/company-image`：生圖／改圖的唯一入口，裝進 image 的受限 CLI，兩個 runtime 共用。
- `agents/bin/slack-thread-artifact`：把 drafts 的 PNG／Markdown／HTML 用 bot token 回原 Slack thread 的受限 CLI，兩個 runtime 共用。
- `tests/image-runtime.py`：用假 gateway 驗 `company-image` 的請求 shape、PNG 輸出與拒絕不合法輸入。
- `tests/slack-thread-artifact.py`：用假 Slack 驗 upload 三段流程的 header 與 body 編碼（兩個 Web API 呼叫送 form、bytes 那段不帶 token）、成功刪檔、失敗保留與拒絕不合法輸入。
- `config/slack-home.json`：授權使用者看到的 Slack Home功能首頁。
- `config/repos.conf`：snapshot 清單的正本，新增 repo只改這裡。
- `agents/CLAUDE.md`：遠端 bot 的行為邊界；兩個 runtime 共用同一份。
- `scripts/update-snapshots.sh`：host 端 clone/fetch/reset，並重建 CodeGraph 索引。
- `scripts/preflight.sh`：部署前檢查 secrets、版本 pin、目錄擁有權與 snapshot 狀態。
- `managed-claude-settings.json`：保留給 Claude rollback 使用的既有設定檔。
- `scripts/publish-slack-home.sh`：把 Home view發布給所有授權使用者。
- `scripts/install-sync-cron.sh`：建立目錄並寫入兩個每小時的 crontab entry（snapshot 同步、artifact cleanup）。
- `scripts/cleanup-artifacts.sh`：cron 呼叫的那一支，在 container 內執行 `slack-list cleanup` 收掉超過 24 小時的 artifact。
- `docs/runbook.md`：deployment host首次安裝、Slack 設定與日常操作。
- `docs/adr/`：不容易從設定本身看懂的決策理由。

AI agent修改前從 [`CLAUDE.md`](CLAUDE.md) 的閱讀順序開始。要理解系統目的而不是操作命令，讀 [`docs/system-design.md`](docs/system-design.md)。

## Local 驗證與 Smoke Test

```bash
./tests/static.sh          # 最後會跑兩支 runtime 的 mocked 測試
git diff --check
```

`tests/static.sh` 只做靜態檢查。沒有 Docker 的機器上它會改用本機解析 `compose.yaml`，並在最後印出
「LIMITED VERIFICATION」列出沒驗到的項目 —— 那不是 container smoke test 通過。它跑的三支 mocked
測試（`image-runtime.py`、`slack-thread-artifact.py`、`artifact-path-safety.py`）都不呼叫 Slack 或
公司 gateway。

`scripts/deploy.sh` 也只是多加了 container 內的存在性與權限檢查。真的 Slack 往返、真的生圖、STT 與
cleanup 排程是否觸發，都在 [`docs/runbook.md`](docs/runbook.md#人工-release-gate) 的「人工 release
gate」，**必須由人各跑一次**；`deploy.sh` 退出 0 不代表那些過了，它結束時會把清單再印一次。

Local與deployment host共用同一套 runtime設定，不另建 local Compose。Local smoke test自己建一份乾淨 snapshot，
不掛開發用的 checkout；state與drafts都放在被 Git忽略的 `runtime/`。完整命令見
[`docs/runbook.md`](docs/runbook.md#2-local-首次啟動)。

目標機器填好 secrets 並完成首次 snapshot sync 後，再跑：

```bash
./scripts/preflight.sh
./scripts/deploy.sh
```

完整步驟見 [`docs/runbook.md`](docs/runbook.md)。
