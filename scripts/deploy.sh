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
compose exec -T backlog-agent sh -lc 'test -d /home/node/.claude/skills/slack-list && test ! -w /home/node/code'

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

# Runtime-specific checks. These read versions and paths inside the container;
# no Slack or gateway call is made here.
if [[ $OPENAB_AGENT_RUNTIME == opencode ]]; then
  compose exec -T backlog-agent sh -lc \
    "opencode --version | grep -qF '$OPENCODE_VERSION'"
  compose exec -T backlog-agent sh -lc \
    "npm ls -g --depth=0 oh-my-opencode-slim | grep -qF 'oh-my-opencode-slim@$OMO_VERSION'"
  # The OMO plugin resolves from the image, so /home/node/.cache only has to be
  # writable. The config dir itself must be writable too: OpenCode writes its own
  # `.gitignore` and state there, and a read-only one kills `opencode acp` at
  # startup. The committed config files stay read-only single-file mounts, so the
  # agent cannot rewrite provider or permission settings. The touch/rm probe is
  # the exact operation that failed, not a proxy for it.
  compose exec -T backlog-agent sh -lc \
    'test -r /home/node/.config/opencode/opencode.json &&
     test -r /home/node/.config/opencode/oh-my-opencode-slim.json &&
     test ! -w /home/node/.config/opencode/opencode.json &&
     test ! -w /home/node/.config/opencode/oh-my-opencode-slim.json &&
     test -w /home/node/.config/opencode &&
     touch /home/node/.config/opencode/.deploy-write-probe &&
     rm /home/node/.config/opencode/.deploy-write-probe &&
     test -w /home/node/.cache &&
     test -w /home/node/.local/share/opencode'
  compose exec -T backlog-agent sh -lc \
    'grep -q "^command = \"opencode\"" /etc/openab/config.toml &&
     grep -q "^args = \[\"acp\"\]" /etc/openab/config.toml'
else
  compose exec -T backlog-agent sh -lc 'command -v claude-agent-acp >/dev/null'
  compose exec -T backlog-agent sh -lc \
    'grep -q "^command = \"claude-agent-acp\"" /etc/openab/config.toml'
fi

compose ps

# 這支跑完不等於這一版可以放給人用。上面每一條都是 container 內的存在性與權限檢查，
# 沒有一條打過 Slack、公司 gateway 或 STT，也沒有一條證明排程真的會觸發。
# 那些只能由人在有 secret 的環境做一次，做完才算 release。
cat <<'GATE'

Deploy finished. What it just verified: the container starts, the pinned runtime is
the one config/versions.env records, and the read-only / writable boundaries hold.

NOT VERIFIED HERE — manual release gate, see the "人工 release gate" section of
docs/runbook.md. Do not call this version released until every line is ticked off:
  1. Slack round trip: an authorised user gets an answer; an unauthorised one does not.
  2. slack-thread-artifact against real Slack: file lands in the original thread and
     the draft is deleted; force one failure and confirm the draft is kept.
  3. company-image against the real company gateway (this bills one call).
  4. Artifact cleanup: `./scripts/cleanup-artifacts.sh` by hand, then confirm the
     crontab entry exists and its log has no FAILED line.
  5. STT, only if [stt].enabled is true: one real audio file through the endpoint.
GATE
