#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/ops.sh"
bootstrap_helper="$ROOT/scripts/cloud-init/split/bootstrap-production.sh"
common_helper="$ROOT/scripts/cloud-init/split/production-ops-common.sh"
reconcile_helper="$ROOT/scripts/cloud-init/split/reconcile-production.sh"
recover_helper="$ROOT/scripts/cloud-init/split/recover-production.sh"
reset_helper="$ROOT/scripts/cloud-init/split/reset-production.sh"
grep -Fq 'production_require_control_file "$production_edge_receipt" 400' "$common_helper"
grep -Fq 'production_require_control_file "$production_receipt" 400' "$common_helper"
grep -Fq 'control.env_identity' "$common_helper"
grep -Fq 'control.manifest_identity' "$common_helper"
grep -Fq '"$production_edge_id" 2>/dev/null' "$common_helper"
grep -Fq 'com.docker.compose.project' "$common_helper"
grep -Fq 'com.docker.compose.service' "$common_helper"
grep -Fq 'production_verify_edge' "$reconcile_helper"
grep -Fq 'bootstrap-production.sh" --reconcile-edge' "$reconcile_helper"
grep -Fq 'recover-production.sh"' "$reconcile_helper"
if grep -Fq 'start-local.sh' "$reconcile_helper"; then
  echo "production reconcile called the first-fresh start wrapper" >&2
  exit 1
fi
[ "$(grep -Fc 'production_verify_edge' "$reset_helper")" -eq 2 ]
grep -Fq 'docker container rm -f "$production_edge_id"' "$reset_helper"
grep -Fq 'cleanup-local.sh" --purge "$production_run"' "$reset_helper"
grep -Fq '"$production_base/runner-preparation.env"' "$reset_helper"
grep -Fq '"$production_base/production-ops/bootstrap-production.sh"' "$reset_helper"
if grep -Eq 'docker compose|docker volume rm|compose down' "$reconcile_helper" "$reset_helper"; then
  echo "production operations bypassed the receipt-bound canonical helpers" >&2
  exit 1
fi
production_helpers=$(ops_production_helpers_prelude)
bootstrap_payload=$(base64 <"$bootstrap_helper" | tr -d '\r\n')
grep -Fq "payload='$bootstrap_payload'" <<<"$production_helpers"
grep -Fq 'for helper in bootstrap-production.sh production-ops-common.sh recover-production.sh reconcile-production.sh reset-production.sh' <<<"$production_helpers"
grep -Fq 'install -o root -g root -m 0755 "$helper_tmp" "/var/dirextalk-message-server/production-ops/$helper"' <<<"$production_helpers"

# Exercise the real production reconcile wrapper with its owning helpers
# replaced by deterministic boundaries. The wrapper must distinguish success,
# an expected negative result, and infrastructure failure at the actual call
# site without inferring a status after an unmatched if.
reconcile_fixture="$tmp/reconcile-wrapper"
mkdir -p "$reconcile_fixture/split/scripts" "$reconcile_fixture/base/p2p"
cp "$reconcile_helper" "$reconcile_fixture/reconcile-production.sh"
cat >"$reconcile_fixture/recover-production.sh" <<'EOF'
#!/usr/bin/env bash
printf 'recover\n' >>"$RECONCILE_CALLS"
"$RECONCILE_SPLIT/scripts/restart-agent-local.sh" "$RECONCILE_RUN"
EOF
cat >"$reconcile_fixture/production-ops-common.sh" <<'EOF'
production_die() { printf 'die:%s\n' "$*" >>"$RECONCILE_CALLS"; exit 1; }
production_negative() { printf 'negative:%s\n' "$*" >>"$RECONCILE_CALLS"; exit 3; }
production_bind_runtime() {
  printf 'bind\n' >>"$RECONCILE_CALLS"
  RECONCILE_BIND_COUNT=$((RECONCILE_BIND_COUNT + 1))
  export RECONCILE_BIND_COUNT
  if [ "${RECONCILE_BIND_FAIL_AT:-0}" -eq "$RECONCILE_BIND_COUNT" ]; then
    production_die 'injected runtime identity rebind failure'
  fi
  production_base=$RECONCILE_BASE
  production_split=$RECONCILE_SPLIT
  production_run=$RECONCILE_RUN
  production_stack=d-abcdefghijklmnopqrstuvwxyz
  production_edge_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}
