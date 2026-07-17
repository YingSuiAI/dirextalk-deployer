#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
isolation_root=$(mktemp -d)
json_worker_pid=
cleanup() {
  if [ -n "${DIREXTALK_JSON_WORKER_SOCKET:-}" ]; then
    case "$DIREXTALK_JSON_WORKER_SOCKET" in
      *[!0-9]*|'') ;;
      *) eval "exec ${DIREXTALK_JSON_WORKER_SOCKET}>&-" || true ;;
    esac
    unset DIREXTALK_JSON_WORKER_SOCKET
  fi
  if [ -n "$json_worker_pid" ]; then
    kill "$json_worker_pid" 2>/dev/null || true
    wait "$json_worker_pid" 2>/dev/null || true
  fi
  rm -rf "$isolation_root"
}
trap cleanup EXIT
export DIREXTALK_TEST_ROOT=$isolation_root

# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"
dirextalk_test_isolate_homes "$isolation_root"

# Reuse one native Node process for all JSON commands in this isolated suite.
# This avoids hundreds of slow Bash -> node.exe startups on Windows while the
# production CLI remains the fallback outside the test root.
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"
json_worker_metadata="$isolation_root/json-worker.meta"
json_worker_script=$(dirextalk_native_tool_path "$ROOT/scripts/lib/json-worker.mjs")
json_worker_metadata_native=$(dirextalk_native_tool_path "$json_worker_metadata")
export DIREXTALK_JSON_WORKER_POSIX_ROOT=$isolation_root
export DIREXTALK_JSON_WORKER_NATIVE_ROOT
DIREXTALK_JSON_WORKER_NATIVE_ROOT=$(dirextalk_native_tool_path "$isolation_root")
MSYS_NO_PATHCONV=1 "$(json_node)" "$json_worker_script" "$json_worker_metadata_native" &
json_worker_pid=$!
for _ in $(seq 1 100); do
  [ -s "$json_worker_metadata" ] && break
  kill -0 "$json_worker_pid" 2>/dev/null || break
  sleep 0.02
done
[ -s "$json_worker_metadata" ] || {
  echo "failed to start the isolated JSON worker" >&2
  exit 1
}
read -r DIREXTALK_JSON_WORKER_PORT DIREXTALK_JSON_WORKER_TOKEN < "$json_worker_metadata"
export DIREXTALK_JSON_WORKER_PORT DIREXTALK_JSON_WORKER_TOKEN

[ "$#" -gt 0 ] || {
  echo "usage: run_isolated.sh <command> [args...]" >&2
  exit 2
}

case "$1" in
  *.sh)
    script=$1
    shift
    # Reuse this Git Bash controller for the suite entrypoint. Test cases are
    # still launched sequentially by npm_test_suite.sh for state isolation.
    # shellcheck disable=SC1090
    source "$script" "$@"
    ;;
  *) "$@" ;;
esac
