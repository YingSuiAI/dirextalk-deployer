#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/ops.sh"
ops_desired_state_helper_payload | base64 --decode > "$tmp/decoded-desired-state-helper.sh"
cmp "$ROOT/scripts/updater/set-desired-state.sh" "$tmp/decoded-desired-state-helper.sh"
legacy_root="$tmp/base-99f55dd-remote"
mkdir -p "$legacy_root/var/dirextalk-message-server/updater"
[ ! -e "$legacy_root/var/dirextalk-message-server/updater/set-desired-state.sh" ]
legacy_prelude=$(ops_desired_state_helper_prelude)
legacy_prelude=${legacy_prelude//\/var\/dirextalk-message-server/$legacy_root\/var\/dirextalk-message-server}
legacy_prelude=${legacy_prelude//sudo /}
bash -c "$legacy_prelude"
cmp "$ROOT/scripts/updater/set-desired-state.sh" "$legacy_root/var/dirextalk-message-server/updater/set-desired-state.sh"
[ -x "$legacy_root/var/dirextalk-message-server/updater/set-desired-state.sh" ]

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
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

cat > "$fakebin/dirextalk-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'dirextalk-connect' >> "$CALLS"
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
chmod 700 "$fakebin/dirextalk-connect"

write_state() {
  local state=$1 service_dir=$2
  mkdir -p "$(dirname "$state")" "$service_dir"
  json_build object \
    run_id=ops-test \
    region=ap-northeast-1 \
    domain_mode=user \
    domain=ops.example.test \
    as_url=https://ops.example.test \
    instance_type=t3.small \
    password=12345678 \
    access_token=ACCESS_SECRET \
    agent_token=AGENT_SECRET \
    'agent_room_id=!old:ops.example.test' \
    agent_service_id=ops.example.test \
    "agent_service_dir=$service_dir" \
    "agent_credentials_file=$service_dir/credentials.json" \
    connect_install_status=installed \
    "connect_config=$service_dir/dirextalk-connect/config.toml" \
    connect_binary=dirextalk-connect \
    connect_agent=codex \
    "mcp_config_dir=$service_dir/mcp" \
    "mcp_codex_config=$service_dir/mcp/codex.toml" \
    "mcp_openclaw_config=$service_dir/mcp/openclaw.md" \
    "mcp_hermes_config=$service_dir/mcp/hermes.mcp.json" \
    "mcp_doctor_command=legacy local MCP doctor command" \
    mcp_install_status=installed \
    mcp_host_probe_status=passed \
    mcp_daemon_install_status=installed \
    'mcp_daemon_install_command=legacy local MCP daemon install command' \
    'mcp_daemon_status_command=legacy local MCP daemon status command' \
    mcp_daemon_url=http://127.0.0.1:19757/mcp \
    'mcp_daemon_proxy_command=legacy local MCP proxy command' \
    'resources={"instance_id":"i-ops","public_ip":"203.0.113.77","eip_id":"eipalloc-ops","key_file":"/tmp/ops.pem"}' \
    'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
    'user_confirmations={"app_initialization":{"status":"confirmed","evidence":"old app confirmation"},"real_chat":{"status":"confirmed","evidence":"old chat confirmation"},"agent_mcp_runtime":{"status":"confirmed","evidence":"old runtime confirmation","runtime_summary_status":"passed","runtime_probe_confirmed":true}}' \
    'runtime_checks={"summary":{"status":"passed"},"connect_daemon":{"status":"passed"},"mcp_doctor":{"status":"passed"},"mcp_smoke":{"status":"passed"},"mcp_tools":{"status":"passed"}}' > "$state"
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

service_dir="$HOME/.dirextalk/nodes/ops.example.test"
state="$service_dir/state.json"
write_state "$state" "$service_dir"

update_calls="$tmp/update.calls"
: > "$update_calls"
if CALLS="$update_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" MESSAGE_SERVER_IMAGE="dirextalk/message-server:test" bash "$ROOT/scripts/update.sh" "$state" > "$tmp/update-unconfirmed.out" 2>&1; then
  echo "update image override must require explicit debug/legacy confirmation" >&2
  exit 1
fi
for unsafe_image in \
  'dirextalk/message-server:debug#e touch /tmp/injected' \
  $'dirextalk/message-server:debug\n#e touch /tmp/injected' \
  $'dirextalk/message-server:debug\rbroken' \
  $'dirextalk/message-server:debug\tbroken' \
  'dirextalk/message-server:debug broken'; do
  : > "$update_calls"
  if CALLS="$update_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" \
    MESSAGE_SERVER_IMAGE="$unsafe_image" DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
    bash "$ROOT/scripts/update.sh" "$state" > "$tmp/update-unsafe.out" 2>&1; then
    echo "unsafe debug image override reached update SSH path" >&2
    exit 1
  fi
  [ ! -s "$update_calls" ] || { echo "unsafe debug image override reached SSH" >&2; cat "$update_calls" >&2; exit 1; }
done
CALLS="$update_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" MESSAGE_SERVER_IMAGE="dirextalk/message-server:test" DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 bash "$ROOT/scripts/update.sh" "$state" > "$tmp/update.out"
assert_not_contains "$tmp/update.out" 'Old credentials and runtime checks were cleared'
assert_not_contains "$tmp/update.out" 'Scoped local bridge daemon was stopped'
assert_not_contains "$tmp/update.out" 'rerun orchestrate with DIREXTALK_EXISTING_STATE_ACTION=continue'

assert_contains "$update_calls" 'docker compose --env-file \.env pull'
assert_contains "$update_calls" 'docker compose --env-file \.env up -d'
assert_contains "$update_calls" 'set-desired-state\.sh maintenance'
assert_contains "$update_calls" 'set-desired-state\.sh running'
assert_contains "$update_calls" 'base64 --decode'
assert_contains "$update_calls" 'install -m 0755.*set-desired-state\.sh'
assert_contains "$update_calls" 'cd /var/dirextalk-message-server'
assert_contains "$update_calls" 'bash /var/dirextalk-message-server/init-tokens\.sh'
assert_contains "$update_calls" '/var/dirextalk-message-server/p2p/bootstrap\.json'
assert_contains "$update_calls" 'dirextalk/message-server:test'
assert_contains "$update_calls" 'MESSAGE_SERVER_IMAGE=\$escaped_image'
deprecated_remote_dir="/opt""/p2p"
assert_not_contains "$update_calls" "$deprecated_remote_dir|exec -T message-server sh -c .*bootstrap\\.json"
assert_not_contains "$update_calls" 'dirextalk-connect daemon status --service-name ops\.example\.test'
assert_not_contains "$update_calls" 'dirextalk-connect daemon stop --service-name ops\.example\.test'
assert_not_contains "$update_calls" 'volume rm|down -v|postgres-data|message-config|message-data|caddy-data|caddy-config'

write_state "$state" "$service_dir"
update_default_calls="$tmp/update-default.calls"
: > "$update_default_calls"
env -u MESSAGE_SERVER_IMAGE CALLS="$update_default_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" bash "$ROOT/scripts/update.sh" "$state" > "$tmp/update-default.out"
assert_contains "$update_default_calls" 'sudo sh -lc'
assert_not_contains "$update_default_calls" 'sudo MESSAGE_SERVER_IMAGE='
assert_contains "$update_default_calls" 'docker compose --env-file \.env pull'
assert_contains "$update_default_calls" 'docker compose --env-file \.env up -d'

json_test_check "$state" "String(data.password) === '12345678' && data.access_token === 'ACCESS_SECRET' && data.agent_token === 'AGENT_SECRET' && data.agent_room_id === '!old:ops.example.test' && data.connect_install_status === 'installed' && data.phases.S4_BOOTSTRAP_STACK.status === 'done' && data.phases.S5_INIT_TOKENS.status === 'done' && data.phases.S6_WIRE_LOCAL.status === 'done' && data.phases.S7_VERIFY_E2E.status === 'done' && data.user_confirmations.agent_mcp_runtime.status === 'confirmed' && data.runtime_checks.summary.status === 'passed'"

update_report="$service_dir/operation-report.json"
assert_file_exists "$update_report"
json_test_check "$update_report" "data.operation_type === 'update' && data.status === 'update_remote_restart_complete' && data.security.secrets_included === false && !('user_confirmation' in data.gates) && data.runtime_checks.summary.status === 'passed' && data.connect.install_status === 'installed' && data.credentials.status === 'current_or_not_recorded' && data.mcp.status === 'current_or_not_recorded'"

write_state "$state" "$service_dir"
if CALLS="$tmp/reset-unconfirmed.calls" PATH="$fakebin:$PATH" bash "$ROOT/scripts/reset-app-data.sh" "$state" >/dev/null 2>&1; then
  echo "reset-app-data must require explicit confirmation" >&2
  exit 1
fi

reset_calls="$tmp/reset.calls"
: > "$reset_calls"
CALLS="$reset_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" DIREXTALK_RESET_APP_DATA_CONFIRM=1 bash "$ROOT/scripts/reset-app-data.sh" "$state" > "$tmp/reset.out"
assert_contains "$tmp/reset.out" 'Old credentials and runtime checks were cleared'
assert_contains "$tmp/reset.out" 'Scoped local bridge daemon was stopped'
assert_contains "$tmp/reset.out" 'rerun orchestrate with DIREXTALK_EXISTING_STATE_ACTION=continue'

assert_contains "$reset_calls" 'docker compose --env-file \.env down'
assert_contains "$reset_calls" 'sudo sh -lc'
assert_contains "$reset_calls" 'set-desired-state\.sh maintenance'
assert_contains "$reset_calls" 'set-desired-state\.sh running'
assert_contains "$reset_calls" 'base64 --decode'
assert_contains "$reset_calls" 'install -m 0755.*set-desired-state\.sh'
assert_contains "$reset_calls" 'docker volume rm'
assert_contains "$reset_calls" 'postgres-data'
assert_contains "$reset_calls" 'message-config'
assert_contains "$reset_calls" 'message-data'
assert_contains "$reset_calls" 'docker compose --env-file \.env up -d'
assert_contains "$reset_calls" 'cd /var/dirextalk-message-server'
assert_contains "$reset_calls" 'bash /var/dirextalk-message-server/init-tokens\.sh'
assert_contains "$reset_calls" '/var/dirextalk-message-server/p2p/bootstrap\.json'
assert_contains "$reset_calls" 'rm -f /var/dirextalk-message-server/p2p/bootstrap\.json'
deprecated_owner_file="wellknown/""owner\\.json"
assert_not_contains "$reset_calls" "$deprecated_remote_dir|$deprecated_owner_file"
assert_contains "$reset_calls" 'dirextalk-connect daemon status --service-name ops\.example\.test'
assert_contains "$reset_calls" 'dirextalk-connect daemon stop --service-name ops\.example\.test'
assert_not_contains "$reset_calls" 'caddy-data|caddy-config|down -v'

json_test_check "$state" "!(data.password || data.access_token || data.agent_token || data.agent_room_id) && data.connect_install_status === 'refresh_pending' && data.mcp_install_status === 'refresh_pending' && !('mcp_host_probe_status' in data) && !('mcp_daemon_install_status' in data) && !('mcp_daemon_install_command' in data) && !('mcp_daemon_status_command' in data) && !('mcp_daemon_url' in data) && !('mcp_daemon_proxy_command' in data) && data.phases.S5_INIT_TOKENS.status === 'pending' && data.phases.S6_WIRE_LOCAL.status === 'pending' && data.phases.S7_VERIFY_E2E.status === 'pending' && !data.user_confirmations && !data.runtime_checks"

reset_report="$service_dir/operation-report.json"
assert_file_exists "$reset_report"
json_test_check "$reset_report" "data.operation_type === 'reset_app_data' && data.status === 'reset_remote_data_cleared_refresh_pending' && data.security.secrets_included === false && !('user_confirmation' in data.gates) && data.runtime_checks.summary.status === 'not_run' && data.connect.install_status === 'refresh_pending' && data.credentials.status === 'refresh_pending' && data.mcp.status === 'refresh_pending' && data.mcp.install_status === 'refresh_pending' && !('daemon_install_status' in data.mcp)"

# Private Agent ECR nodes must fail before SSH until update/reset own the same
# short-lived, pinned-host auth refresh implemented by the deployment workflow.
write_state "$state" "$service_dir"
json_mutate "$state" set-json agent_registry '{"source":"private_ecr"}'
: > "$update_calls"
if CALLS="$update_calls" PATH="$fakebin:$PATH" bash "$ROOT/scripts/update.sh" "$state" > "$tmp/update-private-ecr.out" 2>&1; then
  echo "update must fail closed for private Agent ECR without safe auth refresh" >&2
  exit 1
fi
grep -q 'no pinned-SSH short-lived registry-auth refresh path' "$tmp/update-private-ecr.out"
[ ! -s "$update_calls" ]
: > "$reset_calls"
if CALLS="$reset_calls" PATH="$fakebin:$PATH" DIREXTALK_RESET_APP_DATA_CONFIRM=1 bash "$ROOT/scripts/reset-app-data.sh" "$state" > "$tmp/reset-private-ecr.out" 2>&1; then
  echo "reset must fail closed for private Agent ECR without safe auth refresh" >&2
  exit 1
fi
grep -q 'no pinned-SSH short-lived registry-auth refresh path' "$tmp/reset-private-ecr.out"
[ ! -s "$reset_calls" ]

echo "update reset ops ok"
