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

(
  unset -f json_build json_get json_assert json_valid json_type json_length json_stdin_get json_stdin_assert json_check 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$ROOT/scripts/phases/s6_wire_local.sh"
  declare -F json_build >/dev/null || {
    echo "s6_wire_local.sh must source JSON helpers for direct phase execution" >&2
    exit 1
  }
  json_build matrix-session-create DIRECT_DEVICE | grep -q 'agent.matrix_session.create'
)

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
  unset DIREXTALK_CONNECT_AGENT DIREXTALK_CONNECT_AGENT_CMD
}

clear_speech_env() {
  local env_name
  while IFS='=' read -r env_name _; do
    case "$env_name" in
      DIREXTALK_SPEECH_*|OPENAI_API_KEY|OPENAI_BASE_URL|GROQ_API_KEY|DASHSCOPE_API_KEY|DASH_SCOPE_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY)
        unset "$env_name"
        ;;
    esac
  done < <(env)
}

clear_runtime_env
clear_speech_env
export DIREXTALK_AGENT_DETECT_PROCESS=0
export DIREXTALK_LOCAL_PATH_STYLE=posix

unset DIREXTALK_HOME
[ "$(_dirextalk_home)" = "$HOME/.dirextalk" ]
[ "$(DIREXTALK_HOME="$tmp/custom-dirextalk" _dirextalk_home)" = "$tmp/custom-dirextalk" ]
[ "$(_dirextalk_service_id "https://Service.Example.test:8443/_p2p")" = "service.example.test-8443" ]
[ "$(_dirextalk_service_dir "https://Service.Example.test:8443/_p2p")" = "$HOME/.dirextalk/nodes/service.example.test-8443" ]

envfile=$(_write_agent_env_file "https://service.example.test" "agent-token" "access-token" "!agents-real:service.example.test")

[ "$envfile" = "$HOME/.dirextalk/env" ]
grep -q 'DIREXTALK_DOMAIN=https://service.example.test' "$envfile"
grep -q 'DIREXTALK_AGENT_TOKEN=agent-token' "$envfile"
grep -q 'DIREXTALK_AGENT_ROOM_ID=\\!agents-real:service.example.test' "$envfile"
! grep -q '^export P2P_' "$envfile"
! grep -q 'P2P_ADMIN_ACCESS_TOKEN' "$envfile"
! grep -q 'P2P_MATRIX_ACCESS_TOKEN' "$envfile"

# shellcheck disable=SC1090
source "$envfile"
[ "$DIREXTALK_AGENT_ROOM_ID" = "!agents-real:service.example.test" ]

legacy_p2p_agent_pattern='P2P_MATRIX_AS_URL\|P2P_MATRIX_AGENT_TOKEN\|P2P_AGENT_RUNTIME\|p2p-agent-skill\|p2p-''matrix-agent'
if grep -R "$legacy_p2p_agent_pattern" "$ROOT/scripts" "$ROOT/SKILL.md" "$ROOT/references/runtime-wiring.md"; then
  echo "deprecated Matrix-AS env names or old agent skill wiring must not be used by deployer wiring" >&2
  exit 1
fi

[ "$(DIREXTALK_AGENT_PLATFORM=hermes _detect_agent_runtime)" = "hermes" ]
[ "$(DIREXTALK_AGENT_PLATFORM=openclaw _detect_agent_runtime)" = "openclaw" ]
[ "$(DIREXTALK_AGENT_PLATFORM=claude-code _detect_agent_runtime)" = "claude-code" ]
[ "$(DIREXTALK_AGENT_PLATFORM=opencode _detect_agent_runtime)" = "opencode" ]
[ "$(DIREXTALK_CONNECT_AGENT=qodercli _detect_agent_runtime)" = "qoder" ]
[ "$(DIREXTALK_AGENT_PLATFORM=hermes DIREXTALK_CONNECT_AGENT=codex _detect_agent_runtime)" = "hermes" ]
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
[ "$(DIREXTALK_AGENT_INSTALL=skip _connect_install_policy)" = "skip" ]
[ "$(DIREXTALK_AGENT_INSTALL=recommend _connect_install_policy)" = "recommend" ]
[ "$(DIREXTALK_AGENT_INSTALL=auto _connect_install_policy)" = "auto" ]
[ "$(_connect_install_policy)" = "auto" ]
[ "$(_connect_install_mode hermes)" = "dirextalk-connect" ]
[ "$(_connect_install_mode openclaw)" = "dirextalk-connect" ]
[ "$(_connect_install_mode codex)" = "dirextalk-connect" ]
[ "$(_connect_install_mode cursor)" = "dirextalk-connect" ]
[ "$(_connect_install_mode opencode)" = "dirextalk-connect" ]
[ "$(DIREXTALK_AGENT_INSTALL_MODE=dirextalk-connect _connect_install_mode hermes)" = "dirextalk-connect" ]
if DIREXTALK_AGENT_INSTALL_MODE=gateway _connect_install_mode hermes >/dev/null 2>&1; then
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
DIREXTALK_MATRIX_SESSION_CREATE_MAX=2 \
DIREXTALK_MATRIX_SESSION_RETRY_INTERVAL=0 \
PATH="$matrix_retry_dir/bin:$PATH" \
  _create_connect_matrix_session "https://service.example.test" "agent-token" "DEVICE" "$matrix_retry_dir/session.json"
[ "$(cat "$matrix_retry_dir/count")" = "2" ]
json_test_check "$matrix_retry_dir/session.json" "data.user_id === '@agent:service.example.test' && data.access_token === 'matrix-token'"

rm -f "$matrix_retry_dir/count" "$matrix_retry_dir/session.json"
MATRIX_RETRY_COUNT="$matrix_retry_dir/count" \
MATRIX_SUCCESS_AFTER=6 \
DIREXTALK_MATRIX_SESSION_RETRY_INTERVAL=0 \
PATH="$matrix_retry_dir/bin:$PATH" \
  _create_connect_matrix_session "https://service.example.test" "agent-token" "DEVICE" "$matrix_retry_dir/session.json"
[ "$(cat "$matrix_retry_dir/count")" = "6" ]
json_test_check "$matrix_retry_dir/session.json" "data.user_id === '@agent:service.example.test' && data.access_token === 'matrix-token'"

[ "$(_agent_skill_install_path codex)" = "PROJECT_ROOT/.codex/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path claude-code)" = "PROJECT_ROOT/.claude/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path claudecode)" = "PROJECT_ROOT/.claude/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path gemini)" = "PROJECT_ROOT/.gemini/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path cursor)" = "PROJECT_ROOT/.cursor/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path copilot)" = "PROJECT_ROOT/.github/copilot/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path devin)" = "PROJECT_ROOT/.devin/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path opencode)" = "PROJECT_ROOT/.opencode/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path qoder)" = "PROJECT_ROOT/.qoder/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path pi)" = "PROJECT_ROOT/.pi/agent/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path openclaw)" = "PROJECT_ROOT/.openclaw/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path hermes)" = "PROJECT_ROOT/.hermes/skills/dirextalk-deployer" ]
[ "$(_agent_skill_install_path unknown)" = "PROJECT_ROOT/.agent/skills/dirextalk-deployer" ]

[ "$(_agent_global_skill_install_path codex)" = '${CODEX_HOME:-$HOME/.codex}/skills/dirextalk-deployer' ]
[ "$(_agent_global_skill_install_path claude-code)" = '${CLAUDE_HOME:-${CLAUDECODE_HOME:-$HOME/.claude}}/skills/dirextalk-deployer' ]
[ "$(_agent_global_skill_install_path claudecode)" = '${CLAUDE_HOME:-${CLAUDECODE_HOME:-$HOME/.claude}}/skills/dirextalk-deployer' ]
[ "$(_agent_global_skill_install_path generic)" = '$HOME/.agent/skills/dirextalk-deployer' ]
[ "$(_agent_workspace "$tmp/service")" = "$(pwd -P)" ]
[ "$(DIREXTALK_AGENT_WORKSPACE="$tmp/custom-workspace" _agent_workspace "$tmp/service")" = "$tmp/custom-workspace" ]
mkdir -p "$tmp/.codex/skills/dirextalk-deployer"
[ "$(cd "$tmp/.codex/skills/dirextalk-deployer" && _agent_workspace "$tmp/service")" = "$tmp/service/workspace" ]

connect_service_dir="$HOME/.dirextalk/nodes/service.example.test"
connect_service_binary="$connect_service_dir/dirextalk-connect/dirextalk-connect"
[ "$(_connect_binary_path "$connect_service_dir")" = "$connect_service_binary" ]
install_command=$(_connect_install_command "$connect_service_binary" "$connect_service_dir/dirextalk-connect/config.toml" "service.example.test" "$connect_service_dir")
case "$install_command" in
  *"npm install --prefix"*"service.example.test/dirextalk-connect"*"dirextalk-connect@latest"*"dirextalk-connect/dirextalk-connect"*"daemon install"*"--config"*"service.example.test/dirextalk-connect/config.toml"*"--service-name"*"service.example.test"*"--force"*) ;;
  *)
    echo "install command did not include expected dirextalk-connect daemon flags: $install_command" >&2
    exit 1
    ;;
