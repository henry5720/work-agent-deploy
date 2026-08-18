# work-agent-deploy

在一台 Linux deployment host 上部署共享 Slack backlog agent。OpenAB 接 Slack Socket Mode，Claude Code 只讀四個定期更新的 repo snapshot，能讀寫 Slack 待辦、偵察 repo 並交付 issue 草稿；不能改 code、建立 GitHub issue 或 push。

## 架構

```text
Slack
  -> OpenAB 0.10.0-beta.3
    -> Claude Code (最多 10 個 session，閒置 4 小時回收)
      -> /home/node/code/* (read-only snapshots)
      -> work-helper/drafts (唯一可寫的工作目錄)

deployment host
  -> systemd timer 每 5 分鐘 fetch/reset snapshots
  -> 專用 GitHub SSH key，只存在 host
```

Container 沒有 GitHub token、SSH key、Docker socket或可寫的 repo checkout。OpenAB image 以 multi-arch digest 固定，不跟浮動 tag 更新。

## Repo 內容

- `CONTEXT.md`：角色與領域詞彙，避免把 backlog agent、維護 agent和實作 agent混在一起。
- `CLAUDE.md`：給維護這個 deployment repo的 agent；不會 mount進 container。
- `docs/system-design.md`：完整系統設計 spec、信任邊界、流程與驗收情境。
- `.env.example`：Local Docker Compose的 host mount路徑範本；複製成 root `.env` 後自動載入。
- `compose.yaml`：單一 OpenAB + Claude Code container。
- `config/openab.toml`：Slack allowlist、session pool、workspace aliases。
- `config/repos.conf`：四個 snapshot 的 remote 與基準 branch。
- `agents/CLAUDE.md`：遠端 backlog agent 的行為邊界。
- `scripts/update-snapshots.sh`：host 端 clone/fetch/reset。
- `systemd/`：每 5 分鐘更新 snapshots。
- `docs/runbook.md`：deployment host首次安裝、Slack 設定與日常操作。

AI agent修改前從 [`CLAUDE.md`](CLAUDE.md) 的閱讀順序開始。要理解系統目的而不是操作命令，讀 [`docs/system-design.md`](docs/system-design.md)。

## Local 驗證與 Smoke Test

```bash
./tests/static.sh
git diff --check
```

Local與deployment host共用同一套 runtime設定，不另建 local Compose。Local smoke test用 root `.env`
把 snapshots、state與drafts改指向使用者目錄；完整命令見 [`docs/runbook.md`](docs/runbook.md#local-smoke-test)。

目標機器填好 secrets 並完成首次 snapshot sync 後，再跑：

```bash
./scripts/preflight.sh
./scripts/deploy.sh
```

完整步驟見 [`docs/runbook.md`](docs/runbook.md)。
