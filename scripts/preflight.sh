#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
load_env "$ROOT"
load_versions "$ROOT"

SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-$HOME/work-agent-snapshots}
HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}
ENV_FILE="$ROOT/env/openab.env"
STATE_DIR="$ROOT/runtime/openab"
DRAFT_DIR="$ROOT/runtime/drafts"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE (copy env/openab.env.example and fill secrets)"
[[ $(stat -c '%a' "$ENV_FILE") =~ ^(600|640)$ ]] || fail "$ENV_FILE must have mode 600 or 640"

# The gateway credentials are required by both runtimes: OpenCode's `company`
# provider reads them for the model, and `company-image` reads them for image
# generation, which the Claude ACP rollback also has.
required_keys=(
  SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_LIST_ID WORK_HELPER_ISSUE_MODE
  COMPANY_GATEWAY_BASE_URL COMPANY_GATEWAY_API_KEY
)
for key in "${required_keys[@]}"; do
  grep -q "^${key}=." "$ENV_FILE" || fail "$key is missing from $ENV_FILE"
done
grep -q '^WORK_HELPER_ISSUE_MODE=manual$' "$ENV_FILE" || fail "WORK_HELPER_ISSUE_MODE must be manual"
grep -q '^SLACK_BOT_TOKEN=xoxb-' "$ENV_FILE" || fail "SLACK_BOT_TOKEN must start with xoxb-"
grep -q '^SLACK_APP_TOKEN=xapp-' "$ENV_FILE" || fail "SLACK_APP_TOKEN must start with xapp-"
# company-image refuses a plain-http gateway; catch it here instead of at the
# first Slack request for an image.
grep -q '^COMPANY_GATEWAY_BASE_URL=https://' "$ENV_FILE" ||
  fail "COMPANY_GATEWAY_BASE_URL must be an https URL"
! grep -q 'replace-me' "$ENV_FILE" || fail "$ENV_FILE still contains placeholder values"

# STT 是選配，且不是公司 gateway 的延伸假設。兩個值要嘛都沒有、要嘛都填；真正啟用
# 前還必須把兩份 OpenAB config 的 [stt].enabled 改成 true。
stt_base=$(grep -E '^STT_BASE_URL=' "$ENV_FILE" || true)
stt_key=$(grep -E '^STT_API_KEY=' "$ENV_FILE" || true)
if [[ -n ${stt_base#STT_BASE_URL=} || -n ${stt_key#STT_API_KEY=} ]]; then
  [[ -n ${stt_base#STT_BASE_URL=} && -n ${stt_key#STT_API_KEY=} ]] ||
    fail "STT_BASE_URL and STT_API_KEY must be set together"
  [[ $stt_base == STT_BASE_URL=https://* ]] || fail "STT_BASE_URL must be an https URL"
fi

# The runtime the build will actually produce. load_versions already rejected an
# unknown runtime, a floating image and a missing OpenAB config; these checks are
# about the files that config points at.
printf 'runtime: %s\nimage:   %s\nconfig:  %s\n' \
  "$OPENAB_AGENT_RUNTIME" "$OPENAB_IMAGE" "$OPENAB_CONFIG"
if [[ $OPENAB_AGENT_RUNTIME == opencode ]]; then
  for f in opencode.json oh-my-opencode-slim.json; do
    [[ -f "$ROOT/config/opencode/$f" ]] || fail "missing config/opencode/$f"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/config/opencode/$f" ||
      fail "config/opencode/$f is not valid JSON"
  done
fi

# The container runs as HOST_UID:HOST_GID (see Dockerfile), so the writable
# bind mounts must belong to that identity.
[[ $(stat -c '%u:%g' "$STATE_DIR") == "$HOST_UID:$HOST_GID" ]] || fail "$STATE_DIR must be owned by $HOST_UID:$HOST_GID"
[[ $(stat -c '%u:%g' "$DRAFT_DIR") == "$HOST_UID:$HOST_GID" ]] || fail "$DRAFT_DIR must be owned by $HOST_UID:$HOST_GID"
[[ $(id -u) == "$HOST_UID" ]] || fail "HOST_UID=$HOST_UID does not match the user running docker ($(id -u))"

# The whole snapshot root is mounted at /home/node/code, so nothing but managed
# snapshots may live in it.
[[ -d "$SNAPSHOT_ROOT" ]] || fail "snapshot root missing: $SNAPSHOT_ROOT (run scripts/install-sync-cron.sh)"
[[ -d "$SNAPSHOT_ROOT/work-helper/.claude/skills" ]] || fail "missing $SNAPSHOT_ROOT/work-helper/.claude/skills (skills are mounted from there)"
# Docker would create a missing bind source as root and the container could not
# write the index, so fail loudly instead.
[[ -d "$SNAPSHOT_ROOT/.index" ]] || fail "missing $SNAPSHOT_ROOT/.index (run scripts/update-snapshots.sh)"
[[ $(stat -c '%u:%g' "$SNAPSHOT_ROOT/.index") == "$HOST_UID:$HOST_GID" ]] || fail "$SNAPSHOT_ROOT/.index must be owned by $HOST_UID:$HOST_GID"

declare -A expected=()
while IFS='|' read -r name _ branch; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  expected[$name]=1
  repo="$SNAPSHOT_ROOT/$name"
  [[ -d "$repo/.git" ]] || fail "snapshot missing: $repo"
  [[ $(git -C "$repo" branch --show-current) == "$branch" ]] || fail "$name is not on $branch"
  [[ -z $(git -C "$repo" status --porcelain) ]] || fail "$name snapshot is dirty"
done < "$ROOT/config/repos.conf"

for entry in "$SNAPSHOT_ROOT"/*; do
  [[ -e "$entry" ]] || continue
  name=$(basename "$entry")
  [[ -n ${expected[$name]:-} ]] || fail "$entry is not listed in config/repos.conf but would be mounted"
done

"$ROOT/scripts/compose.sh" config --quiet
printf 'Preflight passed.\n'
