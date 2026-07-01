#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$HOME"

# shellcheck disable=SC1090
source "$ROOT/scripts/phases/s6_wire_local.sh"

ok() { echo "[test-ok] $*" >&2; }
warn() { echo "[test-warn] $*" >&2; }
fail() { echo "$*" >&2; return 1; }
state_set() { printf '%s=%s\n' "$1" "$2" >> "${STATE_CALLS:?}"; }

clear_runtime_env() {
  local env_name
  while IFS='=' read -r env_name _; do
    case "$env_name" in
      ACP_*|ANTIGRAVITY_*|GOOGLE_ANTIGRAVITY_*|AGY_*|CODEX_*|CLAUDECODE|CLAUDECODE_*|CLAUDE_CODE_*|GEMINI_CLI|GEMINI_CLI_*|GEMINI_AGENT_*|GOOGLE_GEMINI_CLI_*|CURSOR_*|COPILOT_*|GITHUB_COPILOT_*|DEVIN_*|IFLOW_*|KIMI_*|OPENCODE_*|OPEN_CODE_*|PI_CODING_AGENT_*|PI_AGENT_*|QODER_*|REASONIX_*|TMUX*|OPENCLAW_*|HERMES_*)
        unset "$env_name"
        ;;
    esac
  done < <(env)
  unset ACP_HOME ANTIGRAVITY_HOME AGY_HOME HERMES_HOME CODEX_HOME CLAUDE_HOME CLAUDECODE_HOME GEMINI_HOME CURSOR_HOME COPILOT_HOME DEVIN_HOME IFLOW_HOME KIMI_HOME OPENCODE_HOME OPEN_CODE_HOME PI_CODING_AGENT_DIR PI_HOME QODER_HOME REASONIX_HOME TMUX_HOME OPENCLAW_HOME
  unset HERMES_SESSION CODEX_SANDBOX CLAUDECODE GEMINI_CLI CURSOR_TRACE_ID GITHUB_COPILOT_TOKEN DEVIN_SESSION IFLOW_SESSION KIMI_SESSION OPENCODE_SESSION QODER_SESSION PI_AGENT_SESSION ANTIGRAVITY_SESSION OPENCLAW_SESSION
  unset DIREXIO_CONNECT_AGENT DIREXIO_CONNECT_AGENT_CMD
}

clear_speech_env() {
  local env_name
  while IFS='=' read -r env_name _; do
    case "$env_name" in
      DIREXIO_SPEECH_*|OPENAI_API_KEY|OPENAI_BASE_URL|GROQ_API_KEY|DASHSCOPE_API_KEY|DASH_SCOPE_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY)
        unset "$env_name"
        ;;
    esac
  done < <(env)
}

clear_runtime_env
clear_speech_env
export DIREXIO_AGENT_DETECT_PROCESS=0

