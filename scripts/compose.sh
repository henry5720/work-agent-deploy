#!/usr/bin/env bash
# 所有 docker compose 操作的唯一入口。它先載入 root `.env`（snapshot root 與 uid）
# 與 `config/versions.env`（image digest、runtime、pinned 版本），再把參數原樣交給
# docker compose。直接跑 `docker compose` 會因為缺少 OPENAB_IMAGE 而中止，這是刻意的：
# 版本只有一份正本。
#
# 用法：
#   ./scripts/compose.sh <docker compose 參數...>
#   ./scripts/compose.sh --runtime claude config --quiet
#
# `--runtime` 只是不改檔案地試另一個 agent runtime（rollback dry-run），不是第二份
# 設定；正式切換仍然是改 config/versions.env 的 OPENAB_AGENT_RUNTIME。環境變數不能
# 覆蓋版本或 runtime 選擇，load_versions 會擋下來。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

RUNTIME_OVERRIDE=""
case ${1:-} in
  --runtime)
    [[ $# -ge 2 ]] || {
      printf -- '--runtime needs a value (opencode or claude)\n' >&2
      exit 2
    }
    RUNTIME_OVERRIDE=$2
    shift 2
    ;;
  --runtime=*)
    RUNTIME_OVERRIDE=${1#--runtime=}
    shift
    ;;
esac

load_env "$ROOT"
load_versions "$ROOT" "$RUNTIME_OVERRIDE"

exec docker compose -f "$ROOT/compose.yaml" "$@"
