#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/direxio-mcp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = "doctor" ]
[ "${2:-}" = "--json" ]
[ "${DIREXIO_CREDENTIALS_FILE:-}" = "${EXPECTED_CREDENTIALS_FILE:-}" ]

cat <<JSON
{
  "ok": true,
  "domain": "mcp-check.example.test",
  "agent_room_id": "!agent:mcp-check.example.test",
  "token": "redacted"
}
JSON
EOF
chmod 700 "$fakebin/direxio-mcp"

service_dir="$HOME/.direxio/nodes/mcp-check.example.test"
mkdir -p "$service_dir"
credentials="$service_dir/credentials.json"
: > "$credentials"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  --arg credentials "$credentials" \
  '{
    run_id: "mcp-doctor-test",
    region: "ap-northeast-1",
    domain_mode: "user",
    domain: "mcp-check.example.test",
    agent_service_id: "mcp-check.example.test",
    agent_service_dir: $service_dir,
    agent_credentials_file: $credentials,
    mcp_credentials_file: $credentials,
    mcp_command: "direxio-mcp",
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

verify_output=$(P2P_WORKDIR="$service_dir" PATH="$fakebin:$PATH" EXPECTED_CREDENTIALS_FILE="$credentials" bash "$ROOT/scripts/orchestrate.sh" verify mcp_doctor)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_doctor'

jq -e '
  .runtime_checks.mcp_doctor.status == "passed"
  and .runtime_checks.mcp_doctor.domain == "mcp-check.example.test"
  and .runtime_checks.mcp_doctor.agent_room_id == "!agent:mcp-check.example.test"
  and .runtime_checks.mcp_doctor.token == "redacted"
  and (.user_confirmations.agent_mcp_runtime | not)
' "$state" >/dev/null

report_output=$(P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
jq -e '
  .runtime_checks.mcp_doctor.status == "passed"
  and .gates.user_confirmation.agent_mcp_runtime == "pending_runtime_confirmation"
' "$report_path" >/dev/null

echo "mcp doctor runtime check ok"
