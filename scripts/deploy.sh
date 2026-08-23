#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
load_env "$ROOT"
load_versions "$ROOT"

compose() { "$ROOT/scripts/compose.sh" "$@"; }

"$ROOT/scripts/preflight.sh"
compose build --pull
compose up -d --remove-orphans

compose exec -T backlog-agent python3 --version
compose exec -T backlog-agent git --version
compose exec -T backlog-agent /home/node/code/work-helper/bin/slack-list --help >/dev/null
compose exec -T backlog-agent sh -lc 'test -w /home/node/.openab && test -w /home/node/drafts'
compose exec -T backlog-agent sh -lc \
  'test -w /home/node/.claude &&
   touch /home/node/.claude/.deploy-write-probe &&
   rm /home/node/.claude/.deploy-write-probe'
compose exec -T backlog-agent sh -lc 'test -d /home/node/.claude/skills/slack-list && test ! -w /home/node/code'
# Home stays read-only under both runtimes. The writable directories OpenCode needs
# get one named volume each; widening /home/node instead would quietly make the
# read-only config, skills and snapshot mounts underneath it writable.
compose exec -T backlog-agent sh -lc 'test ! -w /home/node'

# 生圖路徑：兩個 runtime 共用同一支 CLI，所以這幾項不放在下面的 runtime 分支裡。
# 只驗它在、可執行、不可寫，以及 container env 有 gateway 設定；agent process 拿不拿
# 得到由 OpenAB config 的 inherit_env 決定，那由 tests/static.sh 比對。
# 這裡不對 gateway 發任何請求。
compose exec -T backlog-agent sh -lc \
  'command -v company-image >/dev/null &&
    company-image --help >/dev/null &&
    slack-thread-artifact --help >/dev/null &&
    test ! -w /usr/local/bin/slack-thread-artifact &&
    test ! -w /usr/local/bin/company-image'
compose exec -T backlog-agent sh -lc \
  'test -n "$COMPANY_GATEWAY_BASE_URL" && test -n "$COMPANY_GATEWAY_API_KEY"'

# OMO 的 Claude Code specialist 使用 image 內固定版本的 adapter 與 CLI；只驗存在與版本。
compose exec -T backlog-agent sh -lc \
  'test "$CLAUDE_AGENT_ACP_BIN" = /usr/local/bin/claude-agent-acp &&
   test -x "$CLAUDE_AGENT_ACP_BIN" &&
   test "$(command -v claude-agent-acp)" = "$CLAUDE_AGENT_ACP_BIN"'
compose exec -T backlog-agent sh -lc \
  "npm ls -g --depth=0 @agentclientprotocol/claude-agent-acp | grep -qF '@agentclientprotocol/claude-agent-acp@$CLAUDE_AGENT_ACP_VERSION'"
compose exec -T backlog-agent sh -lc \
  'test "$CLAUDE_CODE_EXECUTABLE" = /usr/local/bin/claude &&
   test -x "$CLAUDE_CODE_EXECUTABLE" &&
   "$CLAUDE_CODE_EXECUTABLE" --version | grep -qF "$CLAUDE_CODE_VERSION"'

# Runtime-specific checks. These read versions and paths inside the container;
# no Slack or gateway call is made here.
if [[ $OPENAB_AGENT_RUNTIME == opencode ]]; then
  compose exec -T backlog-agent sh -lc \
    "opencode --version | grep -qF '$OPENCODE_VERSION'"
  compose exec -T backlog-agent sh -lc \
    "npm ls -g --depth=0 oh-my-opencode-slim | grep -qF 'oh-my-opencode-slim@$OMO_VERSION'"
  # The OMO plugin resolves from the image, so /home/node/.cache only has to be
  # writable. Two directories must be writable as well: OPENCODE_CONFIG_DIR and
  # OpenCode's own state root /home/node/.opencode. OpenCode writes a `.gitignore`
  # and state into both, and a read-only one kills `opencode acp` at startup.
  # The committed config files stay read-only single-file mounts, so the agent
  # cannot rewrite provider or permission settings. The touch/rm probes write the
  # exact dotfile that failed in production, not a proxy for it.
  compose exec -T backlog-agent sh -lc \
    'test -r /home/node/.config/opencode/opencode.json &&
     test -r /home/node/.config/opencode/oh-my-opencode-slim.json &&
     test ! -w /home/node/.config/opencode/opencode.json &&
     test ! -w /home/node/.config/opencode/oh-my-opencode-slim.json &&
     test -w /home/node/.config/opencode &&
     touch /home/node/.config/opencode/.deploy-write-probe &&
     rm /home/node/.config/opencode/.deploy-write-probe &&
     test -w /home/node/.opencode &&
     touch /home/node/.opencode/.deploy-write-probe &&
     rm /home/node/.opencode/.deploy-write-probe &&
     test -w /home/node/.cache &&
     test -w /home/node/.local/share/opencode'
  compose exec -T backlog-agent sh -lc \
    'grep -q "^command = \"opencode\"" /etc/openab/config.toml &&
     grep -q "^args = \[\"acp\"\]" /etc/openab/config.toml'
else
  compose exec -T backlog-agent sh -lc \
    'grep -q "^command = \"/usr/local/bin/claude-agent-acp\"" /etc/openab/config.toml'
fi

compose ps

# preflight.sh 在 build 前已完成 R2 secret/host 檢查，並以 interactive gate 確認 lifecycle
# 與 Slack files:read；若沒有 TTY 或任一項未確認，deploy 在這裡就已中止。這支跑完仍不等於
# 這一版可以放給人用。上面每一條都是 container 內的存在性與權限檢查，
# 沒有一條打過 Claude、Slack、公司 gateway 或 STT，也沒有一條證明排程真的會觸發。
# 那些只能由人在有 secret 的環境做一次，做完才算 release。
cat <<'GATE'

Deploy finished. What it just verified: the container starts, the pinned runtime,
Claude ACP adapter and Claude Code CLI are the ones config/versions.env records, and
the required writable volumes are available. Preflight also confirmed the R2 host
and credentials are present and recorded the two manual prerequisite confirmations.

NOT VERIFIED HERE — manual release gate, see the "人工 release gate" section of
docs/runbook.md. Do not call this version released until every line is ticked off:
  1. Slack round trip: an authorised user gets an answer; an unauthorised one does not.
  2. slack-thread-artifact against real Slack: file lands in the original thread and
     the draft is deleted; force one failure and confirm the draft is kept.
  3. company-image against the real company gateway (this bills one call).
  4. Artifact cleanup: `./scripts/cleanup-artifacts.sh` by hand, then confirm the
     crontab entry exists and its log has no FAILED line.
  5. STT, only if [stt].enabled is true: one real audio file through the endpoint.
  6. Model inference against the real company gateway: one `opencode run --pure`
      against company/gpt-5.6-terra returns text, not HTTP 405. Nothing offline can
      prove the gateway accepts the route this config resolves to.
GATE