unset DIREXIO_HOME
[ "$(_direxio_home)" = "$HOME/.direxio" ]
[ "$(DIREXIO_HOME="$tmp/custom-direxio" _direxio_home)" = "$tmp/custom-direxio" ]
[ "$(_direxio_service_id "https://Service.Example.test:8443/_p2p")" = "service.example.test-8443" ]
[ "$(_direxio_service_dir "https://Service.Example.test:8443/_p2p")" = "$HOME/.direxio/nodes/service.example.test-8443" ]

envfile=$(_write_agent_env_file "https://service.example.test" "agent-token" "access-token" "!agents-real:service.example.test")

[ "$envfile" = "$HOME/.direxio/env" ]
grep -q 'DIREXIO_DOMAIN=https://service.example.test' "$envfile"
grep -q 'DIREXIO_AGENT_TOKEN=agent-token' "$envfile"
grep -q 'DIREXIO_AGENT_ROOM_ID=\\!agents-real:service.example.test' "$envfile"
! grep -q '^export P2P_' "$envfile"
! grep -q 'P2P_ADMIN_ACCESS_TOKEN' "$envfile"
! grep -q 'P2P_MATRIX_ACCESS_TOKEN' "$envfile"

# shellcheck disable=SC1090
source "$envfile"
[ "$DIREXIO_AGENT_ROOM_ID" = "!agents-real:service.example.test" ]

legacy_p2p_agent_pattern='P2P_MATRIX_AS_URL\|P2P_MATRIX_AGENT_TOKEN\|P2P_AGENT_RUNTIME\|p2p-agent-skill\|p2p-''matrix-agent'
if grep -R "$legacy_p2p_agent_pattern" "$ROOT/scripts" "$ROOT/SKILL.md" "$ROOT/references/runtime-wiring.md"; then
  echo "deprecated Matrix-AS env names or old agent skill wiring must not be used by deployer wiring" >&2
  exit 1
fi

[ "$(DIREXIO_AGENT_PLATFORM=hermes _detect_agent_runtime)" = "hermes" ]
[ "$(DIREXIO_AGENT_PLATFORM=openclaw _detect_agent_runtime)" = "openclaw" ]
[ "$(DIREXIO_AGENT_PLATFORM=claude-code _detect_agent_runtime)" = "claude-code" ]
[ "$(DIREXIO_AGENT_PLATFORM=opencode _detect_agent_runtime)" = "opencode" ]
[ "$(DIREXIO_CONNECT_AGENT=qodercli _detect_agent_runtime)" = "qoder" ]
[ "$(DIREXIO_AGENT_PLATFORM=hermes DIREXIO_CONNECT_AGENT=codex _detect_agent_runtime)" = "hermes" ]
assert_active_runtime() {
  local expected=$1 signal=$2
  shift 2
  (
    clear_runtime_env
    mkdir -p "$HOME/.hermes" "$HOME/.codex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.cursor" "$HOME/.copilot" "$HOME/.devin" "$HOME/.iflow" "$HOME/.kimi" "$HOME/.opencode" "$HOME/.qoder" "$HOME/.pi/agent" "$HOME/.antigravity" "$HOME/.openclaw" "$tmp/neutral"
    cd "$tmp/neutral"
    PATH="/usr/bin:/bin"
    local kv
    for kv in "$@"; do
      export "$kv"
    done
    actual=$(_detect_agent_runtime)
    if [ "$actual" != "$expected" ]; then
      echo "expected active $expected runtime from $signal, got $actual" >&2
      exit 1
    fi
  )
}

assert_active_runtime codex CODEX_SANDBOX CODEX_SANDBOX=1
assert_active_runtime claudecode CLAUDECODE CLAUDECODE=1
assert_active_runtime gemini GEMINI_CLI GEMINI_CLI=1
assert_active_runtime cursor CURSOR_TRACE_ID CURSOR_TRACE_ID=1
assert_active_runtime copilot GITHUB_COPILOT_TOKEN GITHUB_COPILOT_TOKEN=1
assert_active_runtime devin DEVIN_SESSION DEVIN_SESSION=1
assert_active_runtime iflow IFLOW_SESSION IFLOW_SESSION=1
assert_active_runtime kimi KIMI_SESSION KIMI_SESSION=1
assert_active_runtime opencode OPENCODE_SESSION OPENCODE_SESSION=1
assert_active_runtime qoder QODER_SESSION QODER_SESSION=1
assert_active_runtime pi PI_AGENT_SESSION PI_AGENT_SESSION=1
assert_active_runtime antigravity ANTIGRAVITY_SESSION ANTIGRAVITY_SESSION=1
assert_active_runtime openclaw OPENCLAW_SESSION OPENCLAW_SESSION=1
assert_active_runtime hermes HERMES_SESSION HERMES_SESSION=1
assert_active_runtime codex .codex/tmp PATH="/tmp/.codex/tmp/codex-arg123:/usr/bin:/bin"
(
  clear_runtime_env
  mkdir -p "$HOME/.hermes" "$HOME/.codex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.cursor" "$HOME/.copilot" "$HOME/.openclaw" "$tmp/neutral"
  cd "$tmp/neutral"
  PATH="/usr/bin:/bin"
  export CLAUDE_API_KEY=test GEMINI_API_KEY=test
  [ "$(_detect_agent_runtime)" = "unknown" ]
)
[ "$(DIREXIO_AGENT_INSTALL=skip _connect_install_policy)" = "skip" ]
[ "$(DIREXIO_AGENT_INSTALL=recommend _connect_install_policy)" = "recommend" ]
[ "$(DIREXIO_AGENT_INSTALL=auto _connect_install_policy)" = "auto" ]
[ "$(_connect_install_policy)" = "auto" ]
[ "$(_connect_install_mode hermes)" = "direxio-connect" ]
[ "$(_connect_install_mode openclaw)" = "direxio-connect" ]
[ "$(_connect_install_mode codex)" = "direxio-connect" ]
[ "$(_connect_install_mode cursor)" = "direxio-connect" ]
[ "$(_connect_install_mode opencode)" = "direxio-connect" ]
[ "$(DIREXIO_AGENT_INSTALL_MODE=direxio-connect _connect_install_mode hermes)" = "direxio-connect" ]
if DIREXIO_AGENT_INSTALL_MODE=gateway _connect_install_mode hermes >/dev/null 2>&1; then
  echo "legacy install mode should be rejected" >&2
  exit 1
fi

matrix_retry_dir="$tmp/matrix-retry"
mkdir -p "$matrix_retry_dir/bin"
cat > "$matrix_retry_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file=${MATRIX_RETRY_COUNT:?}
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
out=
auth=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H) [ "${2:-}" = "Authorization: Bearer agent-token" ] && auth=agent-token; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 2
[ "$auth" = "agent-token" ] || exit 3
if [ "$count" -eq 1 ]; then
  printf 'transient network failure' > "$out"
  printf '000'
elif [ "$count" -lt "${MATRIX_SUCCESS_AFTER:-2}" ]; then
  printf 'action not ready' > "$out"
  printf '404'
else
  printf '{"access_token":"matrix-token","device_id":"DEVICE","user_id":"@agent:service.example.test","homeserver":"https://service.example.test"}' > "$out"
  printf '200'
fi
EOF
chmod 700 "$matrix_retry_dir/bin/curl"
MATRIX_RETRY_COUNT="$matrix_retry_dir/count" \
DIREXIO_MATRIX_SESSION_CREATE_MAX=2 \
DIREXIO_MATRIX_SESSION_RETRY_INTERVAL=0 \
PATH="$matrix_retry_dir/bin:$PATH" \
  _create_connect_matrix_session "https://service.example.test" "agent-token" "DEVICE" "$matrix_retry_dir/session.json"
[ "$(cat "$matrix_retry_dir/count")" = "2" ]
json_test_check "$matrix_retry_dir/session.json" "data.user_id === '@agent:service.example.test' && data.access_token === 'matrix-token'"

rm -f "$matrix_retry_dir/count" "$matrix_retry_dir/session.json"
MATRIX_RETRY_COUNT="$matrix_retry_dir/count" \
MATRIX_SUCCESS_AFTER=6 \
DIREXIO_MATRIX_SESSION_RETRY_INTERVAL=0 \
PATH="$matrix_retry_dir/bin:$PATH" \
  _create_connect_matrix_session "https://service.example.test" "agent-token" "DEVICE" "$matrix_retry_dir/session.json"
[ "$(cat "$matrix_retry_dir/count")" = "6" ]
json_test_check "$matrix_retry_dir/session.json" "data.user_id === '@agent:service.example.test' && data.access_token === 'matrix-token'"

[ "$(_agent_skill_install_path codex)" = "PROJECT_ROOT/.codex/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path claude-code)" = "PROJECT_ROOT/.claude/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path claudecode)" = "PROJECT_ROOT/.claude/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path gemini)" = "PROJECT_ROOT/.gemini/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path cursor)" = "PROJECT_ROOT/.cursor/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path copilot)" = "PROJECT_ROOT/.github/copilot/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path devin)" = "PROJECT_ROOT/.devin/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path opencode)" = "PROJECT_ROOT/.opencode/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path qoder)" = "PROJECT_ROOT/.qoder/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path pi)" = "PROJECT_ROOT/.pi/agent/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path openclaw)" = "PROJECT_ROOT/.openclaw/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path hermes)" = "PROJECT_ROOT/.hermes/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path unknown)" = "PROJECT_ROOT/.agent/skills/direxio-deployer" ]

[ "$(_agent_global_skill_install_path codex)" = '${CODEX_HOME:-$HOME/.codex}/skills/direxio-deployer' ]
[ "$(_agent_global_skill_install_path claude-code)" = '${CLAUDE_HOME:-${CLAUDECODE_HOME:-$HOME/.claude}}/skills/direxio-deployer' ]
[ "$(_agent_global_skill_install_path claudecode)" = '${CLAUDE_HOME:-${CLAUDECODE_HOME:-$HOME/.claude}}/skills/direxio-deployer' ]
[ "$(_agent_global_skill_install_path generic)" = '$HOME/.agent/skills/direxio-deployer' ]
[ "$(_agent_workspace "$tmp/service")" = "$tmp/service/workspace" ]
[ "$(DIREXIO_AGENT_WORKSPACE="$tmp/custom-workspace" _agent_workspace "$tmp/service")" = "$tmp/custom-workspace" ]

install_command=$(_connect_install_command "direxio-connect" "$HOME/.direxio/nodes/service.example.test/direxio-connect/config.toml" "service.example.test")
case "$install_command" in
  *"npm install -g"*"direxio-connent@latest"*"direxio-connect"*"daemon install"*"--config"*"service.example.test/direxio-connect/config.toml"*"--service-name"*"service.example.test"*"--force"*) ;;
  *)
    echo "install command did not include expected direxio-connect daemon flags: $install_command" >&2
    exit 1
    ;;
