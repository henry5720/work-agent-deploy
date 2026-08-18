#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/scripts/preflight.sh"
docker compose -f "$ROOT/compose.yaml" pull
docker compose -f "$ROOT/compose.yaml" up -d --remove-orphans
docker compose -f "$ROOT/compose.yaml" ps
