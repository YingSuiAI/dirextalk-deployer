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
for tool in aws ssh; do
  cat > "$fakebin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 700 "$fakebin/$tool"
done

cat > "$fakebin/dirextalk-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "daemon" ]
[ "${2:-}" = "status" ]
[ "${3:-}" = "--service-name" ]
[ "${4:-}" = "s7-mcp.example.test" ]
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

printf '%s\n' "$*" >> "$CURL_CALLS"

case " $* " in
  *"/_p2p/query"*)
    echo "legacy _p2p/query must not be used by S7 MCP acceptance" >&2
    exit 1
    ;;
esac

body_path=""
header_path=""
secret_headers=""
request_body=""
write_code=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o)
      body_path=${args[$((i + 1))]}
      ;;
    -D)
      header_path=${args[$((i + 1))]}
      ;;
    -w)
      write_code=1
      ;;
    -H)
      case "${args[$((i + 1))]}" in
        @*) secret_headers=$(cat "${args[$((i + 1))]#@}") ;;
      esac
      ;;
    -d)
      request_body=${args[$((i + 1))]}
      ;;
    --data-binary)
      case "${args[$((i + 1))]}" in
        @*) request_body=$(cat "${args[$((i + 1))]#@}") ;;
      esac
      ;;
  esac
done

url=""
for arg in "$@"; do
  case "$arg" in
    https://*) url=$arg ;;
  esac
done

body=""
code=200
case "$url" in
  https://s7-mcp.example.test/healthz)
    body='{"status":"ok"}'
    ;;
  https://s7-mcp.example.test/_matrix/client/versions)
    body='{"versions":["v1.0"]}'
    ;;
  https://s7-mcp.example.test/.well-known/matrix/server)
    body='{"m.server":"s7-mcp.example.test:443"}'
    ;;
  https://s7-mcp.example.test/.well-known/portal/owner.json)
    body='{"ok":true}'
    [ -n "$header_path" ] && printf 'HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: http://127.0.0.1:51820\r\n\r\n' > "$header_path"
    ;;
  https://s7-mcp.example.test/_p2p/command)
    body='{"access_token":"OWNER_ACCESS"}'
    ;;
  https://s7-mcp.example.test/_matrix/client/v3/voip/turnServer)
    body='{"username":"u","password":"p","ttl":86400,"uris":["turn:s7-mcp.example.test:3478?transport=udp"]}'
    ;;
  https://s7-mcp.example.test/mcp)
    case " $secret_headers $request_body " in
      *"Authorization: Bearer AGENT_TOKEN_S7"*'"method":"initialize"'*)
        body='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"dirextalk-message-server","version":"test"},"capabilities":{"tools":{}}}}'
        ;;
      *"Authorization: Bearer AGENT_TOKEN_S7"*'"method":"tools/list"'*)
        body='{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"dirextalk_messages_list"}]}}'
        ;;
      *"Authorization: Bearer AGENT_TOKEN_S7"*'"method":"tools/call"'*'"name":"dirextalk_messages_list"'*'"room_id":"!agent:s7-mcp.example.test"'*)
        body='{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"[]"}],"isError":false}}'
        ;;
      *)
        echo "unexpected MCP smoke request: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac

[ -n "$body_path" ] && printf '%s\n' "$body" > "$body_path" || printf '%s\n' "$body"
[ "$write_code" -eq 1 ] && printf '%s' "$code"
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.dirextalk/nodes/s7-mcp.example.test"
runtime_dir="$service_dir/dirextalk-connect"
mkdir -p "$runtime_dir"
config="$runtime_dir/config.toml"
: > "$config"
state="$service_dir/state.json"
json_build object \
  run_id=s7-mcp-test \
  region=ap-northeast-2 \
  cloud_provider=lightsail \
  domain_mode=route53 \
  domain=s7-mcp.example.test \
  domain_confirmed_irreversible=true \
  as_url=https://s7-mcp.example.test \
  mcp_endpoint_url=https://s7-mcp.example.test/mcp \
  password=12345678 \
  access_token=OWNER_ACCESS \
  agent_token=AGENT_TOKEN_S7 \
  agent_node_id=s7-node \
  'agent_room_id=!agent:s7-mcp.example.test' \
  agent_service_id=s7-mcp.example.test \
  "agent_service_dir=$service_dir" \
  "connect_config=$config" \
  connect_binary=dirextalk-connect \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"pending"}}' \
  'resources={"public_ip":"203.0.113.17"}' > "$state"

calls="$tmp/curl.calls"
run_output=$(DIREXTALK_WORKDIR="$service_dir" DIREXTALK_EXISTING_STATE_ACTION=continue PATH="$fakebin:$PATH" CURL_CALLS="$calls" CONNECT_WORK_DIR="$runtime_dir" bash "$ROOT/scripts/orchestrate.sh" 2>&1)
printf '%s\n' "$run_output" | grep -q 'HTTP MCP dirextalk_messages_list (agent token)'
printf '%s\n' "$run_output" | grep -q 'Automated Deployment Gates Passed'

json_test_check "$state" "data.phases.S7_VERIFY_E2E.status === 'done' && data.runtime_checks.mcp_smoke.status === 'passed' && data.runtime_checks.summary.status === 'passed'"
if grep -q '/_p2p/query' "$calls"; then
  echo "S7 must not call legacy /_p2p/query for MCP acceptance" >&2
  exit 1
fi
grep -q 'https://s7-mcp.example.test/mcp' "$calls"
if grep -q 'AGENT_TOKEN_S7\|OWNER_ACCESS\|12345678' "$calls"; then
  echo "S7 secrets must not appear in curl argv" >&2
  exit 1
fi

echo "s7 http mcp acceptance ok"
