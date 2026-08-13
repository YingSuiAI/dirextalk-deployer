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
# shellcheck disable=SC1090
source "$HERE/lib/state.sh"
# shellcheck disable=SC1090
source "$HERE/lib/server-release.sh"
# shellcheck disable=SC1090
source "$HERE/lib/updater-release.sh"
dirextalk_require_git_bash_on_windows || exit 1

STATE_JSON=$(ops_state_path "${1:-}")
ops_require_state "$STATE_JSON"
server_release_validate_override
updater_release_validate_pin
server_release_split_state_can_advance
server_release_split_application_matches_pin || {
  echo "current deployer application release differs from the existing node receipt; use release.v2.apply before updating host integration" >&2
  exit 1
}
recorded_split_revision=$(state_get split_release.split_source_revision)
recorded_split_release=$(state_get split_release)
recorded_updater_release=$(state_get updater_release)
[ -n "$recorded_split_release" ] && [ -n "$recorded_updater_release" ] || {
  echo "state is missing release receipts; refusing existing-node update" >&2
  exit 1
}

status=0
ops_verify_existing_node_identity "$STATE_JSON" || status=$?
[ "$status" -eq 0 ] || exit 1
ops_stage_current_host_integration "$STATE_JSON" "$recorded_split_revision" || status=$?
case "$status" in 0) ;; 3) exit 3 ;; *) exit 1 ;; esac

# The staged integration already executed the canonical receipt-bound
# reconcile. A same-name replacement or host reset after that remote commit
# must not receive the local release-state commit.
ops_verify_existing_node_identity "$STATE_JSON" || exit 1
ops_commit_existing_update_release "$STATE_JSON" "$recorded_split_release" "$recorded_updater_release"
report=$(ops_write_report update update_remote_restart_complete "$STATE_JSON")

echo "Update remote restart complete."
echo "Local credentials, dirextalk-connect daemon state, MCP artifacts, confirmations, and runtime checks were left unchanged."
echo "operation report: $report"