esac
custom_install_command=$(DIREXIO_CONNECT_NPM_PACKAGE='direxio-connent@override-test' _connect_install_command "direxio-connect" "$HOME/.direxio/nodes/service.example.test/direxio-connect/config.toml" "service.example.test")
[[ "$custom_install_command" == *"direxio-connent@override-test"* ]]

[ "$(DIREXIO_LOCAL_PATH_STYLE=windows _local_connect_path '/mnt/c/Users/alice/.direxio/nodes/im/direxio-connect/config.toml')" = "C:/Users/alice/.direxio/nodes/im/direxio-connect/config.toml" ]
[ "$(DIREXIO_LOCAL_PATH_STYLE=windows _local_connect_path '/c/Users/alice/.direxio/nodes/im/direxio-connect/config.toml')" = "C:/Users/alice/.direxio/nodes/im/direxio-connect/config.toml" ]
windows_install_command=$(DIREXIO_LOCAL_PATH_STYLE=windows _connect_install_command "direxio-connect" "/mnt/c/Users/alice/.direxio/nodes/im/direxio-connect/config.toml" "im")
[[ "$windows_install_command" == *"C:/Users/alice/.direxio/nodes/im/direxio-connect/config.toml"* ]]
[[ "$windows_install_command" == *"--service-name im"* ]]

