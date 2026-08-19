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
