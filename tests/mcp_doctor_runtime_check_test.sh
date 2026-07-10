#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$CURL_CALLS"

want_url="https://mcp-check.example.test/mcp"
case " $* " in
  *" $want_url "*|*" $want_url")
    ;;
  *)
    echo "unexpected curl URL: $*" >&2
    exit 1
    ;;
esac

case " $* " in
  *"Authorization: Bearer AGENT_TOKEN_DOCTOR"*) ;;
  *)
    echo "missing or wrong Authorization header: $*" >&2
    exit 1
    ;;
esac

case " $* " in
  *'"method":"initialize"'*) ;;
  *)
    echo "wrong MCP initialize body: $*" >&2
    exit 1
    ;;
esac

body_path=""
write_code=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      body_path=$2
      shift 2
      ;;
    -w)
      write_code=1
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

payload='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"dirextalk-message-server","version":"test"},"capabilities":{"tools":{}}}}'
if [ -n "$body_path" ]; then
  printf '%s\n' "$payload" > "$body_path"
else
  printf '%s\n' "$payload"
fi
[ "$write_code" -eq 1 ] && printf '200'
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.dirextalk/nodes/mcp-check.example.test"
mkdir -p "$service_dir"
credentials="$service_dir/credentials.json"
: > "$credentials"
state="$service_dir/state.json"
json_build object \
  run_id=mcp-doctor-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=mcp-check.example.test \
  as_url=https://mcp-check.example.test \
  agent_service_id=mcp-check.example.test \
  "agent_service_dir=$service_dir" \
  "agent_credentials_file=$credentials" \
  "mcp_credentials_file=$credentials" \
  mcp_endpoint_url=https://mcp-check.example.test/mcp \
  agent_token=AGENT_TOKEN_DOCTOR \
  agent_node_id=doctor-node \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

calls="$tmp/curl.calls"
verify_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CURL_CALLS="$calls" bash "$ROOT/scripts/orchestrate.sh" verify mcp_doctor)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_doctor'

json_test_check "$state" "data.runtime_checks.mcp_doctor.status === 'passed' && data.runtime_checks.mcp_doctor.endpoint === 'https://mcp-check.example.test/mcp' && data.runtime_checks.mcp_doctor.protocol_version === '2025-06-18' && data.runtime_checks.mcp_doctor.server_name === 'dirextalk-message-server' && data.runtime_checks.mcp_doctor.tools_capable === true && !data.user_confirmations?.agent_mcp_runtime"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.mcp_doctor.status === 'passed' && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

echo "mcp doctor runtime check ok"
