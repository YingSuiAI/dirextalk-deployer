#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# The npm entrypoint must provide the isolation root before any test can resolve
# a user or runtime home.
# shellcheck disable=SC1091
source "$ROOT/tests/lib/isolated_home.sh"
: "${DIREXTALK_TEST_ROOT:?run this suite through tests/lib/run_isolated.sh}"
dirextalk_test_assert_isolated_homes "$DIREXTALK_TEST_ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/json.sh"

mode=${1:-quick}
case "$mode" in
  quick|extended|extended-only|release|release-only) ;;
  *) echo "usage: $0 [quick|extended|extended-only|release|release-only]" >&2; exit 2 ;;
esac

# Keep `npm test` short enough for the Windows Git Bash development loop. These
# cross-platform contracts protect package distribution, Git Bash execution,
# local path/permission boundaries, persisted JSON, and atomic updater replacement.
quick_tests=(
  tests/tracked_text_lf_test.sh
  tests/test_runner_entry_test.mjs
  tests/npm_skill_distribution_test.sh
  tests/skill_structure_test.sh
  tests/atomic_write_test.sh
  tests/json_helper_test.sh
  tests/local_paths_test.sh
  tests/git_bash_windows_contract_test.sh
  tests/private_file_permissions_test.sh
  tests/region_recommendation_test.sh
  tests/updater_platform_contract_test.sh
  tests/updater_atomic_install_test.sh
)

# The stage lane protects the default Lightsail deploy -> wire -> verify ->
# destroy workflow and its credential/report boundaries. Keep it within the
# three-minute local feedback budget on the profiled Windows host.
extended_tests=(
  tests/aws_credentials_test.sh
  tests/s3_lightsail_provision_test.sh
  tests/s5_init_tokens_test.sh
  tests/s6_run_phase_failure_test.sh
  tests/destroy_lightsail_test.sh
  tests/s7_http_mcp_acceptance_test.sh
  tests/operation_report_test.sh
)

# Exhaustive compatibility matrices, legacy adoption, optional EC2, updater,
# and implementation-detail variants remain release coverage. They run once
# on Ubuntu CI and explicitly before publishing, not in the local stage loop.
release_tests=(
  tests/s6_run_phase_failure_test.sh
  tests/orchestrate_status_recovery_test.sh
  tests/orchestrate_region_env_test.sh
  tests/domain_dns_mode_detection_test.sh
  tests/domain_route53_default_test.sh
  tests/domain_authoritative_dns_test.sh
  tests/route53_zone_required_test.sh
  tests/s1_lightsail_availability_fallback_test.sh
  tests/lightsail_static_ip_quota_test.sh
  tests/eip_preflight_test.sh
  tests/root_volume_size_test.sh
  tests/s3_ec2_updater_upload_test.sh
  tests/s3_stable_ip_reconcile_test.sh
  tests/s3_public_ip_validation_test.sh
  tests/s3_updater_integration_migration_test.sh
  tests/legacy_adopt_test.sh
  tests/destroy_local_bridge_test.sh
  tests/destroy_root_identity_test.sh
  tests/server_release_test.sh
  tests/user_confirmation_gates_test.sh
  tests/mcp_tools_runtime_check_test.sh
  tests/runtime_summary_check_test.sh
  tests/final_delivery_runtime_gate_test.sh
  tests/s6_wire_local_test.sh
  tests/render_userdata_remote_nodes_test.sh
  tests/init_tokens_resume_test.sh
  tests/updater_release_pin_test.sh
  tests/updater_bundle_test.sh
  tests/updater_bootstrap_resume_test.sh
  tests/updater_release_download_test.sh
  tests/pricing_estimate_test.sh
  tests/update_reset_ops_test.sh
)

case "$mode" in
  quick) tests=("${quick_tests[@]}") ;;
  extended) tests=("${extended_tests[@]}") ;;
  extended-only) tests=("${extended_tests[@]}") ;;
  release)
    tests=("${quick_tests[@]}")
    for test_file in "${extended_tests[@]}"; do
      [ "$test_file" = tests/s6_run_phase_failure_test.sh ] || tests+=("$test_file")
    done
    tests+=("${release_tests[@]}")
    ;;
  release-only) tests=("${release_tests[@]}") ;;
esac

for test_file in "${tests[@]}"; do
  test_started=$SECONDS
  case "$test_file" in
    *.mjs) "$(json_node)" "$test_file" ;;
    *)
      if { [ "$mode" = release ] || [ "$mode" = release-only ]; } && [ "$test_file" = tests/s6_run_phase_failure_test.sh ]; then
        bash "$test_file" --extended
      else
        bash "$test_file"
      fi
      ;;
  esac
  if [ "${DIREXTALK_TEST_TIMINGS:-0}" = 1 ]; then
    printf 'DIREXTALK_TEST_TIMING\t%s\t%ss\n' "$test_file" "$((SECONDS - test_started))"
  fi
done
