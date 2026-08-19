#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

test -f "$ROOT/CONTEXT.md"
test -f "$ROOT/CLAUDE.md"
test -f "$ROOT/Dockerfile"
test -f "$ROOT/.env.example"
test -f "$ROOT/docs/system-design.md"
test -f "$ROOT/config/slack-home.json"
test -f "$ROOT/docs/adr/0001-github-access-stops-at-the-host-boundary.md"
test -f "$ROOT/docs/adr/0002-run-the-deployment-host-inside-restricted-incus.md"
test -f "$ROOT/systemd/work-agent-snapshots@.service"
test -f "$ROOT/systemd/work-agent-snapshots@.timer"
grep -Fq 'WorkingDirectory=~' "$ROOT/systemd/work-agent-snapshots@.service"
grep -Fq 'exec "$HOME/code/work-agent-deploy/scripts/update-snapshots.sh"' "$ROOT/systemd/work-agent-snapshots@.service"
! grep -Fq '%h/code/work-agent-deploy' "$ROOT/systemd/work-agent-snapshots@.service"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/managed-claude-settings.json"
python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["type"] == "home"; assert v["blocks"]' "$ROOT/config/slack-home.json"
python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1], "rb")); assert c["slack"]["allow_all_users"] is False; assert len(c["slack"]["allowed_users"]) == 5; assert c["pool"] == {"max_sessions": 10, "session_ttl_hours": 4}' "$ROOT/config/openab.toml"

grep -q 'WORK_HELPER_ISSUE_MODE=manual' "$ROOT/env/openab.env.example"
grep -q '^\.env$' "$ROOT/.gitignore"
grep -q '^/runtime/$' "$ROOT/.gitignore"
grep -q '^SNAPSHOT_ROOT=${HOME}/code$' "$ROOT/.env.example"
grep -Fq 'done < "$ROOT/.env"' "$ROOT/scripts/preflight.sh"
grep -Fq "SNAPSHOT_ROOT=\${SNAPSHOT_ROOT//'\${HOME}'/\$HOME}" "$ROOT/scripts/preflight.sh"
! grep -q -E '^(STATE_ROOT|DRAFT_ROOT)=' "$ROOT/.env.example"
grep -q 'allow_all_users = false' "$ROOT/config/openab.toml"
grep -q 'assistant_mode = false' "$ROOT/config/openab.toml"
grep -q 'CLAUDE_CONFIG_DIR: /home/node/.claude' "$ROOT/compose.yaml"
grep -q './runtime/openab:/home/node/.openab' "$ROOT/compose.yaml"
grep -q './runtime/drafts:/home/node/drafts' "$ROOT/compose.yaml"
grep -q 'views.publish' "$ROOT/scripts/publish-slack-home.sh"
grep -q 'sha256:2b9fca58d898fdc5bceb2d48bcdd774287ece3352d6e3efbad7a213072232a89' "$ROOT/Dockerfile"
grep -q 'apt-get install -y --no-install-recommends python3' "$ROOT/Dockerfile"
grep -q 'dockerfile: Dockerfile' "$ROOT/compose.yaml"
grep -q 'exec -T backlog-agent python3 --version' "$ROOT/scripts/deploy.sh"
grep -q 'slack-list --help' "$ROOT/scripts/deploy.sh"
grep -q 'test -w /home/node/.openab' "$ROOT/scripts/deploy.sh"
grep -q "must be owned by container user 1000:1000" "$ROOT/scripts/preflight.sh"
grep -q 'slack-list add' "$ROOT/agents/CLAUDE.md"
grep -q '建立指派給自己的待辦' "$ROOT/config/slack-home.json"
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
