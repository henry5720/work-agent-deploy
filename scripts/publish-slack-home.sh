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
: "${SLACK_TEAM_ID:?SLACK_TEAM_ID is required}"
: "${SLACK_LIST_ID:?SLACK_LIST_ID is required}"

# The view references ${SLACK_TEAM_ID}/${SLACK_LIST_ID} in the list deep link. Substitute
# from env instead of copying the IDs into the JSON: env/openab.env is the machine source of
# truth, and a second copy here would drift the moment the list moves.
view=$(python3 -c \
  'import json,os,string,sys; print(string.Template(open(sys.argv[1]).read()).substitute(os.environ), end="")' \
  "$VIEW_FILE")

mapfile -t users < <(python3 -c \
  'import sys,tomllib; print(*tomllib.load(open(sys.argv[1], "rb"))["slack"]["allowed_users"], sep="\n")' \
  "$ROOT/config/openab.toml")

for user in "${users[@]}"; do
  payload=$(jq -cn --arg user "$user" --argjson view "$view" \
    '{user_id: $user, view: $view}')
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
