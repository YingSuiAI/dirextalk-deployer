#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dirextalk_test_isolate_homes "$tmp"
export DIREXTALK_AGENT_DETECT_PROCESS=0
export DIREXTALK_LOCAL_PATH_STYLE=posix
export DIREXTALK_SPEECH_ENABLED=false

# shellcheck disable=SC1090
source "$ROOT/scripts/phases/s6_wire_local.sh"

ok() { :; }
warn() { printf '%s\n' "$*" >&2; }
fail() { printf '%s\n' "$*" >&2; return 1; }

state_get() {
  case "$1" in
    domain) printf 'service.example.test\n' ;;
    as_url) printf 'https://service.example.test\n' ;;
    agent_token) printf 'agent-token\n' ;;
    access_token) printf 'owner-token\n' ;;
    password) printf '12345678\n' ;;
    agent_room_id) printf '!agents-real:service.example.test\n' ;;
    *) return 0 ;;
  esac
}

phase_set() {
  printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >> "${PHASE_CALLS:?}"
}

state_set() {
  printf '%s=%s\n' "$1" "$2" >> "${STATE_CALLS:?}"
}

_ensure_connect_wrapper() { :; }
_create_connect_matrix_session() {
  local output=$4
  mkdir -p "$(dirname "$output")"
  json_build object \
    access_token=matrix-token \
    device_id=DEVICE \
    'user_id=@agent:service.example.test' \
    homeserver=https://service.example.test > "$output"
}
_maybe_auto_install_agent() { return 0; }
_print_connect_guidance() { :; }
_print_mcp_guidance() { :; }

run_failure_case() {
  local name=$1 case_dir="$tmp/$1"
  mkdir -p "$case_dir"
  DIREXTALK_HOME="$case_dir/dirextalk"
  export DIREXTALK_HOME
  dirextalk_test_assert_isolated_homes "$tmp"
  PHASE_CALLS="$case_dir/phases.log"
  STATE_CALLS="$case_dir/state.log"
  STATE_JSON="$case_dir/state.json"
  export PHASE_CALLS STATE_CALLS STATE_JSON
  : > "$PHASE_CALLS"
  : > "$STATE_CALLS"
  json_build object > "$STATE_JSON"

  unset DIREXTALK_AGENT_PLATFORM DIREXTALK_CONNECT_AGENT DIREXTALK_CONNECT_AGENT_OPTIONS_TOML
  unset DIREXTALK_AGENT_INSTALL DIREXTALK_AGENT_INSTALL_MODE
  unset DIREXTALK_OPENCLAW_ACP_URL DIREXTALK_OPENCLAW_ACP_TOKEN_FILE DIREXTALK_OPENCLAW_ACP_SESSION
  DIREXTALK_AGENT_INSTALL=skip
  DIREXTALK_AGENT_INSTALL_MODE=recommended
  export DIREXTALK_AGENT_INSTALL DIREXTALK_AGENT_INSTALL_MODE

  # Restore the default MCP enrollment helper after the dedicated failure case.
  unset -f _maybe_auto_install_mcp 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib/mcp-client-adapters.sh"

  case "$name" in
    invalid_runtime)
      DIREXTALK_AGENT_PLATFORM=not-a-runtime
      ;;
    invalid_agent)
      DIREXTALK_AGENT_PLATFORM=auto
      DIREXTALK_CONNECT_AGENT=not-an-agent
      ;;
    invalid_options)
      DIREXTALK_AGENT_PLATFORM=openclaw
      DIREXTALK_OPENCLAW_ACP_URL=ws://127.0.0.1:18790
      ;;
    invalid_policy)
      DIREXTALK_AGENT_PLATFORM=codex
      DIREXTALK_AGENT_INSTALL=invalid
      ;;
    invalid_mode)
      DIREXTALK_AGENT_PLATFORM=codex
      DIREXTALK_AGENT_INSTALL_MODE=invalid
      ;;
    host_openclaw_override)
      DIREXTALK_AGENT_PLATFORM=openclaw
      DIREXTALK_CONNECT_AGENT=codex
      ;;
    host_hermes_override)
      DIREXTALK_AGENT_PLATFORM=hermes
      DIREXTALK_CONNECT_AGENT=codex
      ;;
    mcp_enrollment)
      DIREXTALK_AGENT_PLATFORM=codex
      DIREXTALK_AGENT_INSTALL=auto
      _maybe_auto_install_mcp() { return 1; }
      ;;
    artifact_path_directory)
      DIREXTALK_AGENT_PLATFORM=codex
      mkdir -p "$DIREXTALK_HOME/nodes/service.example.test/mcp/codex.toml"
      ;;
    connect_config_path_directory)
      DIREXTALK_AGENT_PLATFORM=codex
      mkdir -p "$DIREXTALK_HOME/nodes/service.example.test/dirextalk-connect/config.toml"
      ;;
    *)
      echo "unknown case: $name" >&2
      return 2
      ;;
  esac
  export DIREXTALK_AGENT_PLATFORM DIREXTALK_CONNECT_AGENT DIREXTALK_AGENT_INSTALL DIREXTALK_AGENT_INSTALL_MODE
  export DIREXTALK_OPENCLAW_ACP_URL DIREXTALK_OPENCLAW_ACP_TOKEN_FILE DIREXTALK_OPENCLAW_ACP_SESSION

  set +e
  run_phase > "$case_dir/stdout.log" 2> "$case_dir/stderr.log"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    echo "$name: run_phase must return non-zero" >&2
    return 1
  fi
  grep -q '^S6_WIRE_LOCAL|failed|' "$PHASE_CALLS" || {
    echo "$name: run_phase must mark S6 failed" >&2
    return 1
  }
  if grep -q '^S6_WIRE_LOCAL|done|' "$PHASE_CALLS"; then
    echo "$name: failed S6 must not subsequently be marked done" >&2
    return 1
  fi
}

