#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
exit 0
EOF
chmod 700 "$fakebin/ssh"

cat > "$fakebin/direxio-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'direxio-connect' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "status" ]; then
  cat <<STATUS
Status:   ${CONNECT_STATUS:-Running}
WorkDir:  ${CONNECT_WORK_DIR:-}
STATUS
fi
exit 0
EOF
chmod 700 "$fakebin/direxio-connect"

write_state() {
  local state=$1 service_dir=$2
  mkdir -p "$(dirname "$state")" "$service_dir"
  jq -n \
    --arg service_dir "$service_dir" \
    '{
      run_id: "ops-test",
      region: "ap-northeast-1",
      domain_mode: "user",
      domain: "ops.example.test",
      as_url: "https://ops.example.test",
      instance_type: "t3.small",
      password: "12345678",
      access_token: "ACCESS_SECRET",
      agent_token: "AGENT_SECRET",
      agent_room_id: "!old:ops.example.test",
      agent_service_id: "ops.example.test",
      agent_service_dir: $service_dir,
      agent_credentials_file: ($service_dir + "/credentials.json"),
      agent_install_status: "installed",
      cc_connect_config: ($service_dir + "/cc-connect/config.toml"),
      cc_connect_binary: "direxio-connect",
      cc_connect_agent: "codex",
      mcp_config_dir: ($service_dir + "/mcp"),
      mcp_codex_config: ($service_dir + "/mcp/codex.toml"),
      mcp_openclaw_config: ($service_dir + "/mcp/openclaw.mcp.json"),
      mcp_hermes_config: ($service_dir + "/mcp/hermes.mcp.json"),
      mcp_doctor_command: ("DIREXIO_CREDENTIALS_FILE=" + $service_dir + "/credentials.json direxio-mcp doctor --json"),
      resources: {
        instance_id: "i-ops",
        public_ip: "203.0.113.77",
        eip_id: "eipalloc-ops",
        key_file: "/tmp/ops.pem"
      },
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
      user_confirmations: {
        app_initialization: {status: "confirmed", evidence: "old app confirmation"},
        real_chat: {status: "confirmed", evidence: "old chat confirmation"},
        agent_mcp_runtime: {
          status: "confirmed",
          evidence: "old runtime confirmation",
          runtime_summary_status: "passed",
          runtime_probe_confirmed: true
        }
      },
      runtime_checks: {
        summary: {status: "passed"},
        connect_daemon: {status: "passed"},
        mcp_doctor: {status: "passed"},
        mcp_smoke: {status: "passed"},
        mcp_tools: {status: "passed"}
      }
    }' > "$state"
}

assert_file_exists() {
  [ -s "$1" ] || {
    echo "expected non-empty file: $1" >&2
    exit 1
  }
}

