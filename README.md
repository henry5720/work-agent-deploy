# work-agent-deploy

在一台 Linux deployment host 上部署共享 Slack backlog agent。OpenAB 接 Slack Socket Mode，Claude Code 只讀定期更新的 repo snapshot，能讀寫 Slack 待辦、偵察 repo 並交付 issue 草稿；不能改 code、建立 GitHub issue 或 push。

## 架構

```text
Slack
  -> OpenAB 0.10.0-beta.3
    -> Claude Code (最多 10 個 session，閒置 4 小時回收)
      -> /home/node/code/* (read-only snapshots，單一 mount)
      -> /home/node/code/.index (CodeGraph 索引，唯一可寫的 repo 相關路徑)
      -> /home/node/drafts (草稿，可寫)
      -> /home/node/.claude/skills (work-helper/.claude/skills 的 read-only mount)

deployment host
  -> crontab 每小時 fetch/reset snapshots，再用 runtime image 重建索引
  -> 專用 GitHub SSH key，只存在 host
```

Container 沒有 GitHub token、SSH key、Docker socket或可寫的 repo checkout。Runtime image由固定 multi-arch digest的 OpenAB image加上 Python 3建置，不跟浮動 OpenAB tag更新。

## Repo 內容

- `CONTEXT.md`：角色與領域詞彙，避免把 backlog agent、維護 agent和實作 agent混在一起。
- `CLAUDE.md`：給維護這個 deployment repo的 agent；不會 mount進 container。
- `docs/system-design.md`：完整系統設計 spec、信任邊界、流程與驗收情境。
- `.env.example`：snapshot root與 container使用者 uid/gid；複製成 root `.env` 後由 Compose自動載入。
- `Dockerfile`：在固定 OpenAB image上加入 `slack-list` 所需的 Python 3與 CodeGraph，並把 container使用者的 uid對齊 host。
- `compose.yaml`：單一 OpenAB + Claude Code container。
- `config/openab.toml`：Slack allowlist與 session pool。
- `config/slack-home.json`：授權使用者看到的 Slack Home功能首頁。
- `config/repos.conf`：snapshot 清單的正本，新增 repo只改這裡。
- `agents/CLAUDE.md`：遠端 backlog agent 的行為邊界。
- `scripts/update-snapshots.sh`：host 端 clone/fetch/reset，並重建 CodeGraph 索引。
- `scripts/preflight.sh`：部署前檢查 secrets、目錄擁有權與 snapshot 狀態。
- `managed-claude-settings.json`：container 內 Claude Code 的 deny 規則（`gh`、寫入類 git、重建索引）。
- `scripts/publish-slack-home.sh`：把 Home view發布給所有授權使用者。
- `scripts/install-sync-cron.sh`：建立目錄並寫入每小時同步的 crontab entry。
- `docs/runbook.md`：deployment host首次安裝、Slack 設定與日常操作。
- `docs/adr/`：不容易從設定本身看懂的決策理由。

AI agent修改前從 [`CLAUDE.md`](CLAUDE.md) 的閱讀順序開始。要理解系統目的而不是操作命令，讀 [`docs/system-design.md`](docs/system-design.md)。

## Local 驗證與 Smoke Test

```bash
./tests/static.sh
git diff --check
```

Local與deployment host共用同一套 runtime設定，不另建 local Compose。Local smoke test自己建一份乾淨 snapshot，
不掛開發用的 checkout；state與drafts都放在被 Git忽略的 `runtime/`。完整命令見
[`docs/runbook.md`](docs/runbook.md#2-local-首次啟動)。

目標機器填好 secrets 並完成首次 snapshot sync 後，再跑：

```bash
./scripts/preflight.sh
./scripts/deploy.sh
```

完整步驟見 [`docs/runbook.md`](docs/runbook.md)。