[ "$(_mcp_server_name "service.example.test")" = "direxio-service_example_test" ]
[ "$(_mcp_server_name "T1.Direxio.AI")" = "direxio-t1_direxio_ai" ]

mcp_service_dir="$tmp/mcp-service"
mcp_credentials="$mcp_service_dir/credentials.json"
mkdir -p "$mcp_service_dir"
: > "$mcp_credentials"
mkdir -p "$mcp_service_dir/mcp"
: > "$mcp_service_dir/mcp/openclaw.mcp.json"
expected_mcp_credentials="$mcp_credentials"
if command -v cygpath >/dev/null 2>&1; then
  expected_mcp_credentials=$(cygpath -m "$expected_mcp_credentials")
fi
_write_mcp_config_artifacts "service.example.test" "$mcp_service_dir" "$mcp_credentials" "codex-service-example"
[ -s "$mcp_service_dir/mcp/codex.toml" ]
[ -s "$mcp_service_dir/mcp/openclaw.md" ]
[ -s "$mcp_service_dir/mcp/openclaw-server.json" ]
[ ! -e "$mcp_service_dir/mcp/openclaw.mcp.json" ]
[ -s "$mcp_service_dir/mcp/hermes.mcp.json" ]
[ -s "$mcp_service_dir/mcp/mcp-servers.json" ]
[ -s "$mcp_service_dir/mcp/env" ]
grep -q '\[mcp_servers."direxio-service_example_test"\]' "$mcp_service_dir/mcp/codex.toml"
grep -q 'command = "direxio-mcp"' "$mcp_service_dir/mcp/codex.toml"
grep -q 'DIREXIO_CREDENTIALS_FILE' "$mcp_service_dir/mcp/codex.toml"
grep -q "$mcp_credentials" "$mcp_service_dir/mcp/codex.toml"
json_test_check "$mcp_service_dir/mcp/openclaw-server.json" "data.command === 'direxio-mcp'"
json_test_check "$mcp_service_dir/mcp/openclaw-server.json" "data.env.DIREXIO_CREDENTIALS_FILE === '$expected_mcp_credentials'"
if json_check "$mcp_service_dir/mcp/openclaw-server.json" "'mcp' in data || 'mcpServers' in data" >/dev/null; then
  echo "OpenClaw server object must not be a root openclaw.json or mcpServers snippet" >&2
  exit 1
