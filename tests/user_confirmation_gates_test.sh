#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

service_dir="$HOME/.direxio/nodes/confirm.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  '{
    run_id: "confirm-test",
    region: "ap-northeast-1",
    domain_mode: "user",
    domain: "confirm.example.test",
    agent_service_id: "confirm.example.test",
    agent_service_dir: $service_dir,
    phase: "S7_VERIFY_E2E",
    phases: {
      S0_PREREQ_AWS: {status: "done"},
      S1_PREFLIGHT: {status: "done"},
      S2_DOMAIN: {status: "done"},
      S3_PROVISION: {status: "done"},
      S4_BOOTSTRAP_STACK: {status: "done"},
      S5_INIT_TOKENS: {status: "done"},
      S6_WIRE_LOCAL: {status: "done"},
      S7_VERIFY_E2E: {status: "done"}
    },
    resources: {}
  }' > "$state"

set +e
P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" confirm app_initialization > "$tmp/missing-app-evidence.out" 2>&1
missing_app_evidence_rc=$?
set -e
[ "$missing_app_evidence_rc" -ne 0 ] || {
  echo "app_initialization confirmation must require explicit evidence" >&2
  exit 1
}
grep -q 'requires DIREXIO_CONFIRM_EVIDENCE' "$tmp/missing-app-evidence.out"
jq -e '(.user_confirmations.app_initialization | not)' "$state" >/dev/null

set +e
P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" confirm real_chat > "$tmp/missing-real-chat-evidence.out" 2>&1
missing_real_chat_evidence_rc=$?
set -e
[ "$missing_real_chat_evidence_rc" -ne 0 ] || {
  echo "real_chat confirmation must require explicit evidence" >&2
  exit 1
}
grep -q 'requires DIREXIO_CONFIRM_EVIDENCE' "$tmp/missing-real-chat-evidence.out"
jq -e '(.user_confirmations.real_chat | not)' "$state" >/dev/null

set +e
P2P_WORKDIR="$service_dir" \
  DIREXIO_CONFIRM_EVIDENCE="ok" \
  bash "$ROOT/scripts/orchestrate.sh" confirm app_initialization > "$tmp/short-app-evidence.out" 2>&1
short_app_evidence_rc=$?
set -e
[ "$short_app_evidence_rc" -ne 0 ] || {
  echo "app_initialization confirmation must reject short generic evidence" >&2
  exit 1
}
grep -q 'DIREXIO_CONFIRM_EVIDENCE is too short' "$tmp/short-app-evidence.out"
jq -e '(.user_confirmations.app_initialization | not)' "$state" >/dev/null

confirm_output=$(P2P_WORKDIR="$service_dir" DIREXIO_CONFIRM_EVIDENCE="user completed app initialization" bash "$ROOT/scripts/orchestrate.sh" confirm app_initialization)
printf '%s\n' "$confirm_output" | grep -q 'confirmed gate: app_initialization'

jq -e '
  .user_confirmations.app_initialization.status == "confirmed"
  and .user_confirmations.app_initialization.evidence == "user completed app initialization"
  and (.user_confirmations.app_initialization.ts | type == "string")
' "$state" >/dev/null

report_output=$(P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
jq -e '
  .gates.user_confirmation.app_initialization == "confirmed"
  and .gates.user_confirmation.real_chat == "pending_user_confirmation"
  and .gates.user_confirmation.agent_mcp_runtime == "pending_runtime_confirmation"
' "$report_path" >/dev/null

set +e
P2P_WORKDIR="$service_dir" \
  DIREXIO_CONFIRM_EVIDENCE="MCP runtime looks ok" \
  bash "$ROOT/scripts/orchestrate.sh" confirm agent_mcp_runtime > "$tmp/mcp-runtime-blocked.out" 2>&1
mcp_blocked_rc=$?
set -e
[ "$mcp_blocked_rc" -ne 0 ] || {
  echo "agent_mcp_runtime confirmation must require runtime evidence" >&2
  exit 1
}
grep -q 'requires runtime_checks.summary.status=passed' "$tmp/mcp-runtime-blocked.out"
jq -e '(.user_confirmations.agent_mcp_runtime | not)' "$state" >/dev/null

jq '.runtime_checks.summary = {
  status: "passed",
  failed_count: 0,
  evidence: "all runtime checks passed",
  checks: {
    connect_daemon: "passed",
    mcp_doctor: "passed",
    mcp_tools: "passed",
    mcp_smoke: "passed"
  }
}' "$state" > "$state.tmp" && mv "$state.tmp" "$state"

set +e
P2P_WORKDIR="$service_dir" \
  DIREXIO_CONFIRM_EVIDENCE="MCP runtime looks ok" \
  bash "$ROOT/scripts/orchestrate.sh" confirm agent_mcp_runtime > "$tmp/mcp-runtime-missing-probe.out" 2>&1
mcp_missing_probe_rc=$?
set -e
[ "$mcp_missing_probe_rc" -ne 0 ] || {
  echo "agent_mcp_runtime confirmation must require explicit runtime probe evidence" >&2
  exit 1
}
grep -q 'requires DIREXIO_CONFIRM_RUNTIME_PROBE=1' "$tmp/mcp-runtime-missing-probe.out"
jq -e '(.user_confirmations.agent_mcp_runtime | not)' "$state" >/dev/null

mcp_confirm_output=$(
  P2P_WORKDIR="$service_dir" \
    DIREXIO_CONFIRM_RUNTIME_PROBE=1 \
    DIREXIO_CONFIRM_EVIDENCE="runtime channel probe confirmed in Codex" \
    bash "$ROOT/scripts/orchestrate.sh" confirm agent_mcp_runtime
)
printf '%s\n' "$mcp_confirm_output" | grep -q 'confirmed gate: agent_mcp_runtime'

jq -e '
  .user_confirmations.agent_mcp_runtime.status == "confirmed"
  and .user_confirmations.agent_mcp_runtime.evidence == "runtime channel probe confirmed in Codex"
  and .user_confirmations.agent_mcp_runtime.runtime_summary_status == "passed"
  and .user_confirmations.agent_mcp_runtime.runtime_probe_confirmed == true
' "$state" >/dev/null

set +e
P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" confirm unknown_gate > "$tmp/invalid.out" 2>&1
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || {
  echo "invalid confirmation gate should fail" >&2
  exit 1
}
grep -q 'Usage: .* confirm' "$tmp/invalid.out"

echo "user confirmation gates ok"