production_verify_edge() { printf 'verify-edge\n' >>"$RECONCILE_CALLS"; }
production_require_control_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a' "$1")" = "$(id -u):$2" ] || production_die 'invalid fixture control file'
}
EOF
cat >"$reconcile_fixture/bootstrap-production.sh" <<'EOF'
#!/usr/bin/env bash
printf 'edge:%s\n' "$*" >>"$RECONCILE_CALLS"
exit "${RECONCILE_EDGE_STATUS:-0}"
EOF
cat >"$reconcile_fixture/split/scripts/restart-agent-local.sh" <<'EOF'
#!/usr/bin/env bash
printf 'restart:%s\n' "$1" >>"$RECONCILE_CALLS"
exit "${RECONCILE_RESTART_STATUS:-0}"
EOF
cat >"$reconcile_fixture/split/scripts/export-portal-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'export:%s:%s\n' "$1" "$2" >>"$RECONCILE_CALLS"
case "${RECONCILE_EXPORT_MODE:-success}" in
  success)
    printf '%s\n' '{"access_token":"new-access","agent_token":"new-agent","password":"new-password","owner_user_id":"@owner:example.test"}' >"$2"
    chmod 0400 "$2"
    ;;
  fail) exit 17 ;;
  invalid)
    printf '%s\n' '{"access_token":"incomplete"}' >"$2"
    chmod 0400 "$2"
    ;;
  *) exit 18 ;;
esac
EOF
chmod 0755 "$reconcile_fixture/"*.sh "$reconcile_fixture/split/scripts/"*.sh
chmod 0700 "$reconcile_fixture/base/p2p"

write_old_bootstrap() {
  rm -f "$reconcile_fixture/base/p2p/bootstrap.json"
  printf '%s\n' '{"access_token":"old-access","agent_token":"old-agent","password":"old-password","owner_user_id":"@owner:old.example.test"}' \
    >"$reconcile_fixture/base/p2p/bootstrap.json"
  chmod 0400 "$reconcile_fixture/base/p2p/bootstrap.json"
}

run_reconcile_fixture() {
  RECONCILE_CALLS=$1 RECONCILE_BASE="$reconcile_fixture/base" \
    RECONCILE_SPLIT="$reconcile_fixture/split" RECONCILE_RUN="$reconcile_fixture/run" \
    RECONCILE_EDGE_STATUS=${2:-0} RECONCILE_RESTART_STATUS=${3:-0} \
    RECONCILE_EXPORT_MODE=${4:-success} RECONCILE_BIND_FAIL_AT=${5:-0} RECONCILE_BIND_COUNT=0 \
    bash "$reconcile_fixture/reconcile-production.sh" >/dev/null 2>&1
}

reconcile_success="$tmp/reconcile-success.calls"
write_old_bootstrap
run_reconcile_fixture "$reconcile_success"
grep -Fqx 'edge:--reconcile-edge' "$reconcile_success"
grep -Fqx 'recover' "$reconcile_success"
grep -Fqx "restart:$reconcile_fixture/run" "$reconcile_success"
grep -Eq "^export:$reconcile_fixture/run:$reconcile_fixture/base/p2p/\.bootstrap-refresh\.[^/]+/bootstrap\.json$" "$reconcile_success"
json_test_check "$reconcile_fixture/base/p2p/bootstrap.json" "data.access_token === 'new-access' && data.owner_user_id === '@owner:example.test'"
[ "$(stat -c '%a' "$reconcile_fixture/base/p2p/bootstrap.json")" = 400 ]

reconcile_negative="$tmp/reconcile-negative.calls"
write_old_bootstrap
if run_reconcile_fixture "$reconcile_negative" 0 3; then
  echo "production reconcile accepted an expected-negative runtime result" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fqx 'negative:existing runtime recovery reported an expected negative state' "$reconcile_negative"
if grep -Fq 'export:' "$reconcile_negative"; then
  echo "expected-negative reconcile continued after the runtime wrapper" >&2
  exit 1
fi

reconcile_infra="$tmp/reconcile-infrastructure.calls"
write_old_bootstrap
if run_reconcile_fixture "$reconcile_infra" 0 17; then
  echo "production reconcile accepted an infrastructure runtime failure" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:existing runtime recovery failed' "$reconcile_infra"
if grep -Fq 'export:' "$reconcile_infra"; then
  echo "infrastructure-failed reconcile continued after the runtime wrapper" >&2
  exit 1
fi

