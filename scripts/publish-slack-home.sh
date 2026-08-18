#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="$ROOT/env/openab.env"
VIEW_FILE="$ROOT/config/slack-home.json"

[[ -f "$ENV_FILE" ]] || { printf 'Missing %s\n' "$ENV_FILE" >&2; exit 1; }
[[ -f "$VIEW_FILE" ]] || { printf 'Missing %s\n' "$VIEW_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN is required}"

mapfile -t users < <(python3 -c \
  'import sys,tomllib; print(*tomllib.load(open(sys.argv[1], "rb"))["slack"]["allowed_users"], sep="\n")' \
  "$ROOT/config/openab.toml")

for user in "${users[@]}"; do
  payload=$(jq -cn --arg user "$user" --slurpfile view "$VIEW_FILE" \
    '{user_id: $user, view: $view[0]}')
  response=$(curl -fsS https://slack.com/api/views.publish \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$payload")
  if ! jq -e '.ok == true' >/dev/null <<<"$response"; then
    printf 'Failed to publish Home for %s: %s\n' "$user" \
      "$(jq -r '.error // "unknown_error"' <<<"$response")" >&2
    exit 1
  fi
  printf 'Published Slack Home for %s\n' "$user"
done