esac
custom_install_command=$(DIREXTALK_CONNECT_NPM_PACKAGE='dirextalk-connect@override-test' _connect_install_command "$connect_service_binary" "$connect_service_dir/dirextalk-connect/config.toml" "service.example.test" "$connect_service_dir")
[[ "$custom_install_command" == *"dirextalk-connect@override-test"* ]]

[ "$(DIREXTALK_LOCAL_PATH_STYLE=windows _local_connect_path '/mnt/c/Users/alice/.dirextalk/nodes/im/dirextalk-connect/config.toml')" = "C:/Users/alice/.dirextalk/nodes/im/dirextalk-connect/config.toml" ]
[ "$(DIREXTALK_LOCAL_PATH_STYLE=windows _local_connect_path '/c/Users/alice/.dirextalk/nodes/im/dirextalk-connect/config.toml')" = "C:/Users/alice/.dirextalk/nodes/im/dirextalk-connect/config.toml" ]
windows_connect_binary="/mnt/c/Users/alice/.dirextalk/nodes/im/dirextalk-connect/dirextalk-connect.cmd"
windows_install_command=$(DIREXTALK_LOCAL_PATH_STYLE=windows _connect_install_command "$windows_connect_binary" "/mnt/c/Users/alice/.dirextalk/nodes/im/dirextalk-connect/config.toml" "im" "/mnt/c/Users/alice/.dirextalk/nodes/im")
[[ "$windows_install_command" == *"C:/Users/alice/.dirextalk/nodes/im/dirextalk-connect/config.toml"* ]]
[[ "$windows_install_command" == *"/mnt/c/Users/alice/.dirextalk/nodes/im/dirextalk-connect"* ]]
[[ "$windows_install_command" == *"--service-name im"* ]]

