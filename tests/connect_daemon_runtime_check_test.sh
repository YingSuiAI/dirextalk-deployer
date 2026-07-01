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
cat > "$fakebin/direxio-connect" <<'EOF'
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
direxio-connect daemon status

  Status:    ${CONNECT_STATUS:-Running}
  Platform:  test
  WorkDir:   ${CONNECT_WORK_DIR:-}
STATUS
EOF
chmod 700 "$fakebin/direxio-connect"

service_dir="$HOME/.direxio/nodes/connect-check.example.test"
mkdir -p "$service_dir/direxio-connect"
config="$service_dir/direxio-connect/config.toml"
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
  connect_binary=direxio-connect \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

verify_output=$(DIREXIO_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/direxio-connect" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: connect_daemon'

expected_work_dir="$service_dir/direxio-connect"
if command -v cygpath >/dev/null 2>&1; then
  expected_work_dir=$(cygpath -m "$expected_work_dir")
fi

json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'passed' && data.runtime_checks.connect_daemon.service_name === 'connect-check.example.test' && data.runtime_checks.connect_daemon.daemon_status === 'Running' && data.runtime_checks.connect_daemon.work_dir === '$expected_work_dir' && !data.user_confirmations?.agent_mcp_runtime"

set +e
DIREXIO_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/direxio-connect" CONNECT_LOG_OUTPUT='ACP error (ACP_SESSION_INIT_FAILED): ACP metadata is missing for agent:main:acp:a18569b4-1f24-4f8a-aec6-f6a54530d50e. Recreate this ACP session with /acp spawn and rebind the thread.' bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/acp-error.out" 2>&1
acp_rc=$?
set -e
[ "$acp_rc" -ne 0 ] || {
  echo "connect daemon check must fail when daemon logs show ACP session init failure" >&2
  exit 1
}
json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'failed' && data.runtime_checks.connect_daemon.evidence.includes('ACP session initialization failure') && data.runtime_checks.connect_daemon.agent_error.includes('ACP_SESSION_INIT_FAILED')"

report_output=$(DIREXIO_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.connect_daemon.status === 'failed' && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

set +e
DIREXIO_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$HOME/.direxio/nodes/other.example.test/direxio-connect" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/wrong.out" 2>&1
wrong_rc=$?
set -e
[ "$wrong_rc" -ne 0 ] || {
  echo "connect daemon check must fail when daemon WorkDir belongs to another service" >&2
  exit 1
}
json_test_check "$state" "data.runtime_checks.connect_daemon.status === 'failed' && data.runtime_checks.connect_daemon.evidence.includes('different service')"

echo "connect daemon runtime check ok"
