# Shared helpers. Source this, do not execute it.

# Read KEY=value pairs from the repo's .env without executing it, expanding the
# literal ${HOME} that .env.example ships with. Values already present in the
# environment win.
load_env() {
  local root=$1 line key value
  [[ -f "$root/.env" ]] || return 0
  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    value=${line#*=}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    value=${value//'${HOME}'/$HOME}
    [[ -n ${!key:-} ]] && continue
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$root/.env"
}

# The deployment host's two scheduled jobs. Both markers are grep targets, so a
# reinstall rewrites our own lines and leaves every other crontab entry alone.
CRON_MARKER_SYNC='# work-agent-snapshots'
CRON_MARKER_CLEANUP='# work-agent-artifact-cleanup'

# Print the crontab lines the host is supposed to run. install-sync-cron.sh pipes
# this into `crontab -`; tests/static.sh renders it to prove the artifact cleanup
# is actually scheduled rather than only described in the docs. Keeping one
# renderer means the tested text is the installed text.
#
# Cleanup runs at :17 so it does not land on the sync run at :00, which rebuilds
# the CodeGraph indexes with a docker run and is the heavy job of the hour.
render_crontab() {
  local root=$1 snapshot_root=$2
  local sync_schedule=${3:-0 * * * *}
  local cleanup_schedule=${4:-17 * * * *}
  printf '%s SNAPSHOT_ROOT=%q %q %s\n' \
    "$sync_schedule" "$snapshot_root" "$root/scripts/update-snapshots.sh" "$CRON_MARKER_SYNC"
  printf '%s %q %s\n' \
    "$cleanup_schedule" "$root/scripts/cleanup-artifacts.sh" "$CRON_MARKER_CLEANUP"
}