[ "$(_mcp_server_name "service.example.test")" = "dirextalk-service_example_test" ]
[ "$(_mcp_server_name "T1.Dirextalk.AI")" = "dirextalk-t1_dirextalk_ai" ]

mcp_service_dir="$tmp/mcp-service"
mcp_credentials="$mcp_service_dir/credentials.json"
expected_mcp_command="$mcp_service_dir/mcp/dirextalk-mcp"
mkdir -p "$mcp_service_dir"
: > "$mcp_credentials"
mkdir -p "$mcp_service_dir/mcp"
: > "$mcp_service_dir/mcp/openclaw.mcp.json"
expected_mcp_credentials="$mcp_credentials"
if command -v cygpath >/dev/null 2>&1; then
  expected_mcp_credentials=$(cygpath -m "$expected_mcp_credentials")
fi
_write_mcp_config_artifacts "service.example.test" "$mcp_service_dir" "$mcp_credentials" "codex-service-example" codex
[ -s "$mcp_service_dir/mcp/codex.toml" ]
[ ! -e "$mcp_service_dir/mcp/cursor.mcp.json" ]
[ ! -e "$mcp_service_dir/mcp/openclaw.md" ]
[ ! -e "$mcp_service_dir/mcp/openclaw-server.json" ]
[ ! -e "$mcp_service_dir/mcp/openclaw.mcp.json" ]
[ ! -e "$mcp_service_dir/mcp/hermes.mcp.json" ]
[ ! -e "$mcp_service_dir/mcp/mcp-servers.json" ]
[ -s "$mcp_service_dir/mcp/env" ]
[ -s "$mcp_service_dir/mcp/README.md" ]
grep -q '\[mcp_servers."dirextalk-service_example_test"\]' "$mcp_service_dir/mcp/codex.toml"
grep -Fq "command = \"$expected_mcp_command\"" "$mcp_service_dir/mcp/codex.toml"
! grep -q '^args = ' "$mcp_service_dir/mcp/codex.toml"
grep -q 'DIREXTALK_CREDENTIALS_FILE' "$mcp_service_dir/mcp/codex.toml"
grep -q "$(_local_connect_path "$mcp_credentials")" "$mcp_service_dir/mcp/codex.toml"
grep -q 'DIREXTALK_AGENT_NODE_ID=codex-service-example' "$mcp_service_dir/mcp/env"
grep -q 'Selected MCP type: codex' "$mcp_service_dir/mcp/README.md"
grep -q 'same MCP server name' "$mcp_service_dir/mcp/README.md"
! grep -R '19757\|proxy --url\|"proxy"' "$mcp_service_dir/mcp"
[ "$(_mcp_config_type_for_runtime codex)" = "codex" ]
[ "$(_mcp_config_type_for_runtime cursor)" = "cursor" ]
[ "$(_mcp_config_type_for_runtime openclaw)" = "openclaw" ]
[ "$(_mcp_config_type_for_runtime hermes)" = "hermes" ]
[ "$(_mcp_config_type_for_runtime gemini)" = "generic" ]
[ "$(_mcp_selected_config_path "$mcp_service_dir" gemini)" = "$mcp_service_dir/mcp/mcp-servers.json" ]

generic_service_dir="$tmp/generic-mcp-service"
generic_credentials="$generic_service_dir/credentials.json"
mkdir -p "$generic_service_dir"
: > "$generic_credentials"
_write_mcp_config_artifacts "generic.example.test" "$generic_service_dir" "$generic_credentials" "gemini-generic-example" gemini
[ -s "$generic_service_dir/mcp/mcp-servers.json" ]
[ ! -e "$generic_service_dir/mcp/codex.toml" ]
[ ! -e "$generic_service_dir/mcp/cursor.mcp.json" ]
json_test_check "$generic_service_dir/mcp/mcp-servers.json" "data.mcpServers['dirextalk-generic_example_test'].command === '$generic_service_dir/mcp/dirextalk-mcp'"
json_test_check "$generic_service_dir/mcp/mcp-servers.json" "!('args' in data.mcpServers['dirextalk-generic_example_test'])"
grep -q 'Selected MCP type: generic' "$generic_service_dir/mcp/README.md"

