#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
load_env "$ROOT"

SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-$HOME/work-agent-snapshots}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/work-agent
SCHEDULE=${SNAPSHOT_SCHEDULE:-0 * * * *}
MARKER='# work-agent-snapshots'

# Create .index before any docker run, or Docker creates the bind source as root
# and a host user without sudo can no longer write the CodeGraph index.
mkdir -p "$SNAPSHOT_ROOT/.index" "$STATE_DIR" "$ROOT/runtime/openab" "$ROOT/runtime/drafts"
chmod 0750 "$ROOT/runtime/openab" "$ROOT/runtime/drafts"

# Rewrite our own line, leave every other crontab entry untouched.
{
  crontab -l 2>/dev/null | grep -vF "$MARKER" || true
  printf '%s SNAPSHOT_ROOT=%q %q %s\n' \
    "$SCHEDULE" "$SNAPSHOT_ROOT" "$ROOT/scripts/update-snapshots.sh" "$MARKER"
} | crontab -

printf 'Installed crontab entry:\n'
crontab -l | grep -F "$MARKER"

printf '\nRunning the first sync (this clones every repo in config/repos.conf)...\n'
SNAPSHOT_ROOT="$SNAPSHOT_ROOT" "$ROOT/scripts/update-snapshots.sh"