fi
grep -q 'openclaw mcp set direxio-service_example_test' "$mcp_service_dir/mcp/openclaw.md"
grep -q 'Do not paste' "$mcp_service_dir/mcp/openclaw.md"
grep -q 'openclaw.json' "$mcp_service_dir/mcp/openclaw.md"
json_test_check "$mcp_service_dir/mcp/hermes.mcp.json" "data.mcpServers['direxio-service_example_test'].env.DIREXIO_CREDENTIALS_FILE === '$expected_mcp_credentials'"
grep -q 'DIREXIO_AGENT_NODE_ID=codex-service-example' "$mcp_service_dir/mcp/env"
mcp_install_command=$(_mcp_install_command)
[[ "$mcp_install_command" == *"npm install -g"*"direxio-mcp@latest"* ]]
custom_mcp_install_command=$(DIREXIO_MCP_NPM_PACKAGE='direxio-mcp@override-test' _mcp_install_command)
[[ "$custom_mcp_install_command" == *"direxio-mcp@override-test"* ]]
mcp_doctor_command=$(_mcp_doctor_command "$mcp_credentials" "codex-service-example")
[[ "$mcp_doctor_command" == *"DIREXIO_CREDENTIALS_FILE="* ]]
[[ "$mcp_doctor_command" == *"direxio-mcp doctor --json"* ]]

stale_node_id=$(DIREXIO_AGENT_NODE_ID=codex-old.example.test _agent_node_id codex new.example.test '!agents-real:new.example.test')
[[ "$stale_node_id" == codex-new.example.test-* ]]

matching_node_id=$(DIREXIO_AGENT_NODE_ID=codex-new.example.test-123 _agent_node_id codex new.example.test '!agents-real:new.example.test')
[ "$matching_node_id" = "codex-new.example.test-123" ]

config_path="$tmp/direxio-connect/config.toml"
_write_connect_config "$config_path" "$tmp/direxio-connect/data" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test"
grep -q 'type = "matrix"' "$config_path"
grep -q 'type = "codex"' "$config_path"
grep -q 'admin_from = "@owner:service.example.test"' "$config_path"
awk '/^\[projects.agent.options\]/{in_options=1} /^admin_from = / && in_options{exit 1}' "$config_path"
grep -q 'backend = "app_server"' "$config_path"
grep -q 'app_server_url = "stdio"' "$config_path"
grep -q 'mode = "yolo"' "$config_path"
grep -q 'room_id = "!agents-real:service.example.test"' "$config_path"
grep -q 'user_id = "@agent:service.example.test"' "$config_path"
grep -q 'share_session_in_channel = true' "$config_path"
grep -q 'group_reply_all = true' "$config_path"
grep -q 'auto_join = false' "$config_path"
! grep -q '^\[speech\]' "$config_path"
! grep -q 'DIREXIO_CREDENTIALS_FILE' "$config_path"

speech_config_path="$tmp/direxio-connect/config-with-speech.toml"
DIREXIO_SPEECH_API_KEY=speech-key \
DIREXIO_SPEECH_BASE_URL=https://stt.example.test/v1 \
DIREXIO_SPEECH_MODEL=whisper-test \
  _write_connect_config "$speech_config_path" "$tmp/direxio-connect/data-speech" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test"
grep -q '^\[speech\]$' "$speech_config_path"
grep -q 'enabled = true' "$speech_config_path"
grep -q 'provider = "openai"' "$speech_config_path"
grep -q 'language = "zh"' "$speech_config_path"
grep -q '^\[speech.openai\]$' "$speech_config_path"
grep -q 'api_key = "speech-key"' "$speech_config_path"
grep -q 'base_url = "https://stt.example.test/v1"' "$speech_config_path"
grep -q 'model = "whisper-test"' "$speech_config_path"