openclaw_service_dir="$tmp/openclaw-mcp-service"
openclaw_credentials="$openclaw_service_dir/credentials.json"
mkdir -p "$openclaw_service_dir"
: > "$openclaw_credentials"
_write_mcp_config_artifacts "openclaw.example.test" "$openclaw_service_dir" "$openclaw_credentials" "openclaw-node" openclaw
[ -s "$openclaw_service_dir/mcp/openclaw.md" ]
[ -s "$openclaw_service_dir/mcp/openclaw-server.json" ]
[ ! -e "$openclaw_service_dir/mcp/mcp-servers.json" ]
json_test_check "$openclaw_service_dir/mcp/openclaw-server.json" "data.command === '$openclaw_service_dir/mcp/dirextalk-mcp'"
json_test_check "$openclaw_service_dir/mcp/openclaw-server.json" "!('args' in data)"
if json_check "$openclaw_service_dir/mcp/openclaw-server.json" "'mcp' in data || 'mcpServers' in data" >/dev/null; then
  echo "OpenClaw server object must not be a root openclaw.json or mcpServers snippet" >&2
  exit 1
fi
grep -q 'openclaw mcp set dirextalk-openclaw_example_test' "$openclaw_service_dir/mcp/openclaw.md"
grep -q 'Do not paste' "$openclaw_service_dir/mcp/openclaw.md"
grep -q 'openclaw.json' "$openclaw_service_dir/mcp/openclaw.md"
mcp_install_command=$(_mcp_install_command "$mcp_service_dir")
[[ "$mcp_install_command" == *"npm install --prefix"*"mcp-service/mcp"*"dirextalk-mcp@latest"* ]]
custom_mcp_install_command=$(DIREXTALK_MCP_NPM_PACKAGE='dirextalk-mcp@override-test' _mcp_install_command "$mcp_service_dir")
[[ "$custom_mcp_install_command" == *"dirextalk-mcp@override-test"* ]]
mcp_doctor_command=$(_mcp_doctor_command "$mcp_credentials" "codex-service-example" "$mcp_service_dir")
[[ "$mcp_doctor_command" == *"DIREXTALK_CREDENTIALS_FILE="* ]]
[[ "$mcp_doctor_command" == *"mcp/dirextalk-mcp doctor --json"* ]]

stale_node_id=$(DIREXTALK_AGENT_NODE_ID=codex-old.example.test _agent_node_id codex new.example.test '!agents-real:new.example.test')
[[ "$stale_node_id" == codex-new.example.test-* ]]

matching_node_id=$(DIREXTALK_AGENT_NODE_ID=codex-new.example.test-123 _agent_node_id codex new.example.test '!agents-real:new.example.test')
[ "$matching_node_id" = "codex-new.example.test-123" ]

config_path="$tmp/dirextalk-connect/config.toml"
_write_connect_config "$config_path" "$tmp/dirextalk-connect/data" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test"
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
! grep -q 'DIREXTALK_CREDENTIALS_FILE' "$config_path"
grep -q '^\[display\]$' "$config_path"
grep -q 'mode = "compact"' "$config_path"
grep -q 'tool_messages = false' "$config_path"
grep -q 'thinking_messages = false' "$config_path"

speech_config_path="$tmp/dirextalk-connect/config-with-speech.toml"
DIREXTALK_SPEECH_API_KEY=speech-key \
DIREXTALK_SPEECH_BASE_URL=https://stt.example.test/v1 \
DIREXTALK_SPEECH_MODEL=whisper-test \
  _write_connect_config "$speech_config_path" "$tmp/dirextalk-connect/data-speech" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test"
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
[ "$(DIREXTALK_CONNECT_AGENT=gemini _connect_agent_type unknown)" = "gemini" ]
[ "$(DIREXTALK_CONNECT_AGENT=codex _connect_agent_type hermes)" = "codex" ]
[ "$(DIREXTALK_CODEX_COMMAND=/opt/codex/bin/codex _connect_agent_command codex)" = "/opt/codex/bin/codex" ]
[ "$(DIREXTALK_GEMINI_COMMAND=/opt/gemini/bin/gemini _connect_agent_command gemini)" = "/opt/gemini/bin/gemini" ]
[ "$(DIREXTALK_CLAUDE_CODE_COMMAND=/opt/claude/bin/claude _connect_agent_command claudecode)" = "/opt/claude/bin/claude" ]
[ "$(DIREXTALK_QODERCLI_COMMAND=/opt/qoder/qodercli _connect_agent_command qoder)" = "/opt/qoder/qodercli" ]
[ "$(DIREXTALK_CONNECT_AGENT_CMD=/custom/agent _connect_agent_command codex)" = "/custom/agent" ]
[ "$(_connect_agent_command acp openclaw)" = "openclaw" ]
[ "$(_connect_agent_command acp hermes)" = "dirextalk-connect" ]
[ "$(DIREXTALK_OPENCLAW_COMMAND=/opt/openclaw/bin/openclaw _connect_agent_command acp openclaw)" = "/opt/openclaw/bin/openclaw" ]
[ "$(DIREXTALK_HERMES_COMMAND=/opt/hermes/bin/hermes _connect_agent_command acp hermes)" = "dirextalk-connect" ]

