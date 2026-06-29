#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

assert_contains() {
  local haystack=$1 needle=$2
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

write_state() {
  local workdir=$1 phase=$2 status=$3 resources_json=$4
  mkdir -p "$workdir"
  jq -n \
    --arg run_id "status-test" \
    --arg region "ap-northeast-1" \
    --arg domain "status.example.test" \
    --arg phase "$phase" \
    --arg status "$status" \
    --argjson resources "$resources_json" \
    '{
      run_id: $run_id,
      region: $region,
      domain_mode: "user",
      domain: $domain,
      instance_type: "t3.small",
      dns_ready: false,
      phase: $phase,
      phases: {
        S0_PREREQ_AWS: {status: (if $phase == "S0_PREREQ_AWS" then $status else "done" end)},
        S1_PREFLIGHT: {status: (if $phase == "S0_PREREQ_AWS" then "pending" elif $phase == "S1_PREFLIGHT" then $status else "done" end)},
        S2_DOMAIN: {status: (if ($phase == "S0_PREREQ_AWS" or $phase == "S1_PREFLIGHT") then "pending" elif $phase == "S2_DOMAIN" then $status else "done" end)},
        S3_PROVISION: {status: (if ($phase == "S0_PREREQ_AWS" or $phase == "S1_PREFLIGHT" or $phase == "S2_DOMAIN") then "pending" elif $phase == "S3_PROVISION" then $status else "done" end)},
        S4_BOOTSTRAP_STACK: {status: (if ($phase == "S0_PREREQ_AWS" or $phase == "S1_PREFLIGHT" or $phase == "S2_DOMAIN" or $phase == "S3_PROVISION") then "pending" elif $phase == "S4_BOOTSTRAP_STACK" then $status else "done" end)},
        S5_INIT_TOKENS: {status: (if ($phase == "S0_PREREQ_AWS" or $phase == "S1_PREFLIGHT" or $phase == "S2_DOMAIN" or $phase == "S3_PROVISION" or $phase == "S4_BOOTSTRAP_STACK") then "pending" elif $phase == "S5_INIT_TOKENS" then $status else "done" end)},
        S6_WIRE_LOCAL: {status: (if ($phase == "S0_PREREQ_AWS" or $phase == "S1_PREFLIGHT" or $phase == "S2_DOMAIN" or $phase == "S3_PROVISION" or $phase == "S4_BOOTSTRAP_STACK" or $phase == "S5_INIT_TOKENS") then "pending" elif $phase == "S6_WIRE_LOCAL" then $status else "done" end)},
        S7_VERIFY_E2E: {status: (if $phase == "S7_VERIFY_E2E" then $status else "pending" end)}
      },
      resources: $resources
    }' > "$workdir/state.json"
}

pre_resource_workdir="$tmp/pre-resource"
write_state "$pre_resource_workdir" "S2_DOMAIN" "waiting_user" '{}'
pre_resource_output=$(P2P_WORKDIR="$pre_resource_workdir" bash "$ROOT/scripts/orchestrate.sh" status)

assert_contains "$pre_resource_output" "Recovery summary"
assert_contains "$pre_resource_output" "Where it is blocked: S2_DOMAIN"
assert_contains "$pre_resource_output" "Billing impact: no EC2, public IPv4, or EBS resource is recorded yet"
assert_contains "$pre_resource_output" "Resume safety: safe to rerun the same command after the next action is complete"
assert_contains "$pre_resource_output" "Next action: confirm the long-lived domain, DNS authority, and irreversible Matrix server_name binding"
assert_contains "$pre_resource_output" "Stop-loss: no recorded cloud resources need destroy from this state"

billable_workdir="$tmp/billable"
write_state "$billable_workdir" "S4_BOOTSTRAP_STACK" "failed" '{"instance_id":"i-status","root_volume_id":"vol-status-root","public_ip":"203.0.113.10","eip_id":"eipalloc-status","route53_zone_id":"ZSTATUS"}'
billable_output=$(P2P_WORKDIR="$billable_workdir" bash "$ROOT/scripts/orchestrate.sh" status)

assert_contains "$billable_output" "Recovery summary"
assert_contains "$billable_output" "Where it is blocked: S4_BOOTSTRAP_STACK"
assert_contains "$billable_output" "Billing impact: recorded AWS resources may keep billing: EC2 i-status, EBS root volume vol-status-root, public IPv4 203.0.113.10, Elastic IP eipalloc-status, Route53 hosted zone ZSTATUS"
assert_contains "$billable_output" "Resume safety: do not reset state; fix the issue and rerun with P2P_EXISTING_STATE_ACTION=continue"
assert_contains "$billable_output" "Next action: inspect cloud-init, Docker, Caddy/TLS, and message-server logs over SSH"
assert_contains "$billable_output" "Stop-loss: ask the agent to run destroy, or run:"
assert_contains "$billable_output" "destroy.sh"

refresh_workdir="$tmp/refresh-pending"
write_state "$refresh_workdir" "S4_BOOTSTRAP_STACK" "pending" '{"instance_id":"i-refresh","root_volume_id":"vol-refresh-root","public_ip":"203.0.113.20"}'
jq '
  .agent_install_status = "refresh_pending"
  | .agent_service_id = "status.example.test"
  | .user_confirmations.app_initialization = {status:"confirmed", evidence:"old app proof"}
  | .runtime_checks.summary = {status:"passed"}
' "$refresh_workdir/state.json" > "$refresh_workdir/state.json.tmp"
mv "$refresh_workdir/state.json.tmp" "$refresh_workdir/state.json"
refresh_output=$(P2P_WORKDIR="$refresh_workdir" bash "$ROOT/scripts/orchestrate.sh" status)

assert_contains "$refresh_output" "Recovery summary"
assert_contains "$refresh_output" "Local refresh: update/reset cleared old credentials, user confirmations, runtime checks, and bridge install proof"
assert_contains "$refresh_output" "Next action: rerun the deployment workflow to refresh S4-S7, local credentials, MCP snippets, and runtime checks"

echo "orchestrate status recovery ok"