[ "$(_connect_agent_type codex)" = "codex" ]
[ "$(_connect_agent_type claude-code)" = "claudecode" ]
[ "$(_connect_agent_type claudecode)" = "claudecode" ]
[ "$(_connect_agent_type opencode)" = "opencode" ]
[ "$(_connect_agent_type qodercli)" = "qoder" ]
[ "$(_connect_agent_type antigravity)" = "antigravity" ]
[ "$(_connect_agent_type openclaw)" = "acp" ]
[ "$(_connect_agent_type hermes)" = "acp" ]
[ "$(DIREXIO_CONNECT_AGENT=gemini _connect_agent_type unknown)" = "gemini" ]
[ "$(DIREXIO_CONNECT_AGENT=codex _connect_agent_type hermes)" = "codex" ]
[ "$(DIREXIO_CODEX_COMMAND=/opt/codex/bin/codex _connect_agent_command codex)" = "/opt/codex/bin/codex" ]
[ "$(DIREXIO_GEMINI_COMMAND=/opt/gemini/bin/gemini _connect_agent_command gemini)" = "/opt/gemini/bin/gemini" ]
[ "$(DIREXIO_CLAUDE_CODE_COMMAND=/opt/claude/bin/claude _connect_agent_command claudecode)" = "/opt/claude/bin/claude" ]
[ "$(DIREXIO_QODERCLI_COMMAND=/opt/qoder/qodercli _connect_agent_command qoder)" = "/opt/qoder/qodercli" ]
[ "$(DIREXIO_CONNECT_AGENT_CMD=/custom/agent _connect_agent_command codex)" = "/custom/agent" ]
[ "$(_connect_agent_command acp openclaw)" = "openclaw" ]
[ "$(_connect_agent_command acp hermes)" = "direxio-connect" ]
[ "$(DIREXIO_OPENCLAW_COMMAND=/opt/openclaw/bin/openclaw _connect_agent_command acp openclaw)" = "/opt/openclaw/bin/openclaw" ]
[ "$(DIREXIO_HERMES_COMMAND=/opt/hermes/bin/hermes _connect_agent_command acp hermes)" = "direxio-connect" ]

cmd_config_path="$tmp/direxio-connect/config-with-cmd.toml"
_write_connect_config "$cmd_config_path" "$tmp/direxio-connect/data-cmd" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "/opt/codex/bin/codex"
grep -q 'cmd = "/opt/codex/bin/codex"' "$cmd_config_path"

options_config_path="$tmp/direxio-connect/config-with-extra-options.toml"
_write_connect_config "$options_config_path" "$tmp/direxio-connect/data-options" "reasonix-node" "reasonix" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "" 'serve_url = "http://127.0.0.1:8080"'
grep -q 'type = "reasonix"' "$options_config_path"
grep -q 'serve_url = "http://127.0.0.1:8080"' "$options_config_path"
! grep -q 'backend = "app_server"' "$options_config_path"

codex_options_config_path="$tmp/direxio-connect/config-with-codex-extra-options.toml"
_write_connect_config "$codex_options_config_path" "$tmp/direxio-connect/data-codex-options" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "" $'mode = "full-auto"\nmodel = "gpt-5.5"'
grep -q 'backend = "app_server"' "$codex_options_config_path"
grep -q 'app_server_url = "stdio"' "$codex_options_config_path"
grep -q 'mode = "full-auto"' "$codex_options_config_path"
[ "$(grep -c '^[[:space:]]*mode[[:space:]]*=' "$codex_options_config_path")" = "1" ]
grep -q 'model = "gpt-5.5"' "$codex_options_config_path"

fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$fakebin/direxio-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "install" ]; then
  [ "${5:-}" = "--service-name" ]
  [ "${6:-}" = "service.example.test" ]
  exit 0
fi
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "status" ]; then
  [ "${3:-}" = "--service-name" ]
  [ "${4:-}" = "service.example.test" ]
  cat <<STATUS