assert_not_contains() {
  local path=$1 pattern=$2
  if grep -E "$pattern" "$path" >/dev/null; then
    echo "unexpected pattern in $path: $pattern" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_contains() {
  local path=$1 pattern=$2
  if ! grep -E "$pattern" "$path" >/dev/null; then
    echo "missing pattern in $path: $pattern" >&2
    cat "$path" >&2
    exit 1
  fi
}

service_dir="$HOME/.direxio/nodes/ops.example.test"
state="$service_dir/state.json"
write_state "$state" "$service_dir"

update_calls="$tmp/update.calls"
: > "$update_calls"
CALLS="$update_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/cc-connect" MESSAGE_SERVER_IMAGE="direxio/message-server:test" bash "$ROOT/scripts/update.sh" "$state" > "$tmp/update.out"
assert_contains "$tmp/update.out" 'Old user confirmations and runtime checks were cleared'
assert_contains "$tmp/update.out" 'Scoped local bridge daemon was stopped'
assert_contains "$tmp/update.out" 'rerun orchestrate with P2P_EXISTING_STATE_ACTION=continue'

assert_contains "$update_calls" 'docker compose --env-file \.env pull'
assert_contains "$update_calls" 'docker compose --env-file \.env up -d'
assert_contains "$update_calls" 'bash /opt/p2p/init-tokens\.sh'
assert_contains "$update_calls" 'direxio/message-server:test'
assert_contains "$update_calls" 'MESSAGE_SERVER_IMAGE=\$escaped_image'
assert_contains "$update_calls" 'direxio-connect daemon status --service-name ops\.example\.test'
assert_contains "$update_calls" 'direxio-connect daemon stop --service-name ops\.example\.test'
assert_not_contains "$update_calls" 'volume rm|down -v|postgres-data|message-config|message-data|caddy-data|caddy-config'

jq -e '
  (.password // "") == ""
  and (.access_token // "") == ""
  and (.agent_token // "") == ""
  and (.agent_room_id // "") == ""
  and .agent_install_status == "refresh_pending"
  and .phases.S4_BOOTSTRAP_STACK.status == "pending"
  and .phases.S5_INIT_TOKENS.status == "pending"
  and .phases.S6_WIRE_LOCAL.status == "pending"
  and .phases.S7_VERIFY_E2E.status == "pending"
  and (.user_confirmations | not)
  and (.runtime_checks | not)
' "$state" >/dev/null

update_report="$service_dir/operation-report.json"
assert_file_exists "$update_report"
jq -e '
  .operation_type == "update"
  and .status == "update_remote_restart_complete_refresh_pending"
  and .security.secrets_included == false
  and .gates.user_confirmation.app_initialization == "pending_user_confirmation"
  and .gates.user_confirmation.real_chat == "pending_user_confirmation"
  and .gates.user_confirmation.agent_mcp_runtime == "pending_runtime_confirmation"
  and .runtime_checks.summary.status == "not_run"
  and .connect.install_status == "refresh_pending"
  and .credentials.status == "refresh_pending"
  and .mcp.status == "refresh_pending"
' "$update_report" >/dev/null

write_state "$state" "$service_dir"
if CALLS="$tmp/reset-unconfirmed.calls" PATH="$fakebin:$PATH" bash "$ROOT/scripts/reset-app-data.sh" "$state" >/dev/null 2>&1; then
  echo "reset-app-data must require explicit confirmation" >&2
  exit 1
fi

reset_calls="$tmp/reset.calls"
: > "$reset_calls"
CALLS="$reset_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/cc-connect" DIREXIO_RESET_APP_DATA_CONFIRM=1 bash "$ROOT/scripts/reset-app-data.sh" "$state" > "$tmp/reset.out"
assert_contains "$tmp/reset.out" 'Old user confirmations and runtime checks were cleared'
assert_contains "$tmp/reset.out" 'Scoped local bridge daemon was stopped'
assert_contains "$tmp/reset.out" 'rerun orchestrate with P2P_EXISTING_STATE_ACTION=continue'

assert_contains "$reset_calls" 'docker compose --env-file \.env down'
assert_contains "$reset_calls" 'docker volume rm'
assert_contains "$reset_calls" 'postgres-data'
assert_contains "$reset_calls" 'message-config'
assert_contains "$reset_calls" 'message-data'
assert_contains "$reset_calls" 'docker compose --env-file \.env up -d'
assert_contains "$reset_calls" 'bash /opt/p2p/init-tokens\.sh'
assert_contains "$reset_calls" 'direxio-connect daemon status --service-name ops\.example\.test'
assert_contains "$reset_calls" 'direxio-connect daemon stop --service-name ops\.example\.test'
assert_not_contains "$reset_calls" 'caddy-data|caddy-config|down -v'

jq -e '
  (.password // "") == ""
  and (.access_token // "") == ""
  and (.agent_token // "") == ""
  and (.agent_room_id // "") == ""
  and .agent_install_status == "refresh_pending"
  and .phases.S5_INIT_TOKENS.status == "pending"
  and .phases.S6_WIRE_LOCAL.status == "pending"
  and .phases.S7_VERIFY_E2E.status == "pending"
  and (.user_confirmations | not)
  and (.runtime_checks | not)
' "$state" >/dev/null

reset_report="$service_dir/operation-report.json"
assert_file_exists "$reset_report"
jq -e '
  .operation_type == "reset_app_data"
  and .status == "reset_remote_data_cleared_refresh_pending"
  and .security.secrets_included == false
  and .gates.user_confirmation.app_initialization == "pending_user_confirmation"
  and .gates.user_confirmation.real_chat == "pending_user_confirmation"
  and .gates.user_confirmation.agent_mcp_runtime == "pending_runtime_confirmation"
  and .runtime_checks.summary.status == "not_run"
  and .connect.install_status == "refresh_pending"
  and .credentials.status == "refresh_pending"
  and .mcp.status == "refresh_pending"
' "$reset_report" >/dev/null

echo "update reset ops ok"
