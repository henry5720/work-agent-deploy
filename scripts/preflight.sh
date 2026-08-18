#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-/srv/work-agent/repos}
ENV_FILE="$ROOT/env/openab.env"
STATE_DIR="$ROOT/runtime/openab"
DRAFT_DIR="$ROOT/runtime/drafts"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE (copy env/openab.env.example and fill secrets)"
[[ $(stat -c '%a' "$ENV_FILE") =~ ^(600|640)$ ]] || fail "$ENV_FILE must have mode 600 or 640"

for key in SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_LIST_ID WORK_HELPER_ISSUE_MODE; do
  grep -q "^${key}=." "$ENV_FILE" || fail "$key is missing from $ENV_FILE"
done
grep -q '^WORK_HELPER_ISSUE_MODE=manual$' "$ENV_FILE" || fail "WORK_HELPER_ISSUE_MODE must be manual"
grep -q '^SLACK_BOT_TOKEN=xoxb-' "$ENV_FILE" || fail "SLACK_BOT_TOKEN must start with xoxb-"
grep -q '^SLACK_APP_TOKEN=xapp-' "$ENV_FILE" || fail "SLACK_APP_TOKEN must start with xapp-"
! grep -q 'replace-me' "$ENV_FILE" || fail "$ENV_FILE still contains placeholder values"
[[ -w "$STATE_DIR" ]] || fail "$STATE_DIR is not writable"
[[ -w "$DRAFT_DIR" ]] || fail "$DRAFT_DIR is not writable"

while IFS='|' read -r name _ branch; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  repo="$SNAPSHOT_ROOT/$name"
  [[ -d "$repo/.git" ]] || fail "snapshot missing: $repo"
  [[ $(git -C "$repo" branch --show-current) == "$branch" ]] || fail "$name is not on $branch"
  [[ -z $(git -C "$repo" status --porcelain) ]] || fail "$name snapshot is dirty"
done < "$ROOT/config/repos.conf"

docker compose -f "$ROOT/compose.yaml" config --quiet
printf 'Preflight passed.\n'