direxio-connect daemon status

  Status:    Stopped
  Platform:  launchd
  WorkDir:   /tmp/direxio-test/direxio-connect
STATUS
  exit 0
fi
exit 1
EOF
chmod 700 "$fakebin/npm" "$fakebin/direxio-connect"
STATE_CALLS="$tmp/state.calls"
: > "$STATE_CALLS"
PATH="$fakebin:$PATH" _maybe_auto_install_connect auto codex codex "$tmp/service" "$tmp/service/direxio-connect/config.toml" direxio-connect service.example.test
grep -q '^connect_install_status=install_failed$' "$STATE_CALLS"

STATE_CALLS="$tmp/mcp-state.calls"
: > "$STATE_CALLS"
PATH="$fakebin:$PATH" _maybe_auto_install_mcp auto
grep -q '^mcp_install_status=installed$' "$STATE_CALLS"

STATE_CALLS="$tmp/mcp-recommend-state.calls"
: > "$STATE_CALLS"
PATH="$fakebin:$PATH" _maybe_auto_install_mcp recommend
grep -q '^mcp_install_status=recommend$' "$STATE_CALLS"

# When explicit Gateway settings are not set, OpenClaw ACP should auto-discover
# the Gateway from ~/.openclaw/openclaw.json.
openclaw_fallback_options=$(_connect_agent_options_toml openclaw acp 2> "$tmp/openclaw-fallback.err")
[[ "$openclaw_fallback_options" == *'args = ["acp", "--session", "agent:main:main"]'* ]]
grep -q 'auto-detect the Gateway' "$tmp/openclaw-fallback.err"

openclaw_session_fallback_options=$(DIREXIO_OPENCLAW_ACP_SESSION=agent:direxio:main _connect_agent_options_toml openclaw acp 2> "$tmp/openclaw-session-fallback.err")
[[ "$openclaw_session_fallback_options" == *'args = ["acp", "--session", "agent:direxio:main"]'* ]]

if DIREXIO_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 _connect_agent_options_toml openclaw acp > "$tmp/openclaw-partial.out" 2> "$tmp/openclaw-partial.err"; then
  echo "OpenClaw ACP explicit Gateway options must require URL, token file, and session together" >&2
  exit 1
fi
grep -q 'DIREXIO_OPENCLAW_ACP_TOKEN_FILE' "$tmp/openclaw-partial.err"
grep -q 'DIREXIO_OPENCLAW_ACP_SESSION' "$tmp/openclaw-partial.err"

openclaw_options=$(
  DIREXIO_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 \
  DIREXIO_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/gateway.token \
  DIREXIO_OPENCLAW_ACP_SESSION=agent:main:main \
  _connect_agent_options_toml openclaw acp
)
[[ "$openclaw_options" == *'args = ["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "/mnt/c/Users/alice/.openclaw/gateway.token", "--session", "agent:main:main"]'* ]]
[[ "$openclaw_options" == *'display_name = "OpenClaw ACP"'* ]]

openclaw_session_options=$(
  DIREXIO_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 \
  DIREXIO_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/gateway.token \
  DIREXIO_OPENCLAW_ACP_SESSION=agent:direxio:main \
  _connect_agent_options_toml openclaw acp
)
[[ "$openclaw_session_options" == *'--session", "agent:direxio:main"'* ]]

openclaw_url_options=$(DIREXIO_OPENCLAW_ACP_ARGS_TOML='["acp", "--url", "wss://gateway.example.test:18789", "--session", "agent:main:main"]' _connect_agent_options_toml openclaw acp)
[[ "$openclaw_url_options" == *'args = ["acp", "--url", "wss://gateway.example.test:18789", "--session", "agent:main:main"]'* ]]

openclaw_posix_token_options=$(DIREXIO_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 DIREXIO_LOCAL_PATH_STYLE=posix DIREXIO_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/token.json DIREXIO_OPENCLAW_ACP_SESSION=agent:main:main _connect_agent_options_toml openclaw acp)
[[ "$openclaw_posix_token_options" == *'args = ["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "/mnt/c/Users/alice/.openclaw/token.json", "--session", "agent:main:main"]'* ]]

