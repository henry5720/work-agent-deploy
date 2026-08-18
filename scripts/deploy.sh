#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/scripts/preflight.sh"
docker compose -f "$ROOT/compose.yaml" build --pull
docker compose -f "$ROOT/compose.yaml" up -d --remove-orphans
docker compose -f "$ROOT/compose.yaml" exec -T backlog-agent python3 --version
docker compose -f "$ROOT/compose.yaml" exec -T backlog-agent /home/node/code/work-helper/bin/slack-list --help >/dev/null
docker compose -f "$ROOT/compose.yaml" exec -T backlog-agent sh -lc 'test -w /home/node/.openab && test -w /home/node/drafts'
docker compose -f "$ROOT/compose.yaml" ps
