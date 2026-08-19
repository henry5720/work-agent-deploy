#!/usr/bin/env bash
set -euo pipefail

ROOT=${SNAPSHOT_ROOT:-${HOME:?HOME must be set}/work-agent-snapshots}
CONFIG=${REPOS_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/repos.conf}
SSH_KEY=${GITHUB_SSH_KEY:-${HOME:?HOME must be set}/.ssh/work-agent-github}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/work-agent
LOCK=${SNAPSHOT_LOCK:-$STATE_DIR/snapshots.lock}
LOG=${SNAPSHOT_LOG:-$STATE_DIR/snapshots.log}
LOG_MAX_BYTES=${SNAPSHOT_LOG_MAX_BYTES:-1048576}

mkdir -p "$STATE_DIR"

# cron has no journald: keep one rotation of our own log, but stay on the
# terminal when a maintainer runs this by hand.
if [[ ! -t 1 ]]; then
  if [[ -f "$LOG" && $(stat -c '%s' "$LOG") -gt $LOG_MAX_BYTES ]]; then
    mv -f "$LOG" "$LOG.1"
  fi
  exec >>"$LOG" 2>&1
fi
printf '=== %s\n' "$(date -Is)"

if [[ ! -r "$SSH_KEY" ]]; then
  printf 'Missing readable GitHub SSH key: %s\n' "$SSH_KEY" >&2
  exit 1
fi
if [[ ! -r "$CONFIG" ]]; then
  printf 'Missing repo config: %s\n' "$CONFIG" >&2
  exit 1
fi

mkdir -p "$ROOT"
exec 9>"$LOCK"
flock -n 9 || exit 0

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

while IFS='|' read -r name url branch; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    printf 'Invalid repo entry: %s|%s|%s\n' "$name" "$url" "$branch" >&2
    exit 1
  fi

  target="$ROOT/$name"
  if [[ ! -d "$target/.git" ]]; then
    rm -rf "$target"
    git clone --no-checkout "$url" "$target"
  fi

  git -C "$target" remote set-url origin "$url"
  git -C "$target" fetch --prune --tags origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$target" checkout -B "$branch" "origin/$branch"
  git -C "$target" reset --hard "origin/$branch"
  git -C "$target" clean -ffd
  printf '%-20s %s %s\n' "$name" "$branch" "$(git -C "$target" rev-parse --short HEAD)"
done < "$CONFIG"