for failure_case in invalid_runtime invalid_agent invalid_options invalid_policy invalid_mode host_openclaw_override host_hermes_override mcp_enrollment artifact_path_directory connect_config_path_directory; do
  run_failure_case "$failure_case"
done

success_dir="$tmp/success"
mkdir -p "$success_dir"
PHASE_CALLS="$success_dir/phases.log"
STATE_CALLS="$success_dir/state.log"
STATE_JSON="$success_dir/state.json"
export PHASE_CALLS STATE_CALLS STATE_JSON
: > "$PHASE_CALLS"
: > "$STATE_CALLS"
json_build object \
  agent_env_file=/legacy/service/env \
  mcp_json_config=/legacy/service/mcp/mcp-servers.json \
  mcp_codex_config=/legacy/service/mcp/codex.toml \
  mcp_cursor_config=/legacy/service/mcp/cursor.mcp.json \
  mcp_env_file=/canonical/mcp/env \
  mcp_daemon_install_command=legacy-command > "$STATE_JSON"
unset -f _maybe_auto_install_mcp 2>/dev/null || true
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/mcp-client-adapters.sh"
DIREXTALK_HOME="$tmp/dirextalk"
export DIREXTALK_HOME
dirextalk_test_assert_isolated_homes "$tmp"
export DIREXTALK_AGENT_PLATFORM=codex
unset DIREXTALK_CONNECT_AGENT DIREXTALK_CONNECT_AGENT_OPTIONS_TOML
export DIREXTALK_AGENT_INSTALL=skip
export DIREXTALK_AGENT_INSTALL_MODE=recommended

service_dir="$DIREXTALK_HOME/nodes/service.example.test"
mkdir -p "$service_dir"
printf 'legacy service env\n' > "$service_dir/env"
run_phase > "$success_dir/stdout.log" 2> "$success_dir/stderr.log"
grep -q '^S6_WIRE_LOCAL|done|' "$PHASE_CALLS"
[ ! -e "$service_dir/env" ] || {
  echo "S6 must remove the legacy service env artifact" >&2
  exit 1
}
[ -s "$service_dir/mcp/env" ] || {
  echo "S6 must retain the canonical MCP env artifact" >&2
  exit 1
}
if grep -q '^agent_env_file=' "$STATE_CALLS"; then
  echo "S6 must not write the legacy agent_env_file state field" >&2
  exit 1
fi
grep -q '^mcp_env_file=' "$STATE_CALLS"
grep -q '^mcp_capability=session$' "$STATE_CALLS"
json_test_check "$STATE_JSON" "!('agent_env_file' in data) && !('mcp_json_config' in data) && !('mcp_codex_config' in data) && !('mcp_cursor_config' in data) && !('mcp_daemon_install_command' in data) && data.mcp_env_file === '/canonical/mcp/env'"

