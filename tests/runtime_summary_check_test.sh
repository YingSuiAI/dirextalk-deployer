#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d "$ROOT/.tmp-runtime-summary.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/dirextalk-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "logs" ]; then
  [ "${3:-}" = "--service-name" ]
  [ "${4:-}" = "runtime-summary.example.test" ]
  printf '%s\n' "${CONNECT_LOG_OUTPUT:-}"
  exit 0
fi
[ "${1:-}" = "daemon" ]
[ "${2:-}" = "status" ]
[ "${3:-}" = "--service-name" ]
[ "${4:-}" = "runtime-summary.example.test" ]
cat <<STATUS
dirextalk-connect daemon status

  Status:    Running
  Platform:  test
  WorkDir:   ${CONNECT_WORK_DIR:-}
STATUS
EOF
chmod 700 "$fakebin/dirextalk-connect"

cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body_path=""
write_code=0
args="$*"
secret_headers=""
direct_headers=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) body_path=$2; shift 2 ;;
    -w) write_code=1; shift 2 ;;
    -H)
      case "${2:-}" in
        @*) secret_headers=$(cat "${2#@}") ;;
        *) direct_headers+="${2:-}"$'\n' ;;
      esac
      shift 2
      ;;
    *) shift ;;
  esac
done

case "$args" in
  *"https://runtime-summary.example.test/mcp"*)
    case "$secret_headers" in
      *"Authorization: Bearer AGENT_TOKEN_RUNTIME"*) ;;
      *)
        echo "missing or wrong Authorization header: $args" >&2
        exit 1
        ;;
    esac
    case "$direct_headers" in
      *"MCP-Protocol-Version: 2025-06-18"*) ;;
      *)
        echo "missing MCP protocol version header" >&2
        exit 1
        ;;
    esac
    case "$args" in *AGENT_TOKEN_RUNTIME*) echo "token leaked into curl argv" >&2; exit 1 ;; esac
    case "$args" in
      *'"method":"initialize"'*)
        payload='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"dirextalk-message-server","version":"test"},"capabilities":{"tools":{}}}}'
        ;;
      *'"method":"tools/list"'*)
        payload='{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search_rooms"},{"name":"send_message"},{"name":"list_messages"}]}}'
        ;;
      *'"method":"tools/call"'*'"name":"dirextalk_messages_list"'*'"room_id":"!agent:runtime-summary.example.test"'*)
        payload='{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"[]"}],"isError":false}}'
        ;;
      *)
        echo "unexpected MCP body: $args" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected curl URL: $args" >&2
    exit 1
    ;;
esac

if [ -n "$body_path" ]; then
  printf '%s\n' "$payload" > "$body_path"
else
  printf '%s\n' "$payload"
fi
[ "$write_code" -eq 1 ] && printf '200'
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.dirextalk/nodes/runtime-summary.example.test"
mkdir -p "$service_dir/dirextalk-connect"
credentials="$service_dir/credentials.json"
config="$service_dir/dirextalk-connect/config.toml"
: > "$credentials"
: > "$config"
state="$service_dir/state.json"
json_build object \
  run_id=runtime-summary-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=runtime-summary.example.test \
  as_url=https://runtime-summary.example.test \
  agent_service_id=runtime-summary.example.test \
  "agent_service_dir=$service_dir" \
  "agent_credentials_file=$credentials" \
  "mcp_credentials_file=$credentials" \
  mcp_endpoint_url=https://runtime-summary.example.test/mcp \
  agent_token=AGENT_TOKEN_RUNTIME \
  agent_node_id=runtime-node \
  'agent_room_id=!agent:runtime-summary.example.test' \
  "connect_config=$config" \
  connect_binary=dirextalk-connect \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

verify_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" bash "$ROOT/scripts/orchestrate.sh" verify runtime)
printf '%s\n' "$verify_output" | grep -q 'verified runtime checks: passed'

json_test_check "$state" "data.runtime_checks.summary.status === 'passed' && data.runtime_checks.summary.failed_count === 0 && data.runtime_checks.summary.checks.connect_daemon === 'passed' && data.runtime_checks.summary.checks.mcp_doctor === 'passed' && data.runtime_checks.summary.checks.mcp_tools === 'passed' && data.runtime_checks.summary.checks.mcp_smoke === 'passed' && !data.user_confirmations?.agent_mcp_runtime"
json_test_check "$state" "data.runtime_checks.mcp_doctor.protocol_version === '2025-06-18' && data.runtime_checks.mcp_doctor.server_name === 'dirextalk-message-server' && data.runtime_checks.mcp_doctor.tools_capable === true && data.runtime_checks.mcp_smoke.action === 'tools/call' && data.runtime_checks.mcp_smoke.room_id === '!agent:runtime-summary.example.test' && data.runtime_checks.mcp_smoke.response_content_type === 'array'"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.summary.status === 'passed'"

set +e
DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" CONNECT_LOG_OUTPUT='ACP error (ACP_SESSION_INIT_FAILED): session metadata is missing.' bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/runtime-agent-error.out" 2>&1
agent_error_rc=$?
set -e
[ "$agent_error_rc" -ne 0 ] || {
  echo "connect daemon verification must fail when daemon logs report an ACP agent error" >&2
  exit 1
}
json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'failed' && data.runtime_checks.connect_daemon.agent_error.includes('ACP_SESSION_INIT_FAILED')"

set +e
DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$HOME/.dirextalk/nodes/other.example.test/dirextalk-connect" bash "$ROOT/scripts/orchestrate.sh" verify runtime > "$tmp/runtime-fail.out" 2>&1
fail_rc=$?
set -e
[ "$fail_rc" -ne 0 ] || {
  echo "runtime summary must fail when any runtime check fails" >&2
  exit 1
}
json_test_check "$state" "data.runtime_checks.summary.status === 'failed' && data.runtime_checks.summary.failed_count === 1 && data.runtime_checks.summary.checks.connect_daemon === 'failed' && data.runtime_checks.summary.checks.mcp_doctor === 'passed' && data.runtime_checks.summary.checks.mcp_tools === 'passed' && data.runtime_checks.summary.checks.mcp_smoke === 'passed'"

json_mutate "$state" set-string connect_install_policy recommend
json_mutate "$state" set-string connect_install_status recommend
verify_recommend_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$HOME/.dirextalk/nodes/other.example.test/dirextalk-connect" bash "$ROOT/scripts/orchestrate.sh" verify runtime)
printf '%s\n' "$verify_recommend_output" | grep -q 'verified runtime checks: passed'
json_test_check "$state" "data.runtime_checks.summary.status === 'passed' && data.runtime_checks.summary.failed_count === 0 && data.runtime_checks.summary.checks.connect_daemon === 'manual_pending' && data.runtime_checks.connect_daemon.status === 'manual_pending' && data.runtime_checks.mcp_doctor.status === 'passed' && data.runtime_checks.mcp_tools.status === 'passed' && data.runtime_checks.mcp_smoke.status === 'passed'"

echo "runtime summary check ok"
