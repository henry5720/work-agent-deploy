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

# Read the pinned versions from config/versions.env and derive the two values
# Compose interpolates: the base image digest and the OpenAB config file. Both
# depend on OPENAB_AGENT_RUNTIME, so the Claude ACP rollback is one edit in one
# file.
#
# config/versions.env is the only source. An ambient value that disagrees with
# the file is refused instead of winning: otherwise a stray export in a shell or
# in root .env would build a different image from the one the reviewed file
# records, and nothing would say so. An ambient value that agrees is fine, which
# is what lets deploy.sh call scripts/compose.sh after loading versions itself.
#
# The one supported way to resolve a runtime other than the file's is the second
# argument (scripts/compose.sh --runtime <value>), which is explicit and leaves
# the file untouched. That is the rollback dry-run path.
load_versions() {
  local root=$1 runtime_override=${2:-} line key value
  local versions="$root/config/versions.env"
  [[ -f "$versions" ]] || {
    printf 'missing %s\n' "$versions" >&2
    return 1
  }
  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    value=${line#*=}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    # An explicit override for this call is allowed to disagree with the file,
    # and so is an ambient value that matches that override — that is just this
    # process re-entering load_versions (compose.sh called from a script that
    # already resolved the runtime), not the environment choosing anything.
    if [[ $key == OPENAB_AGENT_RUNTIME && -n $runtime_override && ${!key:-} == "$runtime_override" ]]; then
      value=$runtime_override
    fi
    if [[ -n ${!key:-} && ${!key} != "$value" ]]; then
      printf '%s is set in the environment (%s) but config/versions.env says %s.\n' \
        "$key" "${!key}" "$value" >&2
      printf 'config/versions.env is the only source; unset it, or fix root .env.\n' >&2
      [[ $key == OPENAB_AGENT_RUNTIME ]] &&
        printf 'To try the other runtime without editing the file: ./scripts/compose.sh --runtime %s ...\n' \
          "${!key}" >&2
      return 1
    fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$versions"

  if [[ -n $runtime_override ]]; then
    export OPENAB_AGENT_RUNTIME="$runtime_override"
  fi

  case ${OPENAB_AGENT_RUNTIME:-} in
    opencode)
      export OPENAB_IMAGE="$OPENAB_IMAGE_OPENCODE"
      export OPENAB_CONFIG="./config/openab.toml"
      ;;
    claude)
      export OPENAB_IMAGE="$OPENAB_IMAGE_CLAUDE"
      export OPENAB_CONFIG="./config/openab.claude-acp.toml"
      ;;
    *)
      printf 'OPENAB_AGENT_RUNTIME must be opencode or claude, got: %s\n' \
        "${OPENAB_AGENT_RUNTIME:-<unset>}" >&2
      return 1
      ;;
  esac

  [[ $OPENAB_IMAGE == *@sha256:* ]] || {
    printf 'OPENAB_IMAGE must be pinned to a digest: %s\n' "$OPENAB_IMAGE" >&2
    return 1
  }
  [[ -f "$root/${OPENAB_CONFIG#./}" ]] || {
    printf 'missing OpenAB config for runtime %s: %s\n' \
      "$OPENAB_AGENT_RUNTIME" "$OPENAB_CONFIG" >&2
    return 1
  }
}