fake_cursor_agent="$tmp/localapp/cursor-agent"
mkdir -p "$fake_cursor_agent"
cat > "$fake_cursor_agent/agent.cmd" <<'EOF'
@echo off
EOF
chmod 700 "$fake_cursor_agent/agent.cmd"
(
  export LOCALAPPDATA="$tmp/localapp"
  export DIREXTALK_LOCAL_PATH_STYLE=windows
  cursor_windows_cmd=$(_connect_agent_command cursor)
  case "$cursor_windows_cmd" in
    *cursor-agent/agent.cmd) ;;
    *) echo "expected Windows Cursor command to resolve to Cursor Agent CLI, got: $cursor_windows_cmd" >&2; exit 1 ;;
  esac
  cursor_options=$(_connect_agent_options_toml cursor cursor)
  [[ "$cursor_options" == *'mode = "yolo"'* ]]
  [[ "$cursor_options" != *'cli.js'* ]]
)
[ "$(DIREXTALK_CURSOR_MODE=ask _connect_agent_options_toml cursor cursor)" = 'mode = "ask"' ]

fake_version_dir="$fake_cursor_agent/versions/2026.07.01-abc123"
mkdir -p "$fake_version_dir"
echo stub > "$fake_version_dir/node.exe"
(
  export LOCALAPPDATA="$tmp/localapp"
  export DIREXTALK_LOCAL_PATH_STYLE=windows
  _cursor_agent_prepare_windows
  [ -f "$fake_cursor_agent/versions/dist-package/node.exe" ]
)

cmd_config_path="$tmp/dirextalk-connect/config-with-cmd.toml"
_write_connect_config "$cmd_config_path" "$tmp/dirextalk-connect/data-cmd" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "/opt/codex/bin/codex"
grep -q 'cmd = "/opt/codex/bin/codex"' "$cmd_config_path"

options_config_path="$tmp/dirextalk-connect/config-with-extra-options.toml"
_write_connect_config "$options_config_path" "$tmp/dirextalk-connect/data-options" "reasonix-node" "reasonix" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "" 'serve_url = "http://127.0.0.1:8080"'
grep -q 'type = "reasonix"' "$options_config_path"
grep -q 'serve_url = "http://127.0.0.1:8080"' "$options_config_path"
grep -q 'mode = "yolo"' "$options_config_path"
! grep -q 'backend = "app_server"' "$options_config_path"

codex_options_config_path="$tmp/dirextalk-connect/config-with-codex-extra-options.toml"
_write_connect_config "$codex_options_config_path" "$tmp/dirextalk-connect/data-codex-options" "codex-node" "codex" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "" $'mode = "full-auto"\nmodel = "gpt-5.5"'
grep -q 'backend = "app_server"' "$codex_options_config_path"
grep -q 'app_server_url = "stdio"' "$codex_options_config_path"
grep -q 'mode = "full-auto"' "$codex_options_config_path"
[ "$(awk '/^\[projects.agent.options\]/{in_options=1; next} /^\[/{in_options=0} in_options && /^[[:space:]]*mode[[:space:]]*=/{count++} END{print count+0}' "$codex_options_config_path")" = "1" ]
grep -q 'model = "gpt-5.5"' "$codex_options_config_path"

fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/npm" <<'EOF'
#!/usr/bin/env bash
[ -z "${NPM_CALLS:-}" ] || printf '%s\n' "$*" >> "$NPM_CALLS"
[ "${NPM_FAIL:-0}" != "1" ] || exit 1
exit 0
EOF
cat > "$fakebin/dirextalk-mcp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat > "$fakebin/dirextalk-connect" <<'EOF'
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
dirextalk-connect daemon status

  Status:    ${CONNECT_STATUS:-Stopped}
  Platform:  launchd
  WorkDir:   /tmp/dirextalk-test/dirextalk-connect
STATUS
  exit 0
fi
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "logs" ]; then
  [ "${3:-}" = "--service-name" ]
  [ "${4:-}" = "service.example.test" ]
  printf '%s\n' "${CONNECT_LOG_OUTPUT:-}"
  exit 0
