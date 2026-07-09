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
cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$CURL_CALLS"

want_url="https://mcp-smoke.example.test/mcp"
case " $* " in
  *" $want_url "*|*" $want_url")
    ;;
  *)
    echo "unexpected curl URL: $*" >&2
    exit 1
    ;;
esac

case " $* " in
  *"Authorization: Bearer AGENT_TOKEN_SMOKE"*) ;;
  *)
    echo "missing or wrong Authorization header: $*" >&2
    exit 1
    ;;
esac

case " $* " in
  *'"method":"tools/call"'*'"name":"dirextalk_messages_list"'*'"room_id":"!agent:mcp-smoke.example.test"'*) ;;
  *)
    echo "wrong smoke request body: $*" >&2
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

payload='{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"[]"}],"isError":false}}'
if [ -n "$body_path" ]; then
  printf '%s\n' "$payload" > "$body_path"
else
  printf '%s\n' "$payload"
fi
[ "$write_code" -eq 1 ] && printf '200'
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.dirextalk/nodes/mcp-smoke.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
json_build object \
  run_id=mcp-smoke-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=mcp-smoke.example.test \
  as_url=https://mcp-smoke.example.test \
  mcp_endpoint_url=https://mcp-smoke.example.test/mcp \
  agent_service_id=mcp-smoke.example.test \
  "agent_service_dir=$service_dir" \
  agent_token=AGENT_TOKEN_SMOKE \
  agent_node_id=smoke-node \
  'agent_room_id=!agent:mcp-smoke.example.test' \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

calls="$tmp/curl.calls"
verify_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CURL_CALLS="$calls" bash "$ROOT/scripts/orchestrate.sh" verify mcp_smoke)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_smoke'

json_test_check "$state" "data.runtime_checks.mcp_smoke.status === 'passed' && data.runtime_checks.mcp_smoke.action === 'tools/call' && data.runtime_checks.mcp_smoke.tool_name === 'dirextalk_messages_list' && data.runtime_checks.mcp_smoke.room_id === '!agent:mcp-smoke.example.test' && data.runtime_checks.mcp_smoke.response_content_type === 'array' && !data.user_confirmations?.agent_mcp_runtime"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.mcp_smoke.status === 'passed' && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

echo "mcp smoke runtime check ok"
