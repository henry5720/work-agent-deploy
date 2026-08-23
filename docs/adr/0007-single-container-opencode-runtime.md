# 用單一受限 container 跑 OpenCode + OMO，加入 Claude ACP specialist

## Status

Accepted（已決定）。Amends [0006](0006-readonly-product-context-handoff-bot.md)。

## Background

[0006](0006-readonly-product-context-handoff-bot.md) 決定 bot 是唯讀的 product-context/handoff
bot，遠端跑 OpenCode 搭 oh-my-opencode-slim（OMO）。但它同時寫了一個 image-artifact broker：
一個受限的 local MCP，持有公司 gateway 與 Slack 憑證，讓 agent 本身不碰 token。

實際要做的是先驗證 OpenCode + OMO 這條路走不走得通。多加一個 broker process 等於同時驗兩件
事，而 broker 帶來的隔離也有限 —— agent 仍然可以請 broker 貼任何內容到 Slack，token 不在
agent 手上並不改變它能做什麼。

另一件事是版本。原本 `Dockerfile` 只固定 OpenAB image 一個 digest，OpenCode、OMO 與 CodeGraph
的版本散在 Dockerfile 各行，換 runtime 時沒有一個地方可以一次看完該審哪些版本。

## Decision

- 遠端只跑一個受限 container，不建 broker、relay 或 upload helper。Slack token 與公司 gateway
  key 都用 env 進同一個 container，由 OpenAB 依 `inherit_env` 傳給 agent process。
- 不追求 Slack token 隔離。實際邊界是 Slack allowlist、唯讀 snapshot mount、OpenCode 的
  `permission` 設定與 agent 規則，不是 token 放在哪個 process。
- OpenAB 預設 agent 改成 `opencode acp`（`config/openab.toml`）。
- Claude ACP adapter 以固定版本的 `@agentclientprotocol/claude-agent-acp` 安裝在同一個 image，
  作為 OMO 可委派的 specialist；Claude Code CLI 也由 Docker 以 exact version 安裝到
  `/usr/local/bin/claude`。
  `config/openab.claude-acp.toml` 仍保留為完整 rollback，切換只改 `config/versions.env` 的
  `OPENAB_AGENT_RUNTIME`，image 與 config 會一起換。specialist 不使用 runtime `npx` download。
  兩份 config 的 `[slack]`、`[pool]`、`[reactions]` 必須逐字相同，由 `tests/static.sh` 比對。
- 所有版本集中在 `config/versions.env`，包含兩個 OpenAB image 的 immutable digest、
  OpenCode、OMO、CodeGraph、Claude ACP adapter 與 Claude Code CLI 的數字版本。build 不得
  使用 `latest`、`beta`、`stable`。
  `docker compose` 只能透過 `scripts/compose.sh` 進入，直接呼叫會因缺變數而中止。
- OpenCode 與 OMO 的遠端設定維持最小：`config/opencode/opencode.json` 只設 provider、模型、
  instructions、skills 路徑與 permission；`config/opencode/oh-my-opencode-slim.json` 只設
  preset 模型分工、Claude ACP specialist 與關掉 container 內用不到的功能。
- 不在部署層裁 catalog。skills 仍是 `work-helper/.claude/skills` 整個目錄的唯讀 mount，OMO 的
  agent 都保留 `skills: ["*"]` 與 `mcps: ["*"]`。行為限制寫在 `agents/CLAUDE.md`，不用
  mount-level 或 config-level 的 allowlist 表達。
- Slack v1 的輸入限於 text、image、audio；輸出限於 PNG、Markdown，以及使用者明確要求時的
  self-contained HTML。產物一律回原 Slack thread。

## Consequences

- 只有一個 container 要建、要驗、要排障，OpenCode + OMO 能不能用可以單獨判斷。
- 代價是所有 runtime secret 共用一個失效邊界：container 被攻破等於 Slack bot token 與 gateway
  key 同時外洩。這是明確接受的取捨。
- Rollback 是一個變數的事，而且 rollback config 會被測試盯著不漂移；也代表兩份 OpenAB
  config 要一起維護。
- 版本集中在一個檔案讓升級 review 有唯一入口，Dockerfile 會在 build 時驗證 base image 內的
  OpenCode 版本等於 `OPENCODE_VERSION`，digest 換了卻忘了改版本會 build 失敗。
- 強制走 `scripts/compose.sh` 讓版本不可繞過，但也代表所有既有的 `docker compose` 手動指令
  都要改，`docs/runbook.md` 是唯一正本。
- 不裁 catalog 讓 `work-helper` 新增 skill 不必改這個 repo，代價是環境跑不動的 skill 只能靠
  `agents/CLAUDE.md` 的文字擋，不是靠設定擋。
- Claude specialist 與 rollback 共用既有的 `claude-credentials` named volume，保存 Claude
  credential/state。首次需要時執行一次 `claude auth login`，之後由 OMO 委派。不新增 container、
  broker 或 relay。
