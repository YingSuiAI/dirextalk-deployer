#!/usr/bin/env bash
# reset-app-data.sh - clear app data on an existing node while preserving infra/TLS.
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

if [ "${DIREXTALK_RESET_APP_DATA_CONFIRM:-0}" != "1" ]; then
  cat >&2 <<'EOF'
reset-app-data is destructive for application data.
It preserves EC2, Elastic IP/public IPv4, DNS, and Caddy TLS volumes, but clears Matrix/message-server data.
Set DIREXTALK_RESET_APP_DATA_CONFIRM=1 to continue.
EOF
  exit 2
fi

ops_require_safe_registry_refresh "$STATE_JSON" reset-app-data

remote_command=$(ops_reset_remote_command)
ops_ssh "$STATE_JSON" "$remote_command"
ops_mark_refresh_pending "$STATE_JSON" S4_BOOTSTRAP_STACK
if ops_stop_scoped_daemon "$STATE_JSON"; then
  bridge_stop_message="Scoped local bridge daemon was stopped; rerun S6 to install fresh config."
else
  bridge_stop_message="Scoped local bridge daemon stop was skipped or not needed."
fi
report=$(ops_write_report reset_app_data reset_remote_data_cleared_refresh_pending "$STATE_JSON")

echo "Application data reset complete on the existing node."
echo "Caddy TLS storage was preserved."
echo "Old credentials and runtime checks were cleared."
echo "$bridge_stop_message"
echo "Local S4-S7 gates were reset; rerun orchestrate with DIREXTALK_EXISTING_STATE_ACTION=continue."
echo "operation report: $report"