openclaw_token_options=$(DIREXIO_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 DIREXIO_LOCAL_PATH_STYLE=windows DIREXIO_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/token.json DIREXIO_OPENCLAW_ACP_SESSION=agent:main:main _connect_agent_options_toml openclaw acp)
[[ "$openclaw_token_options" == *'args = ["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "C:/Users/alice/.openclaw/token.json", "--session", "agent:main:main"]'* ]]

hermes_options=$(_connect_agent_options_toml hermes acp)
[[ "$hermes_options" == *'args = ["hermes-acp-adapter", "--", "hermes", "acp"]'* ]]
[[ "$hermes_options" == *'display_name = "Hermes ACP"'* ]]

hermes_custom_command_options=$(DIREXIO_HERMES_COMMAND=/opt/hermes/bin/hermes _connect_agent_options_toml hermes acp)
[[ "$hermes_custom_command_options" == *'args = ["hermes-acp-adapter", "--", "/opt/hermes/bin/hermes", "acp"]'* ]]

hermes_custom_args_options=$(DIREXIO_HERMES_ACP_ARGS_TOML='["acp", "--profile", "direxio"]' _connect_agent_options_toml hermes acp)
[[ "$hermes_custom_args_options" == *'args = ["hermes-acp-adapter", "--", "hermes", "acp", "--profile", "direxio"]'* ]]

openclaw_config_path="$tmp/direxio-connect/config-openclaw.toml"
_write_connect_config "$openclaw_config_path" "$tmp/direxio-connect/data-openclaw" "openclaw-node" "$(_connect_agent_type openclaw)" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "$(_connect_agent_command acp openclaw)" "$openclaw_options"
grep -q 'type = "acp"' "$openclaw_config_path"
grep -q 'cmd = "openclaw"' "$openclaw_config_path"
grep -q 'args = \["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "/mnt/c/Users/alice/.openclaw/gateway.token", "--session", "agent:main:main"\]' "$openclaw_config_path"
grep -q 'display_name = "OpenClaw ACP"' "$openclaw_config_path"

hermes_config_path="$tmp/direxio-connect/config-hermes.toml"
_write_connect_config "$hermes_config_path" "$tmp/direxio-connect/data-hermes" "hermes-node" "$(_connect_agent_type hermes)" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "$(_connect_agent_command acp hermes)" "$(_connect_agent_options_toml hermes acp)"
grep -q 'type = "acp"' "$hermes_config_path"
grep -q 'cmd = "direxio-connect"' "$hermes_config_path"
grep -q 'args = \["hermes-acp-adapter", "--", "hermes", "acp"\]' "$hermes_config_path"
grep -q 'display_name = "Hermes ACP"' "$hermes_config_path"

guidance=$(
  _print_connect_guidance codex https://service.example.test "$HOME/.direxio/nodes/service.example.test/credentials.json" "$HOME/.direxio/nodes/service.example.test/env" recommend direxio-connect "install command" codex-service "$config_path" "$HOME/.direxio/nodes/service.example.test/direxio-connect/bin/direxio-connect" codex "/opt/codex/bin/codex" service.example.test 2>&1 >/dev/null
)
[[ "$guidance" == *"DIREXIO_DOMAIN"* ]]
[[ "$guidance" == *"DIREXIO_AGENT_TOKEN"* ]]
[[ "$guidance" == *"direxio-connect service"* ]]
[[ "$guidance" == *"DIREXIO_AGENT_ROOM_ID"* ]]
[[ "$guidance" == *"DIREXIO_AGENT_NODE_ID"* ]]
[[ "$guidance" == *"direxio-connect config"* ]]
[[ "$guidance" == *"/opt/codex/bin/codex"* ]]
[[ "$guidance" == *"daemon install"* ]]
[[ "$guidance" == *"direxio-connent@latest"* || "$install_command" == *"direxio-connent@latest"* ]]
[[ "$guidance" == *"type = \"matrix\""* || "$guidance" == *"direxio-connect will use Matrix"* ]]
bad_credentials_env_name="DIREXIO_CREDENTIALS""_FILE"
if [[ "$guidance" == *"$bad_credentials_env_name"* ]]; then
  echo "direxio-connect guidance must not use $bad_credentials_env_name; it writes direct Matrix config" >&2
  exit 1
fi

echo "s6 wire local ok"