fi
exit 1
EOF
chmod 700 "$fakebin/npm" "$fakebin/dirextalk-connect" "$fakebin/dirextalk-mcp"
mkdir -p "$(dirname "$expected_mcp_command")"
cp "$fakebin/dirextalk-mcp" "$expected_mcp_command"
chmod 700 "$expected_mcp_command"
STATE_CALLS="$tmp/state.calls"
: > "$STATE_CALLS"
set +e
PATH="$fakebin:$PATH" _maybe_auto_install_connect auto codex codex "$tmp/service" "$tmp/service/dirextalk-connect/config.toml" dirextalk-connect service.example.test
connect_stopped_rc=$?
set -e
[ "$connect_stopped_rc" -ne 0 ]
grep -q '^connect_install_status=install_failed$' "$STATE_CALLS"

STATE_CALLS="$tmp/state-agent-log.calls"
: > "$STATE_CALLS"
set +e
PATH="$fakebin:$PATH" CONNECT_STATUS=Running CONNECT_LOG_OUTPUT='time=2026-07-01T17:00:18 level=ERROR msg="cursorSession: process failed" stderr="Error: Authentication required. Please run '\''agent login'\'' first, or set CURSOR_API_KEY environment variable."' _maybe_auto_install_connect auto cursor cursor "$tmp/service" "$tmp/service/dirextalk-connect/config.toml" dirextalk-connect service.example.test
connect_agent_log_rc=$?
set -e
[ "$connect_agent_log_rc" -ne 0 ]
grep -q '^connect_install_status=install_failed$' "$STATE_CALLS"

STATE_CALLS="$tmp/state-agent-offline.calls"
: > "$STATE_CALLS"
set +e
PATH="$fakebin:$PATH" CONNECT_STATUS=Running CONNECT_LOG_OUTPUT='time=2026-07-01T17:02:05 level=ERROR msg="agent backend offline" project=cursor error="agent is offline"' _maybe_auto_install_connect auto cursor cursor "$tmp/service" "$tmp/service/dirextalk-connect/config.toml" dirextalk-connect service.example.test
connect_agent_offline_rc=$?
set -e
[ "$connect_agent_offline_rc" -ne 0 ]
grep -q '^connect_install_status=install_failed$' "$STATE_CALLS"

STATE_CALLS="$tmp/state-agent-ready.calls"
: > "$STATE_CALLS"
PATH="$fakebin:$PATH" CONNECT_STATUS=Running CONNECT_LOG_OUTPUT='time=2026-07-01T17:02:06 level=INFO msg="dirextalk-connect is running" projects=1' _maybe_auto_install_connect auto cursor cursor "$tmp/service" "$tmp/service/dirextalk-connect/config.toml" dirextalk-connect service.example.test
grep -q '^connect_install_status=installed$' "$STATE_CALLS"

STATE_CALLS="$tmp/state-connect-update-fallback.calls"
NPM_CALLS="$tmp/npm-connect-update.calls"
: > "$STATE_CALLS"
: > "$NPM_CALLS"
PATH="$fakebin:$PATH" NPM_CALLS="$NPM_CALLS" NPM_FAIL=1 CONNECT_STATUS=Running CONNECT_LOG_OUTPUT='time=2026-07-01T17:02:06 level=INFO msg="dirextalk-connect is running" projects=1' _maybe_auto_install_connect auto cursor cursor "$tmp/service" "$tmp/service/dirextalk-connect/config.toml" dirextalk-connect service.example.test
grep -q '^connect_install_status=installed$' "$STATE_CALLS"
[ -s "$NPM_CALLS" ]
grep -q -- '--prefix' "$NPM_CALLS"
grep -q 'dirextalk-connect@latest' "$NPM_CALLS"

STATE_CALLS="$tmp/state-no-ready-log.calls"
: > "$STATE_CALLS"
set +e
PATH="$fakebin:$PATH" CONNECT_STATUS=Running DIREXTALK_CONNECT_STARTUP_TIMEOUT_SECONDS=0 CONNECT_LOG_OUTPUT='time=2026-07-01T17:02:07 level=INFO msg="config loaded" path=config.toml' _maybe_auto_install_connect auto cursor cursor "$tmp/service" "$tmp/service/dirextalk-connect/config.toml" dirextalk-connect service.example.test
connect_no_ready_log_rc=$?
set -e
[ "$connect_no_ready_log_rc" -ne 0 ]
grep -q '^connect_install_status=install_failed$' "$STATE_CALLS"

STATE_CALLS="$tmp/mcp-state.calls"
NPM_CALLS="$tmp/npm-mcp-update.calls"
: > "$STATE_CALLS"
: > "$NPM_CALLS"
PATH="$fakebin:$PATH" NPM_CALLS="$NPM_CALLS" NPM_FAIL=1 _maybe_auto_install_mcp auto service.example.test "$mcp_credentials" codex-service-example
grep -q '^mcp_install_status=installed$' "$STATE_CALLS"
! grep -q '^mcp_daemon_' "$STATE_CALLS"
[ -s "$NPM_CALLS" ]
grep -q -- '--prefix' "$NPM_CALLS"
grep -q 'dirextalk-mcp@latest' "$NPM_CALLS"

