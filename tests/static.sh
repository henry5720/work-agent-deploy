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
test -f "$ROOT/docs/adr/0003-deploy-directly-on-the-fedora-host.md"
test -f "$ROOT/docs/adr/0004-schedule-snapshots-with-cron.md"
test ! -e "$ROOT/systemd"
test -x "$ROOT/scripts/install-sync-cron.sh"
test ! -e "$ROOT/scripts/install-sync-timer.sh"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/managed-claude-settings.json"
python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["type"] == "home"; assert v["blocks"]' "$ROOT/config/slack-home.json"
python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1], "rb")); assert c["slack"]["allow_all_users"] is False; assert len(c["slack"]["allowed_users"]) == 5; assert c["pool"] == {"max_sessions": 10, "session_ttl_hours": 4}; assert "workspace" not in c; assert c["agent"]["working_dir"] == "/home/node/code"' "$ROOT/config/openab.toml"

grep -q 'WORK_HELPER_ISSUE_MODE=manual' "$ROOT/env/openab.env.example"
grep -q '^\.env$' "$ROOT/.gitignore"
grep -q '^/runtime/$' "$ROOT/.gitignore"
grep -q '^SNAPSHOT_ROOT=${HOME}/work-agent-snapshots$' "$ROOT/.env.example"
grep -q '^HOST_UID=1000$' "$ROOT/.env.example"
grep -q '^HOST_GID=1000$' "$ROOT/.env.example"
grep -Fq 'load_env "$ROOT"' "$ROOT/scripts/preflight.sh"
grep -Fq "value=\${value//'\${HOME}'/\$HOME}" "$ROOT/scripts/lib.sh"
! grep -q -E '^(STATE_ROOT|DRAFT_ROOT)=' "$ROOT/.env.example"
grep -q 'allow_all_users = false' "$ROOT/config/openab.toml"
grep -q 'assistant_mode = false' "$ROOT/config/openab.toml"
grep -q 'CLAUDE_CONFIG_DIR: /home/node/.claude' "$ROOT/compose.yaml"
grep -q './runtime/openab:/home/node/.openab:z' "$ROOT/compose.yaml"
grep -q './runtime/drafts:/home/node/drafts:z' "$ROOT/compose.yaml"
grep -q 'views.publish' "$ROOT/scripts/publish-slack-home.sh"
grep -q 'sha256:2b9fca58d898fdc5bceb2d48bcdd774287ece3352d6e3efbad7a213072232a89' "$ROOT/Dockerfile"
grep -q 'apt-get install -y --no-install-recommends python3' "$ROOT/Dockerfile"
grep -q 'ARG HOST_UID=1000' "$ROOT/Dockerfile"
grep -Fq 'usermod -u "$HOST_UID"' "$ROOT/Dockerfile"
grep -q 'HOST_UID: ${HOST_UID:-1000}' "$ROOT/compose.yaml"
grep -q 'dockerfile: Dockerfile' "$ROOT/compose.yaml"
grep -q 'exec -T backlog-agent python3 --version' "$ROOT/scripts/deploy.sh"
grep -q 'slack-list --help' "$ROOT/scripts/deploy.sh"
grep -q 'test -w /home/node/.openab' "$ROOT/scripts/deploy.sh"
grep -Fq 'must be owned by $HOST_UID:$HOST_GID' "$ROOT/scripts/preflight.sh"
grep -q 'slack-list add' "$ROOT/agents/CLAUDE.md"
grep -q '建立指派給自己的待辦' "$ROOT/config/slack-home.json"
grep -Fq '不要執行 `fleet-worktree`' "$ROOT/agents/CLAUDE.md"
grep -Fq 'git show origin/<branch>:<path>' "$ROOT/agents/CLAUDE.md"
grep -Fq '不要 `git checkout` 或 `git switch`' "$ROOT/agents/CLAUDE.md"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["disableClaudeAiConnectors"] is True' "$ROOT/managed-claude-settings.json"
grep -Fq 'Bash(git checkout*)' "$ROOT/managed-claude-settings.json"
grep -Fq 'Bash(git switch*)' "$ROOT/managed-claude-settings.json"

# One mount for the whole snapshot root, one for the skills directory. Adding a
# repo must not require touching compose.yaml.
grep -Fq '${SNAPSHOT_ROOT:?set SNAPSHOT_ROOT in .env}:/home/node/code:ro,z' "$ROOT/compose.yaml"
grep -Fq '${SNAPSHOT_ROOT:?set SNAPSHOT_ROOT in .env}/work-helper/.claude/skills:/home/node/.claude/skills:ro,z' "$ROOT/compose.yaml"
if grep -q -E '/home/node/code/[A-Za-z0-9._-]+:ro' "$ROOT/compose.yaml"; then
  printf 'compose.yaml must not mount repos one by one.\n' >&2
  exit 1
fi
if grep -q -E '/home/node/\.claude/skills/[A-Za-z0-9._-]+' "$ROOT/compose.yaml"; then
  printf 'compose.yaml must not mount skills one by one.\n' >&2
  exit 1
fi
# CodeGraph: writable index outside the read-only tree, agent may only query.
grep -Fq '${SNAPSHOT_ROOT:?set SNAPSHOT_ROOT in .env}/.index:/home/node/code/.index:z' "$ROOT/compose.yaml"
grep -q 'CODEGRAPH_TELEMETRY: "0"' "$ROOT/compose.yaml"
grep -q 'npm i -g @colbymchenry/codegraph@' "$ROOT/Dockerfile"
grep -Fq 'ln -sfn "../.index/$name" "$target/.codegraph"' "$ROOT/scripts/update-snapshots.sh"
grep -Fq "grep -qxF '.codegraph'" "$ROOT/scripts/update-snapshots.sh"
grep -Fq 'codegraph explore' "$ROOT/agents/CLAUDE.md"
for sub in init index sync uninit daemon; do
  grep -Fq "Bash(codegraph $sub*)" "$ROOT/managed-claude-settings.json"
done

awk -F'|' '/^[^#]/ && NF { if ($1 !~ /^[A-Za-z0-9._-]+$/ || $2 !~ /^git@github\.com:/ || $3 !~ /^[A-Za-z0-9._\/-]+$/) exit 1 }' "$ROOT/config/repos.conf"

grep -q ':ro' "$ROOT/compose.yaml"
grep -Fq './agents/CLAUDE.md:/home/node/CLAUDE.md:ro,z' "$ROOT/compose.yaml"
if grep -Fq -- '- ./CLAUDE.md:/home/node/CLAUDE.md' "$ROOT/compose.yaml"; then
  printf 'Root CLAUDE.md must not be mounted into the container.\n' >&2
  exit 1
fi
if git -C "$ROOT" grep -q -E 'xoxb-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|github_pat_' \
  -- . ':(exclude)tests/static.sh' ':(exclude)env/openab.env.example'; then
  printf 'A credential-like value is present in the repo.\n' >&2
  exit 1
fi

SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-/nonexistent} docker compose -f "$ROOT/compose.yaml" config --quiet
if git -C "$ROOT" grep -q -E 'nettop|Nettop|(^|[^[:alnum:]_])henry([^[:alnum:]_]|$)|(^|[^[:alnum:]_])Henry([^[:alnum:]_]|$)' \
  -- . ':(exclude)tests/static.sh' ':(exclude)config/repos.conf'; then
  printf 'A deployment host or user name is hard-coded in the repo.\n' >&2
  exit 1
fi

printf 'Static checks passed.\n'
