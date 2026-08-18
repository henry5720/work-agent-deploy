#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
USER_NAME=${WORK_AGENT_USER:-$(id -un)}
GROUP_NAME=${WORK_AGENT_GROUP:-$(id -gn "$USER_NAME")}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
EXPECTED_ROOT="$USER_HOME/code/work-agent-deploy"
UNIT="work-agent-snapshots@$USER_NAME"

if [[ "$ROOT" != "$EXPECTED_ROOT" ]]; then
  printf 'Repo must be at %s for the systemd template (found %s)\n' "$EXPECTED_ROOT" "$ROOT" >&2
  exit 1
fi

sudo install -d -o "$USER_NAME" -g "$GROUP_NAME" /srv/work-agent/repos
sudo install -d -o "$USER_NAME" -g "$GROUP_NAME" "$ROOT/runtime/openab"
sudo install -d -o "$USER_NAME" -g "$GROUP_NAME" "$ROOT/runtime/drafts"
sudo install -m 0644 "$ROOT/systemd/work-agent-snapshots@.service" /etc/systemd/system/work-agent-snapshots@.service
sudo install -m 0644 "$ROOT/systemd/work-agent-snapshots@.timer" /etc/systemd/system/work-agent-snapshots@.timer
sudo systemctl daemon-reload
sudo systemctl enable --now "$UNIT.timer"
sudo systemctl start "$UNIT.service"
sudo systemctl status --no-pager "$UNIT.service"