STATE_CALLS="$tmp/mcp-recommend-state.calls"
: > "$STATE_CALLS"
PATH="$fakebin:$PATH" _maybe_auto_install_mcp recommend
grep -q '^mcp_install_status=recommend$' "$STATE_CALLS"
! grep -q '^mcp_daemon_' "$STATE_CALLS"

# When explicit Gateway settings are not set, OpenClaw ACP should auto-discover
# the Gateway from ~/.openclaw/openclaw.json.
openclaw_fallback_options=$(_connect_agent_options_toml openclaw acp 2> "$tmp/openclaw-fallback.err")
[[ "$openclaw_fallback_options" == *'args = ["acp", "--session", "agent:main:main"]'* ]]
grep -q 'auto-detect the Gateway' "$tmp/openclaw-fallback.err"

openclaw_session_fallback_options=$(DIREXTALK_OPENCLAW_ACP_SESSION=agent:dirextalk:main _connect_agent_options_toml openclaw acp 2> "$tmp/openclaw-session-fallback.err")
[[ "$openclaw_session_fallback_options" == *'args = ["acp", "--session", "agent:dirextalk:main"]'* ]]

if DIREXTALK_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 _connect_agent_options_toml openclaw acp > "$tmp/openclaw-partial.out" 2> "$tmp/openclaw-partial.err"; then
  echo "OpenClaw ACP explicit Gateway options must require URL, token file, and session together" >&2
  exit 1
fi
grep -q 'DIREXTALK_OPENCLAW_ACP_TOKEN_FILE' "$tmp/openclaw-partial.err"
grep -q 'DIREXTALK_OPENCLAW_ACP_SESSION' "$tmp/openclaw-partial.err"

openclaw_options=$(
  DIREXTALK_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 \
  DIREXTALK_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/gateway.token \
  DIREXTALK_OPENCLAW_ACP_SESSION=agent:main:main \
  _connect_agent_options_toml openclaw acp
)
[[ "$openclaw_options" == *'args = ["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "/mnt/c/Users/alice/.openclaw/gateway.token", "--session", "agent:main:main"]'* ]]
[[ "$openclaw_options" == *'display_name = "OpenClaw ACP"'* ]]

openclaw_session_options=$(
  DIREXTALK_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 \
  DIREXTALK_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/gateway.token \
  DIREXTALK_OPENCLAW_ACP_SESSION=agent:dirextalk:main \
  _connect_agent_options_toml openclaw acp
)
[[ "$openclaw_session_options" == *'--session", "agent:dirextalk:main"'* ]]

openclaw_url_options=$(DIREXTALK_OPENCLAW_ACP_ARGS_TOML='["acp", "--url", "wss://gateway.example.test:18789", "--session", "agent:main:main"]' _connect_agent_options_toml openclaw acp)
[[ "$openclaw_url_options" == *'args = ["acp", "--url", "wss://gateway.example.test:18789", "--session", "agent:main:main"]'* ]]

openclaw_posix_token_options=$(DIREXTALK_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 DIREXTALK_LOCAL_PATH_STYLE=posix DIREXTALK_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/token.json DIREXTALK_OPENCLAW_ACP_SESSION=agent:main:main _connect_agent_options_toml openclaw acp)
[[ "$openclaw_posix_token_options" == *'args = ["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "/mnt/c/Users/alice/.openclaw/token.json", "--session", "agent:main:main"]'* ]]

