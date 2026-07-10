#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# The npm entrypoint must provide the isolation root before any test can resolve
# a user or runtime home.
# shellcheck disable=SC1091
source "$ROOT/tests/lib/isolated_home.sh"
: "${DIREXTALK_TEST_ROOT:?run this suite through tests/lib/run_isolated.sh}"
dirextalk_test_assert_isolated_homes "$DIREXTALK_TEST_ROOT"

tests=(
  tests/tracked_text_lf_test.sh
  tests/npm_skill_distribution_test.sh
  tests/skill_structure_test.sh
  tests/atomic_write_test.sh
  tests/json_helper_test.sh
  tests/local_paths_test.sh
  tests/windows_path_wrappers_test.sh
  tests/private_file_permissions_test.sh
  tests/orchestrate_status_recovery_test.sh
  tests/orchestrate_region_env_test.sh
  tests/domain_route53_default_test.sh
  tests/domain_dns_mode_detection_test.sh
  tests/route53_zone_required_test.sh
  tests/eip_preflight_test.sh
  tests/s1_lightsail_availability_fallback_test.sh
  tests/root_volume_size_test.sh
  tests/s3_lightsail_provision_test.sh
  tests/s3_ec2_updater_upload_test.sh
  tests/s3_stable_ip_reconcile_test.sh
  tests/lightsail_static_ip_quota_test.sh
  tests/destroy_lightsail_test.sh
  tests/mcp_tools_runtime_check_test.sh
  tests/s7_http_mcp_acceptance_test.sh
  tests/runtime_summary_check_test.sh
  tests/final_delivery_runtime_gate_test.sh
  tests/s6_run_phase_failure_test.sh
  tests/s6_wire_local_test.sh
  tests/operation_report_test.sh
  tests/render_userdata_remote_nodes_test.sh
  tests/server_release_test.sh
  tests/updater_bundle_test.sh
  tests/updater_binary_rebuild_test.sh
  tests/updater_bootstrap_resume_test.sh
)

for test_file in "${tests[@]}"; do
  bash "$test_file"
done
