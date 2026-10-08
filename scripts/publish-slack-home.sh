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

api_call() {
  local endpoint=$1 payload=$2 raw
  API_STATUS=unknown
  if ! raw=$(curl -sS -w $'\n%{http_code}' "https://slack.com/api/$endpoint" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$payload"); then
    return 1
  fi
  API_STATUS=${raw##*$'\n'}
  API_BODY=${raw%$'\n'*}
  [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]
}

users=()
cursor=''
while :; do
  payload=$(jq -cn --arg cursor "$cursor" '{limit: 200, cursor: $cursor}')
  if ! api_call users.list "$payload"; then
    printf 'users.list request failed (HTTP %s or curl error)\n' "${API_STATUS:-unknown}" >&2
    exit 1
  fi
  if ! jq -e '.ok == true' >/dev/null <<<"$API_BODY"; then
    printf 'users.list failed: %s\n' "$(jq -r '.error // "invalid_response"' <<<"$API_BODY" 2>/dev/null || printf invalid_response)" >&2
    exit 1
  fi
  if ! jq -e '.members | type == "array"' >/dev/null <<<"$API_BODY"; then
    printf 'users.list returned an invalid members list\n' >&2
    exit 1
  fi
  mapfile -t page_users < <(jq -r '.members[] | select(.deleted != true and .is_bot != true and .is_app_user != true) | .id' <<<"$API_BODY")
  users+=("${page_users[@]}")
  cursor=$(jq -r '.response_metadata.next_cursor // empty' <<<"$API_BODY")
  [[ -n "$cursor" ]] || break
done

if ((${#users[@]} == 0)); then
  printf 'No eligible workspace users; nothing was published.\n' >&2
  exit 1
fi

successes=0
failures=0
for user in "${users[@]}"; do
  payload=$(jq -cn --arg user "$user" --argjson view "$view" \
    '{user_id: $user, view: $view}')
  if ! api_call views.publish "$payload"; then
    failures=$((failures + 1))
    printf 'Failed to publish Home for %s (HTTP %s or curl error)\n' "$user" "${API_STATUS:-unknown}" >&2
    printf 'Published: %d; failed: %d\n' "$successes" "$failures" >&2
    exit 1
  fi
  if ! jq -e '.ok == true' >/dev/null <<<"$API_BODY"; then
    failures=$((failures + 1))
    printf 'Failed to publish Home for %s: %s\n' "$user" \
      "$(jq -r '.error // "unknown_error"' <<<"$API_BODY")" >&2
    printf 'Published: %d; failed: %d\n' "$successes" "$failures" >&2
    exit 1
  fi
  successes=$((successes + 1))
  printf 'Published Slack Home for %s\n' "$user"
done
printf 'Published: %d; failed: %d\n' "$successes" "$failures"
