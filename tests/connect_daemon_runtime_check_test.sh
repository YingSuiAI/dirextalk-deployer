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
cat > "$fakebin/dirextalk-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "logs" ]; then
  [ "${3:-}" = "--service-name" ]
  [ "${4:-}" = "connect-check.example.test" ]
  printf '%s\n' "${CONNECT_LOG_OUTPUT:-}"
  exit 0
fi

[ "${1:-}" = "daemon" ]
[ "${2:-}" = "status" ]
[ "${3:-}" = "--service-name" ]
[ "${4:-}" = "connect-check.example.test" ]

cat <<STATUS
dirextalk-connect daemon status

  Status:    ${CONNECT_STATUS:-Running}
  Platform:  test
  WorkDir:   ${CONNECT_WORK_DIR:-}
STATUS
EOF
chmod 700 "$fakebin/dirextalk-connect"

service_dir="$HOME/.dirextalk/nodes/connect-check.example.test"
mkdir -p "$service_dir/dirextalk-connect"
config="$service_dir/dirextalk-connect/config.toml"
: > "$config"
state="$service_dir/state.json"
json_build object \
  run_id=connect-daemon-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=connect-check.example.test \
  agent_service_id=connect-check.example.test \
  "agent_service_dir=$service_dir" \
  "connect_config=$config" \
  connect_binary=dirextalk-connect \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

verify_output=$(DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: connect_daemon'

expected_work_dir="$service_dir/dirextalk-connect"
if command -v cygpath >/dev/null 2>&1; then
  expected_work_dir=$(cygpath -m "$expected_work_dir")
fi

json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'passed' && data.runtime_checks.connect_daemon.service_name === 'connect-check.example.test' && data.runtime_checks.connect_daemon.daemon_status === 'Running' && data.runtime_checks.connect_daemon.work_dir === '$expected_work_dir' && !data.user_confirmations?.agent_mcp_runtime"

assert_agent_log_failure() {
  local name=$1 log=$2 expected=$3 rc
  set +e
  DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" CONNECT_LOG_OUTPUT="$log" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/$name.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || {
    echo "connect daemon check must fail for $name log" >&2
    exit 1
  }
  json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'failed' && data.runtime_checks.connect_daemon.evidence.includes('local agent backend failure') && data.runtime_checks.connect_daemon.agent_error.includes('$expected')"
}

set +e
DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" CONNECT_LOG_OUTPUT='ACP error (ACP_SESSION_INIT_FAILED): ACP metadata is missing for agent:main:acp:a18569b4-1f24-4f8a-aec6-f6a54530d50e. Recreate this ACP session with /acp spawn and rebind the thread.' bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/acp-error.out" 2>&1
acp_rc=$?
set -e
[ "$acp_rc" -ne 0 ] || {
  echo "connect daemon check must fail when daemon logs show ACP session init failure" >&2
  exit 1
}
json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'failed' && data.runtime_checks.connect_daemon.evidence.includes('local agent backend failure') && data.runtime_checks.connect_daemon.agent_error.includes('ACP_SESSION_INIT_FAILED')"

assert_agent_log_failure cursor-cli-missing 'time=2026-07-01T16:59:10 level=ERROR msg="failed to create agent" project=cursor error="cursor: \"C:/Users/alice/AppData/Local/cursor-agent/agent.cmd\" CLI not found in PATH"' 'failed to create agent'
assert_agent_log_failure cursor-auth-required 'time=2026-07-01T17:00:18 level=ERROR msg="cursorSession: process failed" stderr="Error: Authentication required. Please run '\''agent login'\'' first, or set CURSOR_API_KEY environment variable."' 'Authentication required'
assert_agent_log_failure cursor-trust-required 'time=2026-07-01T17:04:00 level=ERROR msg="cursorSession: process failed" stderr="Workspace Trust Required. Pass --trust, --yolo, or -f if you trust this directory"' 'Workspace Trust Required'

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.connect_daemon.status === 'failed' && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

set +e
DIREXTALK_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$HOME/.dirextalk/nodes/other.example.test/dirextalk-connect" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/wrong.out" 2>&1
wrong_rc=$?
set -e
[ "$wrong_rc" -ne 0 ] || {
  echo "connect daemon check must fail when daemon WorkDir belongs to another service" >&2
  exit 1
}
json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'failed' && data.runtime_checks.connect_daemon.evidence.includes('different service')"

echo "connect daemon runtime check ok"