openclaw_token_options=$(DIREXTALK_OPENCLAW_ACP_URL=ws://127.0.0.1:18790 DIREXTALK_LOCAL_PATH_STYLE=windows DIREXTALK_OPENCLAW_ACP_TOKEN_FILE=/mnt/c/Users/alice/.openclaw/token.json DIREXTALK_OPENCLAW_ACP_SESSION=agent:main:main _connect_agent_options_toml openclaw acp)
[[ "$openclaw_token_options" == *'args = ["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "C:/Users/alice/.openclaw/token.json", "--session", "agent:main:main"]'* ]]

hermes_options=$(_connect_agent_options_toml hermes acp)
[[ "$hermes_options" == *'args = ["hermes-acp-adapter", "--", "hermes", "acp"]'* ]]
[[ "$hermes_options" == *'display_name = "Hermes ACP"'* ]]

hermes_custom_command_options=$(DIREXTALK_HERMES_COMMAND=/opt/hermes/bin/hermes _connect_agent_options_toml hermes acp)
[[ "$hermes_custom_command_options" == *'args = ["hermes-acp-adapter", "--", "/opt/hermes/bin/hermes", "acp"]'* ]]

hermes_custom_args_options=$(DIREXTALK_HERMES_ACP_ARGS_TOML='["acp", "--profile", "dirextalk"]' _connect_agent_options_toml hermes acp)
[[ "$hermes_custom_args_options" == *'args = ["hermes-acp-adapter", "--", "hermes", "acp", "--profile", "dirextalk"]'* ]]

openclaw_config_path="$tmp/dirextalk-connect/config-openclaw.toml"
_write_connect_config "$openclaw_config_path" "$tmp/dirextalk-connect/data-openclaw" "openclaw-node" "$(_connect_agent_type openclaw)" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "$(_connect_agent_command acp openclaw)" "$openclaw_options"
grep -q 'type = "acp"' "$openclaw_config_path"
grep -q 'cmd = "openclaw"' "$openclaw_config_path"
grep -q 'args = \["acp", "--url", "ws://127.0.0.1:18790", "--token-file", "/mnt/c/Users/alice/.openclaw/gateway.token", "--session", "agent:main:main"\]' "$openclaw_config_path"
grep -q 'display_name = "OpenClaw ACP"' "$openclaw_config_path"

hermes_config_path="$tmp/dirextalk-connect/config-hermes.toml"
_write_connect_config "$hermes_config_path" "$tmp/dirextalk-connect/data-hermes" "hermes-node" "$(_connect_agent_type hermes)" "$tmp/workspace" "https://service.example.test" "matrix-token" "@agent:service.example.test" "!agents-real:service.example.test" "@owner:service.example.test" "$(_connect_agent_command acp hermes)" "$(_connect_agent_options_toml hermes acp)"
grep -q 'type = "acp"' "$hermes_config_path"
grep -q 'cmd = "dirextalk-connect"' "$hermes_config_path"
grep -q 'args = \["hermes-acp-adapter", "--", "hermes", "acp"\]' "$hermes_config_path"
grep -q 'display_name = "Hermes ACP"' "$hermes_config_path"

guidance=$(
  _print_connect_guidance codex https://service.example.test "$HOME/.dirextalk/nodes/service.example.test/credentials.json" "$HOME/.dirextalk/nodes/service.example.test/env" recommend dirextalk-connect "install command" codex-service "$config_path" "$HOME/.dirextalk/nodes/service.example.test/dirextalk-connect/bin/dirextalk-connect" codex "/opt/codex/bin/codex" service.example.test 2>&1 >/dev/null
)
[[ "$guidance" == *"DIREXTALK_DOMAIN"* ]]
[[ "$guidance" == *"DIREXTALK_AGENT_TOKEN"* ]]
[[ "$guidance" == *"dirextalk-connect service"* ]]
[[ "$guidance" == *"DIREXTALK_AGENT_ROOM_ID"* ]]
[[ "$guidance" == *"DIREXTALK_AGENT_NODE_ID"* ]]
[[ "$guidance" == *"dirextalk-connect config"* ]]
[[ "$guidance" == *"/opt/codex/bin/codex"* ]]
[[ "$guidance" == *"daemon install"* ]]
[[ "$guidance" == *"dirextalk-connect@latest"* || "$install_command" == *"dirextalk-connect@latest"* ]]
[[ "$guidance" == *"type = \"matrix\""* || "$guidance" == *"dirextalk-connect will use Matrix"* ]]
bad_credentials_env_name="DIREXTALK_CREDENTIALS""_FILE"
if [[ "$guidance" == *"$bad_credentials_env_name"* ]]; then
  echo "dirextalk-connect guidance must not use $bad_credentials_env_name; it writes direct Matrix config" >&2
  exit 1
fi

stale_mcp_config="$tmp/stale-mcp.json"
cat > "$stale_mcp_config" <<'EOF'
{"mcpServers":{"dirextalk-service_example_test":{"command":"dirextalk-mcp","env":{"DIREXTALK_CREDENTIALS_FILE":"/old/credentials.json"},"args":["proxy","--url","http://127.0.0.1:19999/mcp"]}}}
EOF
mcp_guidance=$(
  DIREXTALK_MCP_CONFIG_CONFLICT_PATHS="$stale_mcp_config" \
    _print_mcp_guidance codex service.example.test dirextalk-service_example_test "$mcp_credentials" "$mcp_service_dir/mcp" codex "$mcp_service_dir/mcp/codex.toml" "$mcp_install_command" "$mcp_doctor_command" "$mcp_service_dir" 2>&1 >/dev/null
)
[[ "$mcp_guidance" == *"Existing MCP config may shadow this deployment"* ]]
[[ "$mcp_guidance" == *"$stale_mcp_config"* ]]
[[ "$mcp_guidance" == *"Selected MCP type:"* ]]
[[ "$mcp_guidance" == *"Selected MCP config:"* ]]
[[ "$mcp_guidance" == *"S6 writes only the MCP config selected for the detected runtime"* ]]
[[ "$mcp_guidance" != *"MCP optional daemon"* ]]
[[ "$mcp_guidance" != *"MCP daemon URL"* ]]
[[ "$mcp_guidance" != *"MCP proxy command"* ]]
[[ "$mcp_guidance" != *"daemon install"* ]]
[[ "$mcp_guidance" != *"19757"* ]]

echo "s6 wire local ok"
