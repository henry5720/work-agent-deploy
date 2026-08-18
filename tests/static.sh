#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

test -f "$ROOT/CONTEXT.md"
test -f "$ROOT/CLAUDE.md"
test -f "$ROOT/.env.example"
test -f "$ROOT/docs/system-design.md"
test -f "$ROOT/docs/adr/0001-github-access-stops-at-the-host-boundary.md"
test -f "$ROOT/systemd/work-agent-snapshots@.service"
test -f "$ROOT/systemd/work-agent-snapshots@.timer"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/managed-claude-settings.json"
python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1], "rb")); assert c["slack"]["allow_all_users"] is False; assert len(c["slack"]["allowed_users"]) == 5; assert c["pool"] == {"max_sessions": 10, "session_ttl_hours": 4}' "$ROOT/config/openab.toml"

grep -q 'WORK_HELPER_ISSUE_MODE=manual' "$ROOT/env/openab.env.example"
grep -q '^\.env$' "$ROOT/.gitignore"
grep -q '^SNAPSHOT_ROOT=${HOME}/code$' "$ROOT/.env.example"
grep -q 'allow_all_users = false' "$ROOT/config/openab.toml"
grep -q 'assistant_mode = false' "$ROOT/config/openab.toml"
grep -q 'sha256:2b9fca58d898fdc5bceb2d48bcdd774287ece3352d6e3efbad7a213072232a89' "$ROOT/compose.yaml"
grep -q ':ro' "$ROOT/compose.yaml"
grep -Fq './agents/CLAUDE.md:/home/node/CLAUDE.md:ro' "$ROOT/compose.yaml"
if grep -Fq -- '- ./CLAUDE.md:/home/node/CLAUDE.md' "$ROOT/compose.yaml"; then
  printf 'Root CLAUDE.md must not be mounted into the container.\n' >&2
  exit 1
fi
for repo in work-helper work-docs teamsync-frontend teamsync-backend; do
  grep -q "}/$repo:/home/node/code/$repo:ro" "$ROOT/compose.yaml"
done
if git -C "$ROOT" grep -q -E 'xoxb-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|github_pat_' \
  -- . ':(exclude)tests/static.sh' ':(exclude)env/openab.env.example'; then
  printf 'A credential-like value is present in the repo.\n' >&2
  exit 1
fi

docker compose -f "$ROOT/compose.yaml" config --quiet
if git -C "$ROOT" grep -q -E 'nettop|Nettop|(^|[^[:alnum:]_])henry([^[:alnum:]_]|$)|(^|[^[:alnum:]_])Henry([^[:alnum:]_]|$)' \
  -- . ':(exclude)tests/static.sh' ':(exclude)config/repos.conf'; then
  printf 'A deployment host or user name is hard-coded in the repo.\n' >&2
  exit 1
fi

printf 'Static checks passed.\n'
