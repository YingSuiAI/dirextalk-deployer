#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d "$ROOT/.tmp-mcp-tools.XXXXXX")
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

want_url="https://mcp-tools.example.test/mcp"
case " $* " in
  *" $want_url "*|*" $want_url")
    ;;
  *)
    echo "unexpected curl URL: $*" >&2
    exit 1
    ;;
esac

case " $* " in *AGENT_TOKEN_TOOLS*) echo "token leaked into curl argv" >&2; exit 1 ;; esac
headers=
previous=
for arg in "$@"; do
  [ "$previous" != "-H" ] || { case "$arg" in @*) headers=${arg#@} ;; esac; }
  previous=$arg
done
[ -n "$headers" ] && grep -Fxq 'Authorization: Bearer AGENT_TOKEN_TOOLS' "$headers" || {
  echo "missing or wrong protected Authorization header" >&2
  exit 1
}

case " $* " in
  *'"method":"tools/list"'*) ;;
  *)
    echo "wrong MCP tools/list body: $*" >&2
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

payload='{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search_rooms"},{"name":"send_message"},{"name":"list_messages"}]}}'
if [ -n "$body_path" ]; then
  printf '%s\n' "$payload" > "$body_path"
else
  printf '%s\n' "$payload"
fi
[ "$write_code" -eq 1 ] && printf '200'
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.dirextalk/nodes/mcp-tools.example.test"
mkdir -p "$service_dir"
credentials="$service_dir/credentials.json"
: > "$credentials"
state="$service_dir/state.json"
json_build object \
  run_id=mcp-tools-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=mcp-tools.example.test \
  as_url=https://mcp-tools.example.test \
  agent_service_id=mcp-tools.example.test \
  "agent_service_dir=$service_dir" \
  "agent_credentials_file=$credentials" \
  "mcp_credentials_file=$credentials" \
  mcp_endpoint_url=https://mcp-tools.example.test/mcp \
  agent_token=AGENT_TOKEN_TOOLS \
  agent_node_id=tools-node \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

calls="$tmp/curl.calls"
verify_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CURL_CALLS="$calls" bash "$ROOT/scripts/orchestrate.sh" verify mcp_tools)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_tools'

json_test_check "$state" "data.runtime_checks.mcp_tools.status === 'passed' && data.runtime_checks.mcp_tools.endpoint === 'https://mcp-tools.example.test/mcp' && data.runtime_checks.mcp_tools.tool_count === 3 && data.runtime_checks.mcp_tools.tools.some((tool) => tool.name === 'search_rooms') && data.runtime_checks.mcp_tools.tools.some((tool) => tool.name === 'send_message') && data.runtime_checks.mcp_tools.tools.some((tool) => tool.name === 'list_messages') && !data.user_confirmations?.agent_mcp_runtime"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.mcp_tools.status === 'passed' && data.runtime_checks.mcp_tools.tool_count === 3 && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

echo "mcp tools runtime check ok"