reconcile_export_failure="$tmp/reconcile-export-failure.calls"
write_old_bootstrap
old_bootstrap_sha=$(sha256sum "$reconcile_fixture/base/p2p/bootstrap.json" | awk '{print $1}')
if run_reconcile_fixture "$reconcile_export_failure" 0 0 fail; then
  echo "production reconcile accepted a portal bootstrap export failure" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ "$(sha256sum "$reconcile_fixture/base/p2p/bootstrap.json" | awk '{print $1}')" = "$old_bootstrap_sha" ]
grep -Fqx 'die:portal bootstrap refresh failed' "$reconcile_export_failure"

reconcile_identity_failure="$tmp/reconcile-identity-failure.calls"
write_old_bootstrap
old_bootstrap_sha=$(sha256sum "$reconcile_fixture/base/p2p/bootstrap.json" | awk '{print $1}')
if run_reconcile_fixture "$reconcile_identity_failure" 0 0 success 3; then
  echo "production reconcile accepted a runtime identity rebind failure" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ "$(sha256sum "$reconcile_fixture/base/p2p/bootstrap.json" | awk '{print $1}')" = "$old_bootstrap_sha" ]
grep -Fqx 'die:injected runtime identity rebind failure' "$reconcile_identity_failure"
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
printf 'ops.example.test ssh-ed25519 AAAATEST\n' > "$service_dir/known_hosts"

update_calls="$tmp/update.calls"
: > "$update_calls"
if CALLS="$update_calls" PATH="$fakebin:$PATH" CONNECT_WORK_DIR="$service_dir/dirextalk-connect" \
    bash "$ROOT/scripts/update.sh" "$state" >"$tmp/update.out" 2>&1; then
  echo 'update accepted legacy state without immutable node identity' >&2
  exit 1
fi
[ ! -s "$update_calls" ]
deprecated_remote_dir="/opt""/p2p"
json_test_check "$state" "data.split_release === undefined && data.updater_release === undefined && String(data.password) === '12345678' && data.access_token === 'ACCESS_SECRET' && data.agent_token === 'AGENT_SECRET'"

write_state "$state" "$service_dir"
printf 'ops.example.test ssh-ed25519 AAAATEST\n' > "$service_dir/known_hosts"
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

assert_contains "$reset_calls" 'sudo sh -lc'
assert_contains "$reset_calls" 'set-desired-state\.sh maintenance'
assert_contains "$reset_calls" 'set-desired-state\.sh running'
assert_contains "$reset_calls" 'base64 --decode'
assert_contains "$reset_calls" 'install -m 0755.*set-desired-state\.sh'
assert_contains "$reset_calls" 'install -o root -g root -m 0755.*reset-production\.sh'
assert_contains "$reset_calls" '/var/dirextalk-message-server/production-ops/reset-production\.sh'
deprecated_owner_file="wellknown/""owner\\.json"
assert_not_contains "$reset_calls" "$deprecated_remote_dir|$deprecated_owner_file"
assert_contains "$reset_calls" 'dirextalk-connect daemon status --service-name ops\.example\.test'
assert_contains "$reset_calls" 'dirextalk-connect daemon stop --service-name ops\.example\.test'
assert_not_contains "$reset_calls" 'docker compose|postgres-data|message-config|message-data|caddy-data|caddy-config|down -v'

json_test_check "$state" "!(data.password || data.access_token || data.agent_token || data.agent_room_id) && data.connect_install_status === 'refresh_pending' && data.mcp_install_status === 'refresh_pending' && !('mcp_host_probe_status' in data) && !('mcp_daemon_install_status' in data) && !('mcp_daemon_install_command' in data) && !('mcp_daemon_status_command' in data) && !('mcp_daemon_url' in data) && !('mcp_daemon_proxy_command' in data) && data.phases.S5_INIT_TOKENS.status === 'pending' && data.phases.S6_WIRE_LOCAL.status === 'pending' && data.phases.S7_VERIFY_E2E.status === 'pending' && !data.user_confirmations && !data.runtime_checks"

reset_report="$service_dir/operation-report.json"
assert_file_exists "$reset_report"
json_test_check "$reset_report" "data.operation_type === 'reset_app_data' && data.status === 'reset_remote_data_cleared_refresh_pending' && data.security.secrets_included === false && !('user_confirmation' in data.gates) && data.runtime_checks.summary.status === 'not_run' && data.connect.install_status === 'refresh_pending' && data.credentials.status === 'refresh_pending' && data.mcp.status === 'refresh_pending' && data.mcp.install_status === 'refresh_pending' && !('daemon_install_status' in data.mcp)"

echo "update reset ops ok"
