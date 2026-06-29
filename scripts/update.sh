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

remote_command=$(ops_update_remote_command "${MESSAGE_SERVER_IMAGE:-}")
ops_ssh "$STATE_JSON" "$remote_command"
ops_mark_refresh_pending "$STATE_JSON" S4_BOOTSTRAP_STACK
if ops_stop_scoped_daemon "$STATE_JSON"; then
  bridge_stop_message="Scoped local bridge daemon was stopped; rerun S6 to install fresh config."
else
  bridge_stop_message="Scoped local bridge daemon stop was skipped or not needed."
fi
report=$(ops_write_report update update_remote_restart_complete_refresh_pending "$STATE_JSON")

echo "Update remote restart complete."
echo "Old user confirmations and runtime checks were cleared."
echo "$bridge_stop_message"
echo "Local S4-S7 gates were reset; rerun orchestrate with P2P_EXISTING_STATE_ACTION=continue to refresh credentials, MCP, and verification."
echo "operation report: $report"
