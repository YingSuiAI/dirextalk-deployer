#!/usr/bin/env bash
# update.sh - reconcile an existing production split node without deleting data.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/paths.sh"
# shellcheck disable=SC1090
source "$HERE/lib/git-bash.sh"
# shellcheck disable=SC1090
source "$HERE/lib/operation_report.sh"
# shellcheck disable=SC1090
source "$HERE/lib/ops.sh"
dirextalk_require_git_bash_on_windows || exit 1

STATE_JSON=$(ops_state_path "${1:-}")
ops_require_state "$STATE_JSON"

remote_command=$(ops_update_remote_command)
ops_ssh "$STATE_JSON" "$remote_command"
report=$(ops_write_report update update_remote_restart_complete "$STATE_JSON")

echo "Update remote restart complete."
echo "Local credentials, dirextalk-connect daemon state, MCP artifacts, confirmations, and runtime checks were left unchanged."
echo "operation report: $report"
