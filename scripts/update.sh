#!/usr/bin/env bash
# update.sh - update an existing EC2 node without recreating infra or deleting data.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/paths.sh"
# shellcheck disable=SC1090
source "$HERE/lib/operation_report.sh"
# shellcheck disable=SC1090
source "$HERE/lib/ops.sh"

STATE_JSON=$(ops_state_path "${1:-}")
ops_require_state "$STATE_JSON"

if [ -n "${MESSAGE_SERVER_IMAGE:-}" ] && [ "${DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE:-0}" != "1" ]; then
  echo "MESSAGE_SERVER_IMAGE is a debug/legacy override; set DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 explicitly." >&2
  exit 1
fi

remote_command=$(ops_update_remote_command "${MESSAGE_SERVER_IMAGE:-}")
ops_ssh "$STATE_JSON" "$remote_command"
report=$(ops_write_report update update_remote_restart_complete "$STATE_JSON")

echo "Update remote restart complete."
echo "Local credentials, dirextalk-connect daemon state, MCP artifacts, confirmations, and runtime checks were left unchanged."
echo "operation report: $report"
