#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d "$ROOT/.tmp-final-delivery-runtime.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
for tool in aws ssh scp; do
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
[ "${4:-}" = "final-delivery.example.test" ]
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) body_path=$2; shift 2 ;;
    -w) write_code=1; shift 2 ;;
    *) shift ;;
  esac
done

case "$args" in
  *"https://final-delivery.example.test/mcp"*)
    case "$args" in
      *"Authorization: Bearer AGENT_TOKEN_FINAL"*) ;;
      *)
        echo "missing or wrong Authorization header: $args" >&2
        exit 1
        ;;
    esac
    case "$args" in
      *'"method":"initialize"'*)
        payload='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"dirextalk-message-server","version":"test"},"capabilities":{"tools":{}}}}'
        ;;
      *'"method":"tools/list"'*)
        payload='{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"dirextalk_messages_list"}]}}'
        ;;
      *'"method":"tools/call"'*'"name":"dirextalk_messages_list"'*)
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

[ -n "$body_path" ] && printf '%s\n' "$payload" > "$body_path" || printf '%s\n' "$payload"
[ "$write_code" -eq 1 ] && printf '200'
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.dirextalk/nodes/final-delivery.example.test"
runtime_dir="$service_dir/dirextalk-connect"
mkdir -p "$runtime_dir"
config="$runtime_dir/config.toml"
: > "$config"
state="$service_dir/state.json"
json_build object \
  run_id=final-delivery-runtime-test \
  region=eu-west-2 \
  cloud_provider=lightsail \
  domain_mode=route53 \
  domain=final-delivery.example.test \
  domain_confirmed_irreversible=true \
  as_url=https://final-delivery.example.test \
  mcp_endpoint_url=https://final-delivery.example.test/mcp \
  password=12345678 \
  access_token=OWNER_ACCESS \
  agent_token=AGENT_TOKEN_FINAL \
  agent_node_id=final-node \
  'agent_room_id=!agent:final-delivery.example.test' \
  agent_service_id=final-delivery.example.test \
  "agent_service_dir=$service_dir" \
  "connect_config=$config" \
  connect_binary=dirextalk-connect \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={"instance_id":"i-final","public_ip":"203.0.113.21","key_file":"/tmp/key.pem"}' > "$state"

set +e
DIREXTALK_WORKDIR="$service_dir" DIREXTALK_EXISTING_STATE_ACTION=continue PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$HOME/.dirextalk/nodes/other.example.test/dirextalk-connect" bash "$ROOT/scripts/orchestrate.sh" > "$tmp/fail.out" 2>&1
fail_rc=$?
set -e
[ "$fail_rc" -ne 0 ] || {
  echo "final delivery must fail when connect daemon is not running for this service" >&2
  exit 1
}
grep -q 'Final delivery blocked because runtime checks did not all pass' "$tmp/fail.out"
if grep -q 'Automated Deployment Gates Passed' "$tmp/fail.out"; then
  echo "final delivery must not print success when runtime checks fail" >&2
  exit 1
fi
json_test_check "$state" "data.runtime_checks.summary.status === 'failed' && data.runtime_checks.connect_daemon.status === 'failed'"

pass_output=$(DIREXTALK_WORKDIR="$service_dir" DIREXTALK_EXISTING_STATE_ACTION=continue PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$runtime_dir" bash "$ROOT/scripts/orchestrate.sh")
printf '%s\n' "$pass_output" | grep -q 'Automated Deployment Gates Passed'
json_test_check "$state" "data.runtime_checks.summary.status === 'passed' && data.runtime_checks.connect_daemon.status === 'passed' && data.runtime_checks.mcp_doctor.status === 'passed' && data.runtime_checks.mcp_tools.status === 'passed' && data.runtime_checks.mcp_smoke.status === 'passed'"

echo "final delivery runtime gate ok"