run_capability_case() {
  local name=$1 runtime=$2 agent=$3 expected_capability=$4 expect_connect_mcp=$5 expected_result=${6:-done}
  local case_dir="$tmp/capability-$name" config_path rc
  mkdir -p "$case_dir"
  DIREXTALK_HOME="$case_dir/dirextalk"
  PHASE_CALLS="$case_dir/phases.log"
  STATE_CALLS="$case_dir/state.log"
  STATE_JSON="$case_dir/state.json"
  export DIREXTALK_HOME PHASE_CALLS STATE_CALLS STATE_JSON
  dirextalk_test_assert_isolated_homes "$tmp"
  : > "$PHASE_CALLS"
  : > "$STATE_CALLS"
  json_build object > "$STATE_JSON"

  export DIREXTALK_AGENT_PLATFORM="$runtime"
  if [ -n "$agent" ]; then
    export DIREXTALK_CONNECT_AGENT="$agent"
  else
    unset DIREXTALK_CONNECT_AGENT
  fi
  unset DIREXTALK_CONNECT_AGENT_OPTIONS_TOML
  unset DIREXTALK_OPENCLAW_ACP_URL DIREXTALK_OPENCLAW_ACP_TOKEN_FILE DIREXTALK_OPENCLAW_ACP_SESSION
  unset DIREXTALK_MCP_HOST_READY
  export DIREXTALK_AGENT_INSTALL=skip
  export DIREXTALK_AGENT_INSTALL_MODE=recommended

  set +e
  run_phase > "$case_dir/stdout.log" 2> "$case_dir/stderr.log"
  rc=$?
  set -e
  if [ "$expected_result" = "done" ]; then
    [ "$rc" -eq 0 ] || {
      echo "$name: expected run_phase success, got rc=$rc" >&2
      return 1
    }
    grep -q '^S6_WIRE_LOCAL|done|' "$PHASE_CALLS"
  else
    [ "$rc" -ne 0 ] || {
      echo "$name: conditional/unsupported capability must fail closed" >&2
      return 1
    }
    grep -q '^S6_WIRE_LOCAL|failed|' "$PHASE_CALLS"
    grep -q "^mcp_install_status=$expected_capability$" "$STATE_CALLS"
  fi
  grep -q "^mcp_capability=$expected_capability$" "$STATE_CALLS"
  grep -q "^connect_mcp_capability=$expected_capability$" "$STATE_CALLS"

  config_path="$DIREXTALK_HOME/nodes/service.example.test/dirextalk-connect/config.toml"
  if [ "$runtime" = "openclaw" ]; then
    grep -q "^Effective connect-agent MCP capability: $expected_capability$" "$DIREXTALK_HOME/nodes/service.example.test/mcp/openclaw.md"
  fi
  if [ "$runtime" = "hermes" ]; then
    grep -q '^mcp_hermes_home=.*/nodes/service.example.test/hermes$' "$STATE_CALLS"
    grep -q '^mcp_hermes_profile=dirextalk-service_example_test$' "$STATE_CALLS"
    grep -q 'args = \["hermes-acp-adapter", "--", "hermes", "-p", "dirextalk-service_example_test", "acp"\]' "$config_path"
    grep -q 'env = { HERMES_HOME = ".*/nodes/service.example.test/hermes" }' "$config_path"
  fi
  if [ "$expect_connect_mcp" = "true" ]; then
    grep -q '^mcp_url = "https://service.example.test/mcp"' "$config_path"
    grep -q "^mcp_capability = \"$expected_capability\"" "$config_path"
  else
    if grep -q '^mcp_url = \|^mcp_agent_token = \|^mcp_capability = ' "$config_path"; then
      echo "$name: host-managed connect config must not enable canonical MCP" >&2
      return 1
    fi
  fi
}

run_capability_case openclaw-acp openclaw "" host-managed false
run_capability_case hermes-acp hermes "" host-managed false
run_capability_case codex-iflow codex iflow host-managed false
run_capability_case iflow-default iflow "" host-managed false
run_capability_case codex-antigravity codex antigravity host-managed false
run_capability_case codex-cursor codex cursor host-managed false
run_capability_case codex-pi codex pi unsupported true failed
run_capability_case codex-tmux codex tmux unsupported true failed
run_capability_case codex-reasonix codex reasonix unsupported true failed

