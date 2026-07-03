#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

service_dir="$HOME/.dirextalk/nodes/confirm.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
json_build object \
  run_id=confirm-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=confirm.example.test \
  agent_service_id=confirm.example.test \
  "agent_service_dir=$service_dir" \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

set +e
DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" confirm app_initialization > "$tmp/missing-app-evidence.out" 2>&1
missing_app_evidence_rc=$?
set -e
[ "$missing_app_evidence_rc" -ne 0 ] || {
  echo "app_initialization confirmation must require explicit evidence" >&2
  exit 1
}
grep -q 'requires DIREXTALK_CONFIRM_EVIDENCE' "$tmp/missing-app-evidence.out"
json_test_check "$state" "!data.user_confirmations?.app_initialization"

set +e
DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" confirm real_chat > "$tmp/missing-real-chat-evidence.out" 2>&1
missing_real_chat_evidence_rc=$?
set -e
[ "$missing_real_chat_evidence_rc" -ne 0 ] || {
  echo "real_chat confirmation must require explicit evidence" >&2
  exit 1
}
grep -q 'requires DIREXTALK_CONFIRM_EVIDENCE' "$tmp/missing-real-chat-evidence.out"
json_test_check "$state" "!data.user_confirmations?.real_chat"

set +e
DIREXTALK_WORKDIR="$service_dir" \
  DIREXTALK_CONFIRM_EVIDENCE="ok" \
  bash "$ROOT/scripts/orchestrate.sh" confirm app_initialization > "$tmp/short-app-evidence.out" 2>&1
short_app_evidence_rc=$?
set -e
[ "$short_app_evidence_rc" -ne 0 ] || {
  echo "app_initialization confirmation must reject short generic evidence" >&2
  exit 1
}
grep -q 'DIREXTALK_CONFIRM_EVIDENCE is too short' "$tmp/short-app-evidence.out"
json_test_check "$state" "!data.user_confirmations?.app_initialization"

confirm_output=$(DIREXTALK_WORKDIR="$service_dir" DIREXTALK_CONFIRM_EVIDENCE="user completed app initialization" bash "$ROOT/scripts/orchestrate.sh" confirm app_initialization)
printf '%s\n' "$confirm_output" | grep -q 'confirmed gate: app_initialization'

json_test_check "$state" "data.user_confirmations.app_initialization.status === 'confirmed' && data.user_confirmations.app_initialization.evidence === 'user completed app initialization' && typeof data.user_confirmations.app_initialization.ts === 'string'"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.gates.user_confirmation.app_initialization === 'confirmed' && data.gates.user_confirmation.real_chat === 'pending_user_confirmation' && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

set +e
DIREXTALK_WORKDIR="$service_dir" \
  DIREXTALK_CONFIRM_EVIDENCE="MCP runtime looks ok" \
  bash "$ROOT/scripts/orchestrate.sh" confirm agent_mcp_runtime > "$tmp/mcp-runtime-blocked.out" 2>&1
mcp_blocked_rc=$?
set -e
[ "$mcp_blocked_rc" -ne 0 ] || {
  echo "agent_mcp_runtime confirmation must require runtime evidence" >&2
  exit 1
}
grep -q 'requires runtime_checks.summary.status=passed' "$tmp/mcp-runtime-blocked.out"
json_test_check "$state" "!data.user_confirmations?.agent_mcp_runtime"

json_mutate "$state" set-json runtime_checks.summary '{"status":"passed","failed_count":0,"evidence":"all runtime checks passed","checks":{"connect_daemon":"passed","mcp_doctor":"passed","mcp_tools":"passed","mcp_smoke":"passed"}}'

set +e
DIREXTALK_WORKDIR="$service_dir" \
  DIREXTALK_CONFIRM_EVIDENCE="MCP runtime looks ok" \
  bash "$ROOT/scripts/orchestrate.sh" confirm agent_mcp_runtime > "$tmp/mcp-runtime-missing-probe.out" 2>&1
mcp_missing_probe_rc=$?
set -e
[ "$mcp_missing_probe_rc" -ne 0 ] || {
  echo "agent_mcp_runtime confirmation must require explicit runtime probe evidence" >&2
  exit 1
}
grep -q 'requires DIREXTALK_CONFIRM_RUNTIME_PROBE=1' "$tmp/mcp-runtime-missing-probe.out"
json_test_check "$state" "!data.user_confirmations?.agent_mcp_runtime"

mcp_confirm_output=$(
  DIREXTALK_WORKDIR="$service_dir" \
    DIREXTALK_CONFIRM_RUNTIME_PROBE=1 \
    DIREXTALK_CONFIRM_EVIDENCE="runtime channel probe confirmed in Codex" \
    bash "$ROOT/scripts/orchestrate.sh" confirm agent_mcp_runtime
)
printf '%s\n' "$mcp_confirm_output" | grep -q 'confirmed gate: agent_mcp_runtime'

json_test_check "$state" "data.user_confirmations.agent_mcp_runtime.status === 'confirmed' && data.user_confirmations.agent_mcp_runtime.evidence === 'runtime channel probe confirmed in Codex' && data.user_confirmations.agent_mcp_runtime.runtime_summary_status === 'passed' && data.user_confirmations.agent_mcp_runtime.runtime_probe_confirmed === true"

set +e
DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" confirm unknown_gate > "$tmp/invalid.out" 2>&1
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || {
  echo "invalid confirmation gate should fail" >&2
  exit 1
}
grep -q 'Usage: .* confirm' "$tmp/invalid.out"

echo "user confirmation gates ok"
