#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/dirextalk-mcp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = "doctor" ]
[ "${2:-}" = "--json" ]
[ "${DIREXTALK_CREDENTIALS_FILE:-}" = "${EXPECTED_CREDENTIALS_FILE:-}" ]

cat <<JSON
{
  "ok": true,
  "domain": "mcp-check.example.test",
  "agent_room_id": "!agent:mcp-check.example.test",
  "token": "redacted"
}
JSON
EOF
chmod 700 "$fakebin/dirextalk-mcp"

service_dir="$HOME/.dirextalk/nodes/mcp-check.example.test"
mkdir -p "$service_dir"
credentials="$service_dir/credentials.json"
: > "$credentials"
expected_credentials="$credentials"
if command -v cygpath >/dev/null 2>&1; then
  expected_credentials=$(cygpath -m "$expected_credentials")
fi
state="$service_dir/state.json"
json_build object \
  run_id=mcp-doctor-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=mcp-check.example.test \
  agent_service_id=mcp-check.example.test \
  "agent_service_dir=$service_dir" \
  "agent_credentials_file=$credentials" \
  "mcp_credentials_file=$credentials" \
  mcp_command=dirextalk-mcp \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

verify_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" EXPECTED_CREDENTIALS_FILE="$expected_credentials" bash "$ROOT/scripts/orchestrate.sh" verify mcp_doctor)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_doctor'

json_test_check "$state" "data.runtime_checks.mcp_doctor.status === 'passed' && data.runtime_checks.mcp_doctor.domain === 'mcp-check.example.test' && data.runtime_checks.mcp_doctor.agent_room_id === '!agent:mcp-check.example.test' && data.runtime_checks.mcp_doctor.token === 'redacted' && !data.user_confirmations?.agent_mcp_runtime"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.mcp_doctor.status === 'passed' && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

echo "mcp doctor runtime check ok"
