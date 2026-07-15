#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dirextalk_test_isolate_homes "$tmp"

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
  local s0=pending s1=pending s2=pending s3=pending s4=pending s5=pending s6=pending s7=pending
  mkdir -p "$workdir"
  case "$phase" in
    S0_PREREQ_AWS) s0=$status ;;
    S1_PREFLIGHT) s0=done; s1=$status ;;
    S2_DOMAIN) s0=done; s1=done; s2=$status ;;
    S3_PROVISION) s0=done; s1=done; s2=done; s3=$status ;;
    S4_BOOTSTRAP_STACK) s0=done; s1=done; s2=done; s3=done; s4=$status ;;
    S5_INIT_TOKENS) s0=done; s1=done; s2=done; s3=done; s4=done; s5=$status ;;
    S6_WIRE_LOCAL) s0=done; s1=done; s2=done; s3=done; s4=done; s5=done; s6=$status ;;
    S7_VERIFY_E2E) s0=done; s1=done; s2=done; s3=done; s4=done; s5=done; s6=done; s7=$status ;;
  esac
  json_build object \
    run_id=status-test \
    region=ap-northeast-1 \
    domain_mode=user \
    domain=status.example.test \
    instance_type=t3.small \
    dns_ready=false \
    "phase=$phase" \
    "phases={\"S0_PREREQ_AWS\":{\"status\":\"$s0\"},\"S1_PREFLIGHT\":{\"status\":\"$s1\"},\"S2_DOMAIN\":{\"status\":\"$s2\"},\"S3_PROVISION\":{\"status\":\"$s3\"},\"S4_BOOTSTRAP_STACK\":{\"status\":\"$s4\"},\"S5_INIT_TOKENS\":{\"status\":\"$s5\"},\"S6_WIRE_LOCAL\":{\"status\":\"$s6\"},\"S7_VERIFY_E2E\":{\"status\":\"$s7\"}}" \
    "resources=$resources_json" > "$workdir/state.json"
}

pre_resource_workdir="$tmp/pre-resource"
write_state "$pre_resource_workdir" "S2_DOMAIN" "waiting_user" '{}'
pre_resource_output=$(DIREXTALK_WORKDIR="$pre_resource_workdir" bash "$ROOT/scripts/orchestrate.sh" status)

assert_contains "$pre_resource_output" "Recovery summary"
assert_contains "$pre_resource_output" "Where it is blocked: S2_DOMAIN"
assert_contains "$pre_resource_output" "Billing impact: no cloud instance, public IPv4, or storage resource is recorded yet"
assert_contains "$pre_resource_output" "Resume safety: safe to rerun the same command after the next action is complete"
assert_contains "$pre_resource_output" "Next action: confirm the long-lived domain, DNS authority, and irreversible Matrix server_name binding"
assert_contains "$pre_resource_output" "Stop-loss: no recorded cloud resources need destroy from this state"

billable_workdir="$tmp/billable"
write_state "$billable_workdir" "S4_BOOTSTRAP_STACK" "failed" '{"instance_id":"i-status","root_volume_id":"vol-status-root","public_ip":"203.0.113.10","eip_id":"eipalloc-status","route53_zone_id":"ZSTATUS"}'
billable_output=$(DIREXTALK_WORKDIR="$billable_workdir" bash "$ROOT/scripts/orchestrate.sh" status)

assert_contains "$billable_output" "Recovery summary"
assert_contains "$billable_output" "Where it is blocked: S4_BOOTSTRAP_STACK"
assert_contains "$billable_output" "Billing impact: recorded AWS resources may keep billing: EC2 i-status, EBS root volume vol-status-root, public IPv4 203.0.113.10, Elastic IP eipalloc-status, Route53 hosted zone ZSTATUS"
assert_contains "$billable_output" "Resume safety: do not reset state; fix the issue and rerun with DIREXTALK_EXISTING_STATE_ACTION=continue"
assert_contains "$billable_output" "Next action: inspect cloud-init, Docker, Caddy/TLS, and message-server logs over SSH"
assert_contains "$billable_output" "Stop-loss: ask the agent to run destroy, or run:"
assert_contains "$billable_output" "destroy.sh"
windows_billable_output=$(DIREXTALK_LOCAL_PATH_STYLE=windows DIREXTALK_WORKDIR="$billable_workdir" bash "$ROOT/scripts/orchestrate.sh" status)
assert_contains "$windows_billable_output" "DOMAIN=status.example.test"
assert_contains "$windows_billable_output" "destroy.sh"
if printf '%s\n' "$windows_billable_output" | grep -q 'destroy.ps1'; then
  echo "Git Bash recovery output must not reference PowerShell wrappers" >&2
  exit 1
fi

refresh_workdir="$tmp/refresh-pending"
write_state "$refresh_workdir" "S4_BOOTSTRAP_STACK" "pending" '{"instance_id":"i-refresh","root_volume_id":"vol-refresh-root","public_ip":"203.0.113.20"}'
json_mutate "$refresh_workdir/state.json" set-string connect_install_status refresh_pending
json_mutate "$refresh_workdir/state.json" set-string agent_service_id status.example.test
json_mutate "$refresh_workdir/state.json" set-json user_confirmations.app_initialization '{"status":"confirmed","evidence":"old app proof"}'
json_mutate "$refresh_workdir/state.json" set-json runtime_checks.summary '{"status":"passed"}'
refresh_output=$(DIREXTALK_WORKDIR="$refresh_workdir" bash "$ROOT/scripts/orchestrate.sh" status)

assert_contains "$refresh_output" "Recovery summary"
assert_contains "$refresh_output" "Local refresh: reset/redeploy cleared old credentials, user confirmations, runtime checks, bridge install proof, and MCP install proof"
assert_contains "$refresh_output" "Next action: rerun the deployment workflow to refresh S4-S7, local credentials, MCP snippets, automatic installs, and runtime checks"

echo "orchestrate status recovery ok"