run_host_managed_auto_case() {
  local ready=$1 probe_exit=$2 expected_phase=$3 expected_status=$4 case_dir="$tmp/host-managed-auto-$1-$2" rc
  mkdir -p "$case_dir"
  DIREXTALK_HOME="$case_dir/dirextalk"
  PHASE_CALLS="$case_dir/phases.log"
  STATE_CALLS="$case_dir/state.log"
  STATE_JSON="$case_dir/state.json"
  CONNECT_START_CALLS="$case_dir/connect-start.log"
  OPENCLAW_PROBE_CALLS="$case_dir/openclaw-probe.log"
  export DIREXTALK_HOME PHASE_CALLS STATE_CALLS STATE_JSON CONNECT_START_CALLS OPENCLAW_PROBE_CALLS
  dirextalk_test_assert_isolated_homes "$tmp"
  : > "$PHASE_CALLS"
  : > "$STATE_CALLS"
  : > "$CONNECT_START_CALLS"
  : > "$OPENCLAW_PROBE_CALLS"
  json_build object > "$STATE_JSON"
  mkdir -p "$case_dir/bin"
  cat > "$case_dir/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$OPENCLAW_PROBE_CALLS"
exit "${OPENCLAW_PROBE_EXIT:-0}"
EOF
  chmod 700 "$case_dir/bin/openclaw"

  export DIREXTALK_AGENT_PLATFORM=openclaw
  unset DIREXTALK_CONNECT_AGENT DIREXTALK_CONNECT_AGENT_OPTIONS_TOML
  unset DIREXTALK_OPENCLAW_ACP_URL DIREXTALK_OPENCLAW_ACP_TOKEN_FILE DIREXTALK_OPENCLAW_ACP_SESSION
  export DIREXTALK_AGENT_INSTALL=auto
  export DIREXTALK_AGENT_INSTALL_MODE=recommended
  export DIREXTALK_OPENCLAW_COMMAND="$case_dir/bin/openclaw"
  export OPENCLAW_PROBE_EXIT="$probe_exit"
  if [ "$ready" = "1" ]; then
    export DIREXTALK_MCP_HOST_READY=1
  else
    unset DIREXTALK_MCP_HOST_READY
  fi
  _maybe_auto_install_agent() {
    printf 'started\n' >> "$CONNECT_START_CALLS"
  }

  set +e
  run_phase > "$case_dir/stdout.log" 2> "$case_dir/stderr.log"
  rc=$?
  set -e

  grep -q "^S6_WIRE_LOCAL|$expected_phase|" "$PHASE_CALLS"
  grep -q "^mcp_install_status=$expected_status$" "$STATE_CALLS"
  [ -s "$DIREXTALK_HOME/nodes/service.example.test/mcp/openclaw.md" ]
  if grep -q '^mcp_url = \|^mcp_agent_token = \|^mcp_capability = ' "$DIREXTALK_HOME/nodes/service.example.test/dirextalk-connect/config.toml"; then
    echo "host-managed auto case must not enable canonical MCP in connect options" >&2
    return 1
  fi
  if [ "$expected_phase" = "done" ]; then
    [ "$rc" -eq 0 ]
    grep -q '^started$' "$CONNECT_START_CALLS"
  else
    [ "$rc" -eq 2 ]
    [ ! -s "$CONNECT_START_CALLS" ] || {
      echo "host-managed bridge must not start before explicit host enrollment confirmation" >&2
      return 1
    }
  fi
  if [ "$ready" = "1" ]; then
    [ "$(sed -n '1p' "$OPENCLAW_PROBE_CALLS")" = "mcp" ]
    [ "$(sed -n '2p' "$OPENCLAW_PROBE_CALLS")" = "probe" ]
    [ "$(sed -n '3p' "$OPENCLAW_PROBE_CALLS")" = "dirextalk-service_example_test" ]
    [ "$(sed -n '4p' "$OPENCLAW_PROBE_CALLS")" = "--json" ]
    [ "$(wc -l < "$OPENCLAW_PROBE_CALLS" | tr -d ' ')" = "4" ]
    ! grep -q 'agent-token\|Authorization\|Bearer' "$OPENCLAW_PROBE_CALLS"
  else
    [ ! -s "$OPENCLAW_PROBE_CALLS" ]
  fi
}

run_host_managed_auto_case 0 0 waiting_user host_action_required
run_host_managed_auto_case 1 0 done host_probe_passed
run_host_managed_auto_case 1 1 waiting_user host_probe_failed

find "$tmp" -type f -print | while IFS= read -r written; do
  case "$written" in
    "$tmp"/*) ;;
    *) echo "test write escaped temporary root: $written" >&2; exit 1 ;;
  esac
done

echo "s6 run_phase failure propagation ok"
