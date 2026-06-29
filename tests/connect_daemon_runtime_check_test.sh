#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/direxio-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = "daemon" ]
[ "${2:-}" = "status" ]
[ "${3:-}" = "--service-name" ]
[ "${4:-}" = "connect-check.example.test" ]

cat <<STATUS
cc-connect daemon status

  Status:    ${CONNECT_STATUS:-Running}
  Platform:  test
  WorkDir:   ${CONNECT_WORK_DIR:-}
STATUS
EOF
chmod 700 "$fakebin/direxio-connect"

service_dir="$HOME/.direxio/nodes/connect-check.example.test"
mkdir -p "$service_dir/cc-connect"
config="$service_dir/cc-connect/config.toml"
: > "$config"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  --arg config "$config" \
  '{
    run_id: "connect-daemon-test",
    region: "ap-northeast-1",
    domain_mode: "user",
    domain: "connect-check.example.test",
    agent_service_id: "connect-check.example.test",
    agent_service_dir: $service_dir,
    cc_connect_config: $config,
    cc_connect_binary: "direxio-connect",
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

verify_output=$(P2P_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/cc-connect" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: connect_daemon'

jq -e '
  .runtime_checks.connect_daemon.status == "passed"
  and .runtime_checks.connect_daemon.service_name == "connect-check.example.test"
  and .runtime_checks.connect_daemon.daemon_status == "Running"
  and .runtime_checks.connect_daemon.work_dir == "'"$service_dir"'/cc-connect"
  and (.user_confirmations.agent_mcp_runtime | not)
' "$state" >/dev/null

report_output=$(P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
jq -e '
  .runtime_checks.connect_daemon.status == "passed"
  and .gates.user_confirmation.agent_mcp_runtime == "pending_runtime_confirmation"
' "$report_path" >/dev/null

set +e
P2P_WORKDIR="$service_dir" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$HOME/.direxio/nodes/other.example.test/cc-connect" bash "$ROOT/scripts/orchestrate.sh" verify connect_daemon > "$tmp/wrong.out" 2>&1
wrong_rc=$?
set -e
[ "$wrong_rc" -ne 0 ] || {
  echo "connect daemon check must fail when daemon WorkDir belongs to another service" >&2
  exit 1
}
jq -e '
  .runtime_checks.connect_daemon.status == "failed"
  and (.runtime_checks.connect_daemon.evidence | contains("different service"))
' "$state" >/dev/null

echo "connect daemon runtime check ok"
