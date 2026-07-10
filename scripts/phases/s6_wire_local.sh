#!/usr/bin/env bash
# S6 WIRE_LOCAL_CLIENT - write service-scoped credentials and dirextalk-connect config.
#
#   ① ~/.dirextalk/nodes/<service_id>/credentials.json
#   ② dirextalk-connect Matrix config and install guidance for the detected agent runtime
#   ③ capability-specific MCP artifacts under the service directory
#
# Tokens change on every rebuild, so local credentials and dirextalk-connect config must be refreshed.

S6_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$S6_DIR/../lib/paths.sh"
# shellcheck disable=SC1090
source "$S6_DIR/../lib/json.sh"
# shellcheck disable=SC1090
source "$S6_DIR/../lib/local-paths.sh"
# S6 local bridge paths honor DIREXTALK_LOCAL_PATH_STYLE through local-paths.sh.

_dirextalk_home() {
  dirextalk_home
}

_dirextalk_service_id() {
  dirextalk_service_id "$1"
}

_dirextalk_service_dir() {
  dirextalk_service_dir "$1"
}

_connect_supported_agents() {
  printf '%s\n' acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux
}

_connect_supported_agents_csv() {
  _connect_supported_agents | paste -sd ',' - | sed 's/,/, /g'
}

_connect_agent_alias() {
  case "$1" in
    claude|claude-code|claudecode) printf 'claudecode\n' ;;
    open-code|opencode) printf 'opencode\n' ;;
    qodercli|qoder) printf 'qoder\n' ;;
    agy|antigravity) printf 'antigravity\n' ;;
    acp|codex|copilot|cursor|devin|gemini|iflow|kimi|pi|reasonix|tmux) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

_validate_connect_agent() {
  local agent
  agent=$(_connect_agent_alias "$1" 2>/dev/null) || {
    fail "dirextalk-connect agent must be one of: $(_connect_supported_agents_csv)."
    return 1
  }
  printf '%s\n' "$agent"
}

# shellcheck disable=SC1090
source "$S6_DIR/../lib/connect-agent-adapters.sh"
# shellcheck disable=SC1090
source "$S6_DIR/../lib/connect-daemon-logs.sh"
# shellcheck disable=SC1090
source "$S6_DIR/../lib/mcp-client-adapters.sh"

_detect_agent_runtime() {
  local active_runtime explicit_agent home_runtime
  if [ -n "${DIREXTALK_AGENT_PLATFORM:-}" ] && [ "${DIREXTALK_AGENT_PLATFORM:-}" != "auto" ]; then
    _validate_agent_platform "$DIREXTALK_AGENT_PLATFORM" || return 1
    printf '%s\n' "$DIREXTALK_AGENT_PLATFORM"
    return 0
  fi
  if [ -n "${DIREXTALK_CONNECT_AGENT:-}" ]; then
    explicit_agent=$(_validate_connect_agent "$DIREXTALK_CONNECT_AGENT") || return 1
    printf '%s\n' "$explicit_agent"
    return 0
  fi
  # Active-process signals are stronger than stale config directories from
  # other agents that have used this WSL home before.
  active_runtime=$(_active_agent_runtime)
  if [ -n "$active_runtime" ]; then printf '%s\n' "$active_runtime"; return 0; fi
  home_runtime=$(_single_runtime_from_home_vars)
  if [ -n "$home_runtime" ]; then printf '%s\n' "$home_runtime"; return 0; fi
  # Fallback: check for agent config directories on disk.
  home_runtime=$(_single_runtime_from_config_dirs)
  if [ -n "$home_runtime" ]; then printf '%s\n' "$home_runtime"; return 0; fi
  printf 'unknown\n'
}

_active_agent_runtime() {
  local runtime
  for runtime in $(_detectable_agent_runtimes); do
    if _runtime_has_env_signal "$runtime"; then
      printf '%s\n' "$runtime"
      return 0
    fi
  done
  for runtime in $(_detectable_agent_runtimes); do
    if _runtime_has_context_signal "$runtime"; then
      printf '%s\n' "$runtime"
      return 0
    fi
  done
  return 0
}

_detectable_agent_runtimes() {
  printf '%s\n' claudecode codex gemini cursor copilot devin kimi opencode iflow qoder pi antigravity acp reasonix tmux openclaw hermes
}

_runtime_has_active_signal() {
  _runtime_has_env_signal "$1" || _runtime_has_context_signal "$1"
}

_runtime_has_env_signal() {
  local runtime=$1
  case "$runtime" in
    acp)
      _env_name_matches '^ACP_'
      ;;
    antigravity)
      _env_name_matches '^(ANTIGRAVITY_|GOOGLE_ANTIGRAVITY_|AGY_)'
      ;;
    codex)
      _env_name_matches '^CODEX_'
      ;;
    claudecode|claude-code)
      _env_name_matches '^(CLAUDECODE|CLAUDECODE_|CLAUDE_CODE_)'
      ;;
    gemini)
      _env_name_matches '^(GEMINI_CLI|GEMINI_CLI_|GEMINI_AGENT_|GOOGLE_GEMINI_CLI_)'
      ;;
    cursor)
      _env_name_matches '^CURSOR_'
      ;;
    copilot)
      _env_name_matches '^(COPILOT_|GITHUB_COPILOT_)'
      ;;
    devin)
      _env_name_matches '^(DEVIN_|WINDSURF_)'
      ;;
    iflow)
      _env_name_matches '^IFLOW_'
      ;;
    kimi)
      _env_name_matches '^KIMI_'
      ;;
    opencode)
      _env_name_matches '^(OPENCODE_|OPEN_CODE_)'
      ;;
    pi)
      _env_name_matches '^(PI_CODING_AGENT_|PI_AGENT_)'
      ;;
    qoder)
      _env_name_matches '^QODER_'
      ;;
    reasonix)
      _env_name_matches '^REASONIX_'
      ;;
    tmux)
      _env_name_matches '^TMUX'
      ;;
    openclaw)
      _env_name_matches '^OPENCLAW_'
      ;;
    hermes)
      _env_name_matches '^HERMES_'
      ;;
    *) return 1 ;;
  esac
}

_runtime_has_context_signal() {
  local runtime=$1
  case "$runtime" in
    acp)
      _active_text_contains '/.acp/' ||
        _active_text_contains '/.agents/' ||
        _process_name_matches 'acp'
      ;;
    antigravity)
      _active_text_contains '/.antigravity/' ||
        _active_text_contains 'antigravity' ||
        _process_name_matches 'agy'
      ;;
    codex)
      _active_text_contains '/.codex/tmp/' ||
        _active_text_contains 'openai/codex' ||
        _active_text_contains 'openai.codex' ||
        _active_text_contains '/.codex/' ||
        _process_name_matches 'codex'
      ;;
    claudecode|claude-code)
      _active_text_contains '/.claude/tmp/' ||
        _active_text_contains '/.claude/' ||
        _active_text_contains 'claude-code' ||
        _process_name_matches 'claude'
      ;;
    gemini)
      _active_text_contains '/.gemini/tmp/' ||
        _active_text_contains '/.gemini/' ||
        _process_name_matches 'gemini'
      ;;
    cursor)
      _active_text_contains '/.cursor/tmp/' ||
        _active_text_contains '/.cursor/' ||
        _active_text_contains 'cursor' ||
        _process_name_matches 'cursor'
      ;;
    copilot)
      _active_text_contains '/.github/copilot/' ||
        _active_text_contains '/.copilot/' ||
        _process_name_matches 'copilot'
      ;;
    devin)
      _active_text_contains '/.devin/' ||
        _process_name_matches 'devin'
      ;;
    iflow)
      _active_text_contains '/.iflow/' ||
        _process_name_matches 'iflow'
      ;;
    kimi)
      _active_text_contains '/.kimi/' ||
        _process_name_matches 'kimi'
      ;;
    opencode)
      _active_text_contains '/.opencode/' ||
        _active_text_contains '/.open-code/' ||
        _process_name_matches 'opencode'
      ;;
    pi)
      _active_text_contains '/.pi/agent/' ||
        _process_name_matches 'pi'
      ;;
    qoder)
      _active_text_contains '/.qoder/' ||
        _process_name_matches 'qoder'
      ;;
    reasonix)
      _active_text_contains '/.reasonix/' ||
        _process_name_matches 'reasonix'
      ;;
    tmux)
      _process_name_matches 'tmux'
      ;;
    openclaw)
      _active_text_contains '/.openclaw/tmp/' ||
        _active_text_contains '/.openclaw/' ||
        _process_name_matches 'openclaw'
      ;;
    hermes)
      _active_text_contains '/.hermes/tmp/' ||
        _active_text_contains '/.hermes/' ||
        _process_name_matches 'hermes'
      ;;
    *) return 1 ;;
  esac
}

_single_runtime_from_home_vars() {
  _single_runtime_from_sources vars
}

_single_runtime_from_config_dirs() {
  _single_runtime_from_sources dirs
}

_single_runtime_from_sources() {
  local source=$1 runtime match count=0
  for runtime in $(_detectable_agent_runtimes); do
    case "$source" in
      vars)
        _runtime_home_var_is_set "$runtime" || continue
        ;;
      dirs)
        _runtime_config_dir_exists "$runtime" || continue
        ;;
    esac
    match=$runtime
    count=$((count+1))
  done
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$match"
  fi
  return 0
}

_runtime_home_var_is_set() {
  case "$1" in
    acp) [ -n "${ACP_HOME:-}" ] ;;
    antigravity) [ -n "${ANTIGRAVITY_HOME:-}" ] || [ -n "${AGY_HOME:-}" ] ;;
    claudecode|claude-code) [ -n "${CLAUDE_HOME:-}" ] || [ -n "${CLAUDECODE_HOME:-}" ] ;;
    codex) [ -n "${CODEX_HOME:-}" ] ;;
    copilot) [ -n "${COPILOT_HOME:-}" ] ;;
    cursor) [ -n "${CURSOR_HOME:-}" ] ;;
    devin) [ -n "${DEVIN_HOME:-}" ] ;;
    gemini) [ -n "${GEMINI_HOME:-}" ] ;;
    iflow) [ -n "${IFLOW_HOME:-}" ] ;;
    kimi) [ -n "${KIMI_HOME:-}" ] ;;
    opencode) [ -n "${OPENCODE_HOME:-}" ] || [ -n "${OPEN_CODE_HOME:-}" ] ;;
    pi) [ -n "${PI_CODING_AGENT_DIR:-}" ] || [ -n "${PI_HOME:-}" ] ;;
    qoder) [ -n "${QODER_HOME:-}" ] ;;
    reasonix) [ -n "${REASONIX_HOME:-}" ] ;;
    tmux) [ -n "${TMUX_HOME:-}" ] ;;
    openclaw) [ -n "${OPENCLAW_HOME:-}" ] ;;
    hermes) [ -n "${HERMES_HOME:-}" ] ;;
    *) return 1 ;;
  esac
}

_runtime_config_dir_exists() {
  case "$1" in
    acp) [ -d "$HOME/.acp" ] ;;
    antigravity) [ -d "$HOME/.antigravity" ] ;;
    claudecode|claude-code) [ -d "$HOME/.claude" ] ;;
    codex) [ -d "$HOME/.codex" ] ;;
    copilot) [ -d "$HOME/.copilot" ] || [ -d "$HOME/.github/copilot" ] ;;
    cursor) [ -d "$HOME/.cursor" ] ;;
    devin) [ -d "$HOME/.devin" ] ;;
    gemini) [ -d "$HOME/.gemini" ] ;;
    iflow) [ -d "$HOME/.iflow" ] ;;
    kimi) [ -d "$HOME/.kimi" ] ;;
    opencode) [ -d "$HOME/.opencode" ] || [ -d "$HOME/.open-code" ] ;;
    pi) [ -d "$HOME/.pi/agent" ] || [ -d "$HOME/.pi" ] ;;
    qoder) [ -d "$HOME/.qoder" ] ;;
    reasonix) [ -d "$HOME/.reasonix" ] ;;
    tmux) [ -d "$HOME/.tmux" ] ;;
    openclaw) [ -d "$HOME/.openclaw" ] ;;
    hermes) [ -d "$HOME/.hermes" ] ;;
    *) return 1 ;;
  esac
}

_env_name_matches() {
  env | sed -E 's/=.*$//' | grep -Eq "$1"
}

_active_text_contains() {
  local needle=$1 text
  text=$(printf '%s:%s' "${PATH:-}" "${PWD:-}" | tr '[:upper:]' '[:lower:]')
  case "$text" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

_process_name_matches() {
  local needle=$1
  [ "${DIREXTALK_AGENT_DETECT_PROCESS:-1}" != "0" ] || return 1
  _process_tree_names | tr '[:upper:]' '[:lower:]' | grep -Eq "(^|[^a-z0-9])${needle}([^a-z0-9]|$)"
}

_process_tree_names() {
  local pid=${BASHPID:-$$} ppid depth=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 12 ]; do
    ps -o comm= -p "$pid" 2>/dev/null || true
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
    pid=$ppid
    depth=$((depth+1))
  done
}

_validate_agent_platform() {
  case "$1" in
    auto|generic|unknown|openclaw|hermes) return 0 ;;
    *)
      _connect_agent_alias "$1" >/dev/null 2>&1 && return 0
      fail "DIREXTALK_AGENT_PLATFORM must be auto, a dirextalk-connect agent ($(_connect_supported_agents_csv)), openclaw, hermes, generic, or unknown."
      ;;
  esac
}

_connect_install_policy() {
  local policy=${DIREXTALK_AGENT_INSTALL:-auto}
  case "$policy" in
    skip|recommend|auto) printf '%s\n' "$policy" ;;
    *) fail "DIREXTALK_AGENT_INSTALL must be skip, recommend, or auto." ;;
  esac
}

_connect_install_mode() {
  local runtime=$1 mode=${DIREXTALK_AGENT_INSTALL_MODE:-recommended}
  case "$mode" in
    recommended)
      printf 'dirextalk-connect\n'
      ;;
    dirextalk-connect) printf '%s\n' "$mode" ;;
    *) fail "DIREXTALK_AGENT_INSTALL_MODE must be recommended or dirextalk-connect." ;;
  esac
}

_validate_real_agent_room_id() {
  local room_id=$1
  [ -n "$room_id" ] || fail "state is missing real agent_room_id; complete S5 against a current message-server build."
  case "$room_id" in
    \!agent:*) fail "legacy agent_room_id $room_id is not supported; redeploy or restart message-server so it creates a real agents room." ;;
    \!*) return 0 ;;
    *) fail "agent_room_id must be a Matrix room id beginning with !, got: $room_id" ;;
  esac
}

_connect_repo() {
  printf '%s\n' "${DIREXTALK_CONNECT_REPO:-https://github.com/YingSuiAI/dirextalk-connect.git}"
}

_connect_npm_package() {
  printf '%s\n' "${DIREXTALK_CONNECT_NPM_PACKAGE:-dirextalk-connect@latest}"
}

_connect_ref() {
  printf '%s\n' "${DIREXTALK_CONNECT_REF:-main}"
}

_connect_source_dir() {
  local service_dir=$1
  printf '%s\n' "${DIREXTALK_CONNECT_DIR:-$service_dir/dirextalk-connect-src}"
}

_connect_runtime_dir() {
  local service_dir=$1
  printf '%s/dirextalk-connect\n' "$service_dir"
}

_connect_package_dir() {
  local service_dir=$1
  _connect_runtime_dir "$service_dir"
}

_agent_workspace() {
  local service_dir=$1
  if [ -n "${DIREXTALK_AGENT_WORKSPACE:-}" ]; then
    printf '%s\n' "$DIREXTALK_AGENT_WORKSPACE"
    return 0
  fi
  if [ -n "${DIREXTALK_AGENT_WORKSPACE_WINDOWS:-}" ]; then
    printf '%s\n' "$DIREXTALK_AGENT_WORKSPACE_WINDOWS"
    return 0
  fi
  printf '%s/workspace\n' "$service_dir"
}

_connect_config_path() {
  local service_dir=$1
  printf '%s/config.toml\n' "$(_connect_runtime_dir "$service_dir")"
}

_connect_binary_path() {
  local service_dir=$1
  if [ -n "${DIREXTALK_CONNECT_BIN:-}" ]; then
    printf '%s\n' "$DIREXTALK_CONNECT_BIN"
    return 0
  fi
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    printf '%s/dirextalk-connect.cmd\n' "$(_connect_package_dir "$service_dir")"
  else
    printf '%s/dirextalk-connect\n' "$(_connect_package_dir "$service_dir")"
  fi
}

_connect_package_bin_path() {
  local service_dir=$1
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    printf '%s/node_modules/.bin/dirextalk-connect.cmd\n' "$(_connect_package_dir "$service_dir")"
  else
    printf '%s/node_modules/.bin/dirextalk-connect\n' "$(_connect_package_dir "$service_dir")"
  fi
}

_ensure_connect_wrapper() {
  local service_dir=$1 wrapper target
  [ -z "${DIREXTALK_CONNECT_BIN:-}" ] || return 0
  wrapper=$(_connect_binary_path "$service_dir")
  target=$(_connect_package_bin_path "$service_dir")
  mkdir -p "$(dirname "$wrapper")"
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    cat > "$wrapper" <<'EOF'
@echo off
"%~dp0node_modules\.bin\dirextalk-connect.cmd" %*
EOF
  else
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -e
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$DIR/node_modules/.bin/dirextalk-connect" "$@"
EOF
  fi
  chmod 700 "$wrapper" 2>/dev/null || true
  [ -f "$target" ] || return 0
}

_env_first() {
  local name value
  for name in "$@"; do
    value=${!name:-}
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 0
}

_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_connect_speech_config_toml() {
  local enabled provider language api_key base_url model
  local q_provider q_language q_api_key q_base_url q_model
  enabled=$(_lower "${DIREXTALK_SPEECH_ENABLED:-auto}")
  case "$enabled" in
    0|false|off|no|disabled) return 0 ;;
    ""|1|true|on|yes|auto|enabled) ;;
    *) fail "DIREXTALK_SPEECH_ENABLED must be auto, true, or false." ;;
  esac

  provider=$(_lower "${DIREXTALK_SPEECH_PROVIDER:-openai}")
  language=${DIREXTALK_SPEECH_LANGUAGE:-zh}
  case "$provider" in
    openai)
      api_key=$(_env_first DIREXTALK_SPEECH_OPENAI_API_KEY DIREXTALK_SPEECH_API_KEY OPENAI_API_KEY)
      base_url=$(_env_first DIREXTALK_SPEECH_OPENAI_BASE_URL DIREXTALK_SPEECH_BASE_URL OPENAI_BASE_URL)
      model=$(_env_first DIREXTALK_SPEECH_OPENAI_MODEL DIREXTALK_SPEECH_MODEL)
      ;;
    groq)
      api_key=$(_env_first DIREXTALK_SPEECH_GROQ_API_KEY DIREXTALK_SPEECH_API_KEY GROQ_API_KEY)
      model=$(_env_first DIREXTALK_SPEECH_GROQ_MODEL DIREXTALK_SPEECH_MODEL)
      ;;
    qwen)
      api_key=$(_env_first DIREXTALK_SPEECH_QWEN_API_KEY DIREXTALK_SPEECH_API_KEY DASHSCOPE_API_KEY DASH_SCOPE_API_KEY)
      base_url=$(_env_first DIREXTALK_SPEECH_QWEN_BASE_URL DIREXTALK_SPEECH_BASE_URL)
      model=$(_env_first DIREXTALK_SPEECH_QWEN_MODEL DIREXTALK_SPEECH_MODEL)
      ;;
    gemini)
      api_key=$(_env_first DIREXTALK_SPEECH_GEMINI_API_KEY DIREXTALK_SPEECH_API_KEY GEMINI_API_KEY GOOGLE_API_KEY)
      model=$(_env_first DIREXTALK_SPEECH_GEMINI_MODEL DIREXTALK_SPEECH_MODEL)
      ;;
    *) fail "DIREXTALK_SPEECH_PROVIDER must be openai, groq, qwen, or gemini." ;;
  esac
  if [ -z "$api_key" ]; then
    return 0
  fi

  q_provider=$(_toml_escape "$provider")
  q_language=$(_toml_escape "$language")
  q_api_key=$(_toml_escape "$api_key")
  q_base_url=$(_toml_escape "$base_url")
  q_model=$(_toml_escape "$model")
  cat <<EOF
[speech]
enabled = true
provider = "$q_provider"
language = "$q_language"

[speech.$q_provider]
api_key = "$q_api_key"
EOF
  if [ -n "$base_url" ]; then
    printf 'base_url = "%s"\n' "$q_base_url"
  fi
  if [ -n "$model" ]; then
    printf 'model = "%s"\n' "$q_model"
  fi
}

_upper_drive() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

_local_path_style() {
  dirextalk_local_path_style
}

_local_connect_path() {
  dirextalk_normalize_local_path "$1"
}


_create_connect_matrix_session() {
  local asurl=$1 agent_auth_token=$2 device_id=$3 out=$4 body code http_body
  local max_attempts interval max_interval attempt preview sleep_for
  body=$(json_build matrix-session-create "$device_id")
  max_attempts=${DIREXTALK_MATRIX_SESSION_CREATE_MAX:-12}
  interval=${DIREXTALK_MATRIX_SESSION_RETRY_INTERVAL:-2}
  max_interval=${DIREXTALK_MATRIX_SESSION_RETRY_MAX_INTERVAL:-10}
  attempt=1
  sleep_for=$interval
  while [ "$attempt" -le "$max_attempts" ]; do
    http_body=$(mktemp)
    code=$(curl -sk \
      --connect-timeout "${DIREXTALK_MATRIX_SESSION_CURL_CONNECT_TIMEOUT:-10}" \
      --max-time "${DIREXTALK_MATRIX_SESSION_CURL_MAX_TIME:-20}" \
      -o "$http_body" -w '%{http_code}' -X POST "$asurl/_p2p/command" \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $agent_auth_token" \
      -d "$body" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      if ! json_assert "$http_body" matrix-session >/dev/null; then
        warn "agent.matrix_session.create response is missing Matrix session fields: $(head -c 200 "$http_body" 2>/dev/null)"
        rm -f "$http_body"
        return 1
      fi
      mv "$http_body" "$out"
      chmod 600 "$out" 2>/dev/null || true
      return 0
    fi
    preview=$(head -c 200 "$http_body" 2>/dev/null || true)
    rm -f "$http_body"
    case "${code:-000}" in
      000|404|408|409|425|429|5*)
        if [ "$attempt" -lt "$max_attempts" ]; then
          warn "agent.matrix_session.create returned HTTP ${code:-000} on attempt $attempt/$max_attempts; retrying in ${sleep_for}s."
          sleep "$sleep_for"
          if _is_non_negative_integer "$sleep_for" && _is_non_negative_integer "$max_interval"; then
            sleep_for=$((sleep_for * 2))
            [ "$sleep_for" -gt "$max_interval" ] && sleep_for=$max_interval
          fi
          attempt=$((attempt + 1))
          continue
        fi
        ;;
      401)
        warn "agent.matrix_session.create rejected agent_token. Refresh bootstrap credentials or deploy a message-server build that allows agent_token for this action."
        ;;
      *) ;;
    esac
    warn "agent.matrix_session.create returned HTTP ${code:-000}: $preview"
    return 1
  done
  return 1
}

_is_non_negative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

_connect_display_config_toml() {
  local mode tool_messages thinking_messages
  mode=${DIREXTALK_CONNECT_DISPLAY_MODE:-compact}
  tool_messages=${DIREXTALK_CONNECT_DISPLAY_TOOL_MESSAGES:-false}
  thinking_messages=${DIREXTALK_CONNECT_DISPLAY_THINKING_MESSAGES:-false}
  cat <<EOF
[display]
mode = "$(_toml_escape "$mode")"
tool_messages = $tool_messages
thinking_messages = $thinking_messages
reply_footer = true
show_context_indicator = false
EOF
}

_write_connect_config() {
  local config_path=$1 data_dir=$2 project=$3 agent=$4 workspace=$5 homeserver=$6 matrix_token=$7 matrix_user=$8 room_id=$9 admin_from=${10:-} agent_cmd=${11:-} agent_options_toml=${12:-} mcp_url=${13:-} mcp_server_name=${14:-} mcp_agent_token=${15:-} mcp_node_id=${16:-} mcp_capability=${17:-}
  local q_data q_project q_agent q_workspace q_homeserver q_token q_user q_room q_admin_from q_agent_cmd q_mcp_url q_mcp_server_name q_mcp_agent_token q_mcp_node_id q_mcp_capability speech_toml default_agent_options_toml display_toml
  mkdir -p "$(dirname "$config_path")" "$data_dir"
  q_data=$(_toml_escape "$data_dir")
  q_project=$(_toml_escape "$project")
  q_agent=$(_toml_escape "$agent")
  q_workspace=$(_toml_escape "$workspace")
  q_homeserver=$(_toml_escape "$homeserver")
  q_token=$(_toml_escape "$matrix_token")
  q_user=$(_toml_escape "$matrix_user")
  q_room=$(_toml_escape "$room_id")
  q_admin_from=$(_toml_escape "$admin_from")
  q_agent_cmd=$(_toml_escape "$agent_cmd")
  q_mcp_url=$(_toml_escape "$mcp_url")
  q_mcp_server_name=$(_toml_escape "$mcp_server_name")
  q_mcp_agent_token=$(_toml_escape "$mcp_agent_token")
  q_mcp_node_id=$(_toml_escape "$mcp_node_id")
  q_mcp_capability=$(_toml_escape "$mcp_capability")
  speech_toml=$(_connect_speech_config_toml)
  display_toml=$(_connect_display_config_toml)
  default_agent_options_toml=$(_connect_default_agent_options_toml "$agent" "$agent_options_toml")
  umask 077
  cat > "$config_path" <<EOF
language = "auto"
data_dir = "$q_data"
EOF
  if [ -n "$speech_toml" ]; then
    printf '\n%s\n' "$speech_toml" >> "$config_path"
  fi
  if [ -n "$display_toml" ]; then
    printf '\n%s\n' "$display_toml" >> "$config_path"
  fi
  cat >> "$config_path" <<EOF

[[projects]]
name = "$q_project"
admin_from = "$q_admin_from"

[projects.agent]
type = "$q_agent"

[projects.agent.options]
work_dir = "$q_workspace"
EOF
  if [ -n "$mcp_url" ]; then
    cat >> "$config_path" <<EOF
mcp_url = "$q_mcp_url"
mcp_server_name = "$q_mcp_server_name"
mcp_agent_token = "$q_mcp_agent_token"
mcp_node_id = "$q_mcp_node_id"
mcp_capability = "$q_mcp_capability"
EOF
  fi
  if [ -n "$agent_cmd" ]; then
    cat >> "$config_path" <<EOF
cmd = "$q_agent_cmd"
EOF
  fi
  if [ -n "$default_agent_options_toml" ]; then
    printf '%s\n' "$default_agent_options_toml" >> "$config_path"
  fi
  if [ -n "$agent_options_toml" ]; then
    printf '%s\n' "$agent_options_toml" >> "$config_path"
  fi
  cat >> "$config_path" <<EOF

[[projects.platforms]]
type = "matrix"

[projects.platforms.options]
homeserver = "$q_homeserver"
access_token = "$q_token"
user_id = "$q_user"
room_id = "$q_room"
share_session_in_channel = true
group_reply_all = true
auto_join = false
auto_verify = false
EOF
  chmod 600 "$config_path"
}

_connect_daemon_install_command() {
  local binary=$1 config=$2 service_name=$3 package_dir=${4:-}
  local binary_local config_local package_dir_local package package_q binary_q config_q service_q package_dir_q
  [ -n "$service_name" ] || service_name=dirextalk-connect
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    binary_local=$(_local_connect_path "$binary")
    config_local=$(_local_connect_path "$config")
    package_dir_local=${package_dir:+$(_local_connect_path "$package_dir")}
    package=$(_connect_npm_package)
    binary_q=$(_powershell_single_quote "$binary_local")
    config_q=$(_powershell_single_quote "$config_local")
    service_q=$(_powershell_single_quote "$service_name")
    package_q=$(_powershell_single_quote "$package")
    if [ -n "$package_dir_local" ]; then
      package_dir_q=$(_powershell_single_quote "$package_dir_local")
      printf "if (Test-Path -LiteralPath '%s') { & '%s' daemon stop --service-name '%s'; if (\$LASTEXITCODE -ne 0) { Write-Warning 'dirextalk-connect daemon stop failed; continuing refresh' } }; npm install --prefix '%s' '%s'; if (\$LASTEXITCODE -ne 0) { throw 'dirextalk-connect npm install failed' }; & '%s' daemon install --config '%s' --service-name '%s' --force" \
        "$binary_q" "$binary_q" "$service_q" "$package_dir_q" "$package_q" "$binary_q" "$config_q" "$service_q"
    else
      printf "if (-not (Get-Command '%s' -ErrorAction SilentlyContinue)) { npm install -g '%s'; if (\$LASTEXITCODE -ne 0) { throw 'dirextalk-connect npm install failed' } }; & '%s' daemon install --config '%s' --service-name '%s' --force" \
        "$binary_q" "$package_q" "$binary_q" "$config_q" "$service_q"
    fi
    return 0
  fi
  if [ -n "$package_dir" ]; then
    printf 'if [ -x %q ]; then %q daemon stop --service-name %q || true; fi; npm install --prefix %q %q && %q daemon install --config %q --service-name %q --force' "$binary" "$binary" "$service_name" "$package_dir" "$(_connect_npm_package)" "$binary" "$(_local_connect_path "$config")" "$service_name"
  else
    printf 'if ! command -v %q >/dev/null 2>&1; then npm install -g %q; fi && %q daemon install --config %q --service-name %q --force' "$binary" "$(_connect_npm_package)" "$binary" "$(_local_connect_path "$config")" "$service_name"
  fi
}

_powershell_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

_connect_binary_available() {
  [ -x "$1" ] || command -v "$1" >/dev/null 2>&1
}

_connect_daemon_is_running() {
  local binary=$1 service_name=$2 status
  [ -n "$service_name" ] || service_name=dirextalk-connect
  status=$("$binary" daemon status --service-name "$service_name" 2>/dev/null || true)
  printf '%s\n' "$status" | grep -Eq 'Status:[[:space:]]*Running'
}

_connect_daemon_wait_until_ready() {
  local binary=$1 service_name=$2 timeout interval elapsed logs agent_error ready
  [ -n "$service_name" ] || service_name=dirextalk-connect
  timeout=${DIREXTALK_CONNECT_STARTUP_TIMEOUT_SECONDS:-30}
  interval=${DIREXTALK_CONNECT_STARTUP_POLL_SECONDS:-2}
  case "$timeout" in *[!0-9]*|"") timeout=30 ;; esac
  case "$interval" in *[!0-9]*|"") interval=2 ;; esac
  [ "$interval" -gt 0 ] || interval=1
  elapsed=0

  while true; do
    if ! _connect_daemon_is_running "$binary" "$service_name"; then
      printf '%s\n' "daemon status is not Running"
      return 1
    fi

    logs=$("$binary" daemon logs --service-name "$service_name" -n "${DIREXTALK_CONNECT_LOG_TAIL_LINES:-120}" 2>/dev/null || true)
    agent_error=$(connect_daemon_agent_error_from_text "$logs")
    if [ -n "$agent_error" ]; then
      printf '%s\n' "local agent backend failure: $agent_error"
      return 1
    fi
    ready=$(connect_daemon_ready_from_text "$logs")
    if [ -n "$ready" ]; then
      printf '%s\n' "$ready"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout" ]; then
      printf '%s\n' "startup logs did not show 'dirextalk-connect is running' within ${timeout}s"
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

_maybe_auto_install_connect() {
  local policy=$1 runtime=$2 cc_agent=$3 service_dir=$4 config_path=$5 binary=$6 service_name=$7
  local repo ref src commit config_arg ready_evidence package_dir
  [ -n "$service_name" ] || service_name=$(basename "$service_dir")
  if [ "$policy" != "auto" ]; then
    state_set connect_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  config_arg=$(_local_connect_path "$config_path")
  package_dir=$(_connect_package_dir "$service_dir")
  if [ "${DIREXTALK_CONNECT_INSTALL_FROM:-npm}" != "source" ]; then
    if command -v npm >/dev/null 2>&1; then
      if _connect_binary_available "$binary"; then
        "$binary" daemon stop --service-name "$service_name" >/dev/null 2>&1 || true
      fi
      mkdir -p "$package_dir"
      if npm install --prefix "$package_dir" "$(_connect_npm_package)"; then
        _ensure_connect_wrapper "$service_dir"
        ok "dirextalk-connect package refreshed for this service."
      elif ! _connect_binary_available "$binary"; then
        state_set connect_install_status "install_failed" 2>/dev/null || true
        warn "dirextalk-connect service-scoped npm install failed and no existing service binary is available."
        return 1
      else
        warn "dirextalk-connect service-scoped npm update failed; continuing with the existing service binary."
      fi
    elif ! _connect_binary_available "$binary"; then
        warn "DIREXTALK_AGENT_INSTALL=auto requested, but npm is not on PATH. Install Node.js or set DIREXTALK_CONNECT_INSTALL_FROM=source."
        state_set connect_install_status "npm_missing" 2>/dev/null || true
        return 1
    else
      warn "npm is not on PATH; continuing with the existing service-scoped dirextalk-connect binary."
    fi
    if "$binary" daemon install --config "$config_arg" --service-name "$service_name" --force; then
      if ! ready_evidence=$(_connect_daemon_wait_until_ready "$binary" "$service_name"); then
        state_set connect_install_status "install_failed" 2>/dev/null || true
        warn "dirextalk-connect daemon did not reach verified ready state after install ($ready_evidence). Check the local agent command and dirextalk-connect logs."
        return 1
      fi
      state_set connect_install_status "installed" 2>/dev/null || true
      ok "dirextalk-connect daemon installed for $runtime using Matrix room bridge ($ready_evidence)."
    else
      state_set connect_install_status "install_failed" 2>/dev/null || true
      warn "dirextalk-connect daemon install failed. Config is available for manual start."
      return 1
    fi
    return 0
  fi

  repo=$(_connect_repo)
  ref=$(_connect_ref)
  src=$(_connect_source_dir "$service_dir")
  if ! command -v git >/dev/null 2>&1 || ! command -v go >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    warn "DIREXTALK_CONNECT_INSTALL_FROM=source requested, but git, go, and make are required to build dirextalk-connect from source."
    state_set connect_install_status "build_tool_missing" 2>/dev/null || true
    return 1
  fi
  if [ ! -d "$src/.git" ]; then
    mkdir -p "$(dirname "$src")"
    if ! git clone "$repo" "$src"; then
      state_set connect_install_status "clone_failed" 2>/dev/null || true
      warn "dirextalk-connect clone failed from $repo"
      return 1
    fi
  fi
  if ! git -C "$src" fetch --all --tags --prune; then
    state_set connect_install_status "fetch_failed" 2>/dev/null || true
    warn "dirextalk-connect fetch failed in $src"
    return 1
  fi
  if ! git -C "$src" checkout "$ref"; then
    state_set connect_install_status "checkout_failed" 2>/dev/null || true
    warn "dirextalk-connect checkout failed for ref $ref"
    return 1
  fi
  commit=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)
  state_set connect_commit "$commit" 2>/dev/null || true
  if ! (cd "$src" && AGENTS="$cc_agent" PLATFORMS_INCLUDE=matrix NO_WEB=1 make build-noweb); then
    state_set connect_install_status "build_failed" 2>/dev/null || true
    warn "dirextalk-connect build failed for runtime=$runtime agent=$cc_agent"
    return 1
  fi
  binary="$(_connect_runtime_dir "$service_dir")/bin/dirextalk-connect"
  mkdir -p "$(dirname "$binary")"
  if ! cp "$src/dirextalk-connect" "$binary" 2>/dev/null && ! cp "$src/dirextalk-connect.exe" "$binary" 2>/dev/null; then
    state_set connect_install_status "binary_copy_failed" 2>/dev/null || true
    warn "dirextalk-connect binary was not found after build in $src"
    return 1
  fi
  chmod 700 "$binary" 2>/dev/null || true
  if "$binary" daemon install --config "$config_arg" --service-name "$service_name" --force; then
    if ! ready_evidence=$(_connect_daemon_wait_until_ready "$binary" "$service_name"); then
      state_set connect_install_status "install_failed" 2>/dev/null || true
      warn "dirextalk-connect daemon did not reach verified ready state after install ($ready_evidence). Check the local agent command and dirextalk-connect logs."
      return 1
    fi
    state_set connect_install_status "installed" 2>/dev/null || true
    ok "dirextalk-connect daemon installed for $runtime using Matrix room bridge ($ready_evidence)."
  else
    state_set connect_install_status "install_failed" 2>/dev/null || true
    warn "dirextalk-connect daemon install failed. Config and binary are available for manual start."
    return 1
  fi
}

_agent_skill_install_path() {
  local runtime=$1
  case "$runtime" in
    acp) printf 'PROJECT_ROOT/.agents/skills/dirextalk-deployer\n' ;;
    antigravity) printf 'PROJECT_ROOT/.antigravity/skills/dirextalk-deployer\n' ;;
    codex) printf 'PROJECT_ROOT/.codex/skills/dirextalk-deployer\n' ;;
    claude|claude-code|claudecode) printf 'PROJECT_ROOT/.claude/skills/dirextalk-deployer\n' ;;
    devin) printf 'PROJECT_ROOT/.devin/skills/dirextalk-deployer\n' ;;
    iflow) printf 'PROJECT_ROOT/.iflow/skills/dirextalk-deployer\n' ;;
    kimi) printf 'PROJECT_ROOT/.kimi/skills/dirextalk-deployer\n' ;;
    opencode) printf 'PROJECT_ROOT/.opencode/skills/dirextalk-deployer\n' ;;
    pi) printf 'PROJECT_ROOT/.pi/agent/skills/dirextalk-deployer\n' ;;
    qoder) printf 'PROJECT_ROOT/.qoder/skills/dirextalk-deployer\n' ;;
    reasonix) printf 'PROJECT_ROOT/.reasonix/skills/dirextalk-deployer\n' ;;
    tmux) printf 'PROJECT_ROOT/.agent/skills/dirextalk-deployer\n' ;;
    gemini) printf 'PROJECT_ROOT/.gemini/skills/dirextalk-deployer\n' ;;
    cursor) printf 'PROJECT_ROOT/.cursor/skills/dirextalk-deployer\n' ;;
    copilot) printf 'PROJECT_ROOT/.github/copilot/skills/dirextalk-deployer\n' ;;
    openclaw) printf 'PROJECT_ROOT/.openclaw/skills/dirextalk-deployer\n' ;;
    hermes) printf 'PROJECT_ROOT/.hermes/skills/dirextalk-deployer\n' ;;
    generic|unknown|*) printf 'PROJECT_ROOT/.agent/skills/dirextalk-deployer\n' ;;
  esac
}

_agent_global_skill_install_path() {
  local runtime=$1
  case "$runtime" in
    acp) printf '$HOME/.agents/skills/dirextalk-deployer\n' ;;
    antigravity) printf '${ANTIGRAVITY_HOME:-$HOME/.antigravity}/skills/dirextalk-deployer\n' ;;
    codex) printf '${CODEX_HOME:-$HOME/.codex}/skills/dirextalk-deployer\n' ;;
    claude|claude-code|claudecode) printf '${CLAUDE_HOME:-${CLAUDECODE_HOME:-$HOME/.claude}}/skills/dirextalk-deployer\n' ;;
    devin) printf '${DEVIN_HOME:-$HOME/.devin}/skills/dirextalk-deployer\n' ;;
    iflow) printf '${IFLOW_HOME:-$HOME/.iflow}/skills/dirextalk-deployer\n' ;;
    kimi) printf '${KIMI_HOME:-$HOME/.kimi}/skills/dirextalk-deployer\n' ;;
    opencode) printf '${OPENCODE_HOME:-$HOME/.opencode}/skills/dirextalk-deployer\n' ;;
    pi) printf '${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/skills/dirextalk-deployer\n' ;;
    qoder) printf '${QODER_HOME:-$HOME/.qoder}/skills/dirextalk-deployer\n' ;;
    reasonix) printf '${REASONIX_HOME:-$HOME/.reasonix}/skills/dirextalk-deployer\n' ;;
    tmux) printf '$HOME/.agent/skills/dirextalk-deployer\n' ;;
    gemini) printf '${GEMINI_HOME:-$HOME/.gemini}/skills/dirextalk-deployer\n' ;;
    cursor) printf '${CURSOR_HOME:-$HOME/.cursor}/skills/dirextalk-deployer\n' ;;
    copilot) printf '$HOME/.github/copilot/skills/dirextalk-deployer\n' ;;
    openclaw) printf '${OPENCLAW_HOME:-$HOME/.openclaw}/skills/dirextalk-deployer\n' ;;
    hermes) printf '${HERMES_HOME:-$HOME/.hermes}/skills/dirextalk-deployer\n' ;;
    generic|unknown|*) printf '$HOME/.agent/skills/dirextalk-deployer\n' ;;
  esac
}

_connect_install_command() {
  local binary=$1 config=$2 service_name=$3 service_dir=${4:-}
  _connect_daemon_install_command "$binary" "$config" "$service_name" "${service_dir:+$(_connect_package_dir "$service_dir")}"
}

_print_runtime_install_summary() {
  local runtime=$1 mode=$2 config_path=$3 binary=$4 cc_agent=$5 cc_agent_cmd=${6:-} service_name=${7:-} install_command=${8:-}
  cat >&2 <<EOF
Recommended dirextalk-connect install:
  runtime:        $runtime
  dirextalk-connect agent: $cc_agent
  agent command:  ${cc_agent_cmd:-default PATH lookup}
  mode:           $mode
  service name:   $service_name
  config:         $config_path
  binary:         $binary
  daemon install: $install_command
EOF
}

_maybe_auto_install_agent() {
  _maybe_auto_install_connect "$@"
}

_agent_node_id() {
  local runtime=$1 domain=$2 room=$3 explicit host digest raw
  explicit=${DIREXTALK_AGENT_NODE_ID:-}
  host=${domain#http://}
  host=${host#https://}
  host=${host%%/*}
  host=${host%%:*}
  if [ -n "$explicit" ] && { [ "${DIREXTALK_AGENT_NODE_ID_FORCE:-}" = "1" ] || _agent_node_id_matches_host "$explicit" "$host"; }; then
    raw=$explicit
  else
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(printf '%s\n%s\n' "$domain" "$room" | sha256sum | awk '{print substr($1,1,10)}')
    else
      digest=$(printf '%s\n%s\n' "$domain" "$room" | shasum -a 256 | awk '{print substr($1,1,10)}')
    fi
    raw="${runtime:-agent}-${host:-dirextalk}-$digest"
  fi
  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/^$/dirextalk-agent/'
}

_agent_node_id_matches_host() {
  local node_id=$1 host=$2 normalized_node normalized_host
  normalized_node=$(printf '%s\n' "$node_id" | tr '[:upper:]' '[:lower:]')
  normalized_host=$(printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  [ -n "$normalized_host" ] && [[ "$normalized_node" == *"$normalized_host"* ]]
}

_write_credentials_file() {
  local cred=$1 domain=$2 asurl=$3 token=$4 password=$5 access_token=$6 agent_room_id=$7 node_id=$8
  mkdir -p "$(dirname "$cred")"
  json_build credentials-profile "$domain" "$asurl" "$token" "$password" "$access_token" "$agent_room_id" "$node_id" > "$cred"
  chmod 600 "$cred"
}

_print_connect_guidance() {
  local runtime=$1 asurl=$2 cred=$3 policy=$4 mode=$5 install_command=$6 node_id=$7 cc_config=$8 cc_binary=$9 cc_agent=${10} cc_agent_cmd=${11:-} service_name=${12:-}
  local skill_path global_skill_path
  skill_path=$(_agent_skill_install_path "$runtime")
  global_skill_path=$(_agent_global_skill_install_path "$runtime")
  if [ "$policy" = "skip" ]; then
    warn "Dirextalk dirextalk-connect install guidance skipped by DIREXTALK_AGENT_INSTALL=skip."
    return 0
  fi
  warn "Dirextalk dirextalk-connect install policy: $policy; platform=$runtime; mode=$mode."
  cat >&2 <<EOF
Detected agent runtime: $runtime
dirextalk-connect agent:       $cc_agent
Credential file:        $cred
dirextalk-connect config:      $cc_config
dirextalk-connect binary:      $cc_binary
dirextalk-connect agent cmd:   ${cc_agent_cmd:-default PATH lookup}
dirextalk-connect service:     $service_name
Install command:        $install_command
Project skill clone:    $skill_path
Global skill fallback:  $global_skill_path
dirextalk-connect will use Matrix Client-Server sync as @agent:<server> and is restricted to DIREXTALK_AGENT_ROOM_ID.
It talks directly to the Dirextalk homeserver for the agents room conversation.
EOF
  _print_runtime_install_summary "$runtime" "$mode" "$cc_config" "$cc_binary" "$cc_agent" "$cc_agent_cmd" "$service_name" "$install_command"
}

_clear_mcp_daemon_state() {
  local key
  [ -n "${STATE_JSON:-}" ] && [ -f "$STATE_JSON" ] || return 0
  for key in \
    agent_env_file \
    mcp_daemon_install_command \
    mcp_daemon_status_command \
    mcp_daemon_url \
    mcp_daemon_proxy_command \
    mcp_daemon_install_status
  do
    json_mutate "$STATE_JSON" delete "$key" 2>/dev/null || true
  done
}

run_phase() {
  phase_set S6_WIRE_LOCAL in_progress "writing credentials and dirextalk-connect Matrix bridge config"
  local domain asurl token access_token password agent_room_id runtime install_policy install_mode install_command
  local node_id service_dir service_dir_local node_cred workspace workspace_local service_id cc_agent cc_agent_cmd cc_agent_options_toml cc_runtime_dir cc_runtime_dir_local cc_config cc_config_local cc_data cc_data_local cc_binary cc_binary_local cc_session cc_session_local cc_source cc_package_dir
  local mcp_dir mcp_dir_local mcp_capability mcp_server_name mcp_endpoint_url mcp_install_command mcp_doctor_command mcp_codex_config mcp_cursor_config mcp_openclaw_config mcp_hermes_config mcp_json_config mcp_env_file mcp_readme
  local mcp_selected_config_type mcp_selected_config mcp_selected_config_local mcp_codex_config_local mcp_cursor_config_local mcp_openclaw_config_local mcp_hermes_config_local mcp_json_config_local mcp_env_file_local mcp_readme_local node_cred_local
  local matrix_token matrix_user matrix_device matrix_homeserver
  local connect_mcp_url connect_mcp_server_name connect_mcp_agent_token connect_mcp_node_id
  local skill_path global_skill_path
  domain=$(state_get domain)
  asurl=$(state_get as_url)
  token=$(state_get agent_token)
  access_token=$(state_get access_token)
  password=$(state_get password)
  agent_room_id=$(state_get agent_room_id)
  [ -n "$domain" ] && [ -n "$asurl" ] && [ -n "$token" ] || { phase_set S6_WIRE_LOCAL failed "missing domain/as_url/token"; fail "state is missing domain/as_url/agent_token; complete S5 first."; return 1; }
  [ -n "$access_token" ] && [ -n "$password" ] || { phase_set S6_WIRE_LOCAL failed "missing bootstrap credentials"; fail "state is missing password/access_token; complete S5 first."; return 1; }
  if ! ( _validate_real_agent_room_id "$agent_room_id" ); then
    phase_set S6_WIRE_LOCAL failed "invalid or missing agent room id"
    return 1
  fi

  if ! runtime=$(_detect_agent_runtime); then
    phase_set S6_WIRE_LOCAL failed "invalid or ambiguous agent runtime"
    return 1
  fi
  if ! cc_agent=$(_connect_agent_type "$runtime"); then
    phase_set S6_WIRE_LOCAL failed "invalid or unsupported dirextalk-connect agent"
    return 1
  fi
  if ! cc_agent_cmd=$(_connect_agent_command "$cc_agent" "$runtime"); then
    phase_set S6_WIRE_LOCAL failed "invalid dirextalk-connect agent command"
    return 1
  fi
  if ! cc_agent_options_toml=$(_connect_agent_options_toml "$runtime" "$cc_agent"); then
    phase_set S6_WIRE_LOCAL failed "invalid dirextalk-connect agent options"
    return 1
  fi
  if ! install_policy=$(_connect_install_policy); then
    phase_set S6_WIRE_LOCAL failed "invalid dirextalk-connect install policy"
    return 1
  fi
  if ! install_mode=$(_connect_install_mode "$runtime"); then
    phase_set S6_WIRE_LOCAL failed "invalid dirextalk-connect install mode"
    return 1
  fi
  if ! mcp_capability=$(_mcp_runtime_capability "$runtime"); then
    phase_set S6_WIRE_LOCAL failed "MCP capability is undeclared for runtime=$runtime"
    return 1
  fi
  if ! node_id=$(_agent_node_id "$runtime" "$domain" "$agent_room_id"); then
    phase_set S6_WIRE_LOCAL failed "agent node id generation failed"
    return 1
  fi
  if ! service_id=$(_dirextalk_service_id "${asurl:-$domain}") || [ -z "$service_id" ]; then
    phase_set S6_WIRE_LOCAL failed "service id generation failed"
    return 1
  fi
  if ! service_dir=$(_dirextalk_service_dir "${asurl:-$domain}") || [ -z "$service_dir" ]; then
    phase_set S6_WIRE_LOCAL failed "service directory resolution failed"
    return 1
  fi
  node_cred="$service_dir/credentials.json"
  if ! rm -f "$service_dir/env"; then
    phase_set S6_WIRE_LOCAL failed "legacy service env cleanup failed"
    return 1
  fi
  service_dir_local=$(_local_connect_path "$service_dir")
  workspace=$(_agent_workspace "$service_dir")
  admin_from="@owner:$domain"
  cc_runtime_dir=$(_connect_runtime_dir "$service_dir")
  cc_runtime_dir_local=$(_local_connect_path "$cc_runtime_dir")
  cc_config=$(_connect_config_path "$service_dir")
  cc_config_local=$(_local_connect_path "$cc_config")
  cc_data="$cc_runtime_dir/data"
  cc_data_local=$(_local_connect_path "$cc_data")
  cc_binary=$(_connect_binary_path "$service_dir")
  cc_binary_local=$(_local_connect_path "$cc_binary")
  cc_package_dir=$(_connect_package_dir "$service_dir")
  if ! _ensure_connect_wrapper "$service_dir"; then
    phase_set S6_WIRE_LOCAL failed "dirextalk-connect wrapper generation failed"
    return 1
  fi
  cc_session="$cc_runtime_dir/matrix-session.json"
  cc_session_local=$(_local_connect_path "$cc_session")
  cc_source=$(_connect_source_dir "$service_dir")

  if ! _write_credentials_file "$node_cred" "$domain" "$asurl" "$token" "$password" "$access_token" "$agent_room_id" "$node_id"; then
    phase_set S6_WIRE_LOCAL failed "service credential write failed"
    return 1
  fi
  ok "Wrote $node_cred (0600)."
  node_cred_local=$(_local_connect_path "$node_cred")

  if ! _write_mcp_config_artifacts "$service_id" "$service_dir" "$asurl" "$token" "$node_cred" "$node_id" "$runtime"; then
    phase_set S6_WIRE_LOCAL failed "MCP capability or artifact generation failed"
    return 1
  fi
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  mcp_dir_local=$(_local_connect_path "$mcp_dir")
  mcp_server_name=$(_mcp_server_name "$service_id")
  mcp_endpoint_url=$(_mcp_endpoint_url "$asurl")
  if ! mcp_selected_config_type=$(_mcp_config_type_for_runtime "$runtime"); then
    phase_set S6_WIRE_LOCAL failed "MCP capability is undeclared for runtime=$runtime"
    return 1
  fi
  if ! mcp_selected_config=$(_mcp_selected_config_path "$service_dir" "$runtime"); then
    phase_set S6_WIRE_LOCAL failed "MCP artifact selection failed for runtime=$runtime"
    return 1
  fi
  if [ -n "$mcp_selected_config" ]; then
    mcp_selected_config_local=$(_local_connect_path "$mcp_selected_config")
  else
    mcp_selected_config_local=
  fi
  mcp_codex_config=$(_mcp_codex_config_path "$service_dir")
  mcp_cursor_config=$(_mcp_cursor_config_path "$service_dir")
  mcp_openclaw_config=$(_mcp_openclaw_config_path "$service_dir")
  mcp_hermes_config=$(_mcp_hermes_config_path "$service_dir")
  mcp_json_config=$(_mcp_json_config_path "$service_dir")
  mcp_env_file=$(_mcp_env_file_path "$service_dir")
  mcp_readme=$(_mcp_readme_path "$service_dir")
  mcp_codex_config_local=
  mcp_cursor_config_local=
  mcp_openclaw_config_local=
  mcp_hermes_config_local=
  mcp_json_config_local=
  case "$mcp_selected_config_type" in
    codex) mcp_codex_config_local=$mcp_selected_config_local ;;
    cursor) mcp_cursor_config_local=$mcp_selected_config_local ;;
    openclaw) mcp_openclaw_config_local=$mcp_selected_config_local ;;
    hermes) mcp_hermes_config_local=$mcp_selected_config_local ;;
    generic) mcp_json_config_local=$mcp_selected_config_local ;;
  esac
  mcp_env_file_local=$(_local_connect_path "$mcp_env_file")
  mcp_readme_local=$(_local_connect_path "$mcp_readme")
  mcp_install_command=$(_mcp_install_command "$asurl" "$service_dir")
  mcp_doctor_command=$(_mcp_doctor_command "$asurl" "$node_cred" "$node_id" "$service_dir")
  ok "Wrote MCP config snippets under $mcp_dir."

  mkdir -p "$workspace"
  mkdir -p "$cc_runtime_dir"
  if ! _create_connect_matrix_session "$asurl" "$token" "DIREXTALK_CONNECT_${node_id}" "$cc_session"; then
    phase_set S6_WIRE_LOCAL failed "agent Matrix session creation failed"
    fail "failed to create dirextalk-connect Matrix session via agent.matrix_session.create."
  fi
  matrix_token=$(json_get "$cc_session" access_token)
  matrix_user=$(json_get "$cc_session" user_id)
  matrix_device=$(json_get "$cc_session" device_id)
  matrix_homeserver=$(json_get "$cc_session" homeserver)
  if [ "$matrix_user" = "@owner:$domain" ]; then
    phase_set S6_WIRE_LOCAL failed "agent Matrix session returned owner user"
    fail "agent.matrix_session.create returned owner Matrix user; deploy a message-server build with agent Matrix session support."
  fi
  case "$matrix_user" in
    @agent:*) ;;
    *) warn "agent.matrix_session.create returned non-standard agent user_id: $matrix_user" ;;
  esac
  workspace_local=$(_local_connect_path "$workspace")
  if [ "$runtime" = "cursor" ] && [ "$(dirextalk_local_path_style)" = "windows" ]; then
    if ! _cursor_agent_prepare_windows; then
      install_policy_preview=$(_connect_install_policy)
      if [ "$install_policy_preview" = "auto" ]; then
        phase_set S6_WIRE_LOCAL failed "Cursor Agent CLI missing or incomplete"
        return 1
      fi
      warn "Cursor Agent CLI is not ready; continuing in $install_policy_preview mode."
    else
      cc_agent_cmd=$(_connect_agent_command "$cc_agent" "$runtime")
    fi
  fi
  connect_mcp_url=$mcp_endpoint_url
  connect_mcp_server_name=$mcp_server_name
  connect_mcp_agent_token=$token
  connect_mcp_node_id=$node_id
  if ! _write_connect_config "$cc_config" "$cc_data_local" "$node_id" "$cc_agent" "$workspace_local" "$matrix_homeserver" "$matrix_token" "$matrix_user" "$agent_room_id" "$admin_from" "$cc_agent_cmd" "$cc_agent_options_toml" "$connect_mcp_url" "$connect_mcp_server_name" "$connect_mcp_agent_token" "$connect_mcp_node_id" "$mcp_capability"; then
    phase_set S6_WIRE_LOCAL failed "dirextalk-connect config write failed"
    return 1
  fi
  ok "Wrote dirextalk-connect Matrix config $cc_config (0600)."

  state_set agent_node_id "$node_id" 2>/dev/null || true
  state_set agent_service_id "$service_id" 2>/dev/null || true
  state_set agent_service_dir "$service_dir_local" 2>/dev/null || true
  state_set agent_credentials_file "$node_cred_local" 2>/dev/null || true
  state_set mcp_transport "http" 2>/dev/null || true
  state_set mcp_capability "$mcp_capability" 2>/dev/null || true
  state_set mcp_endpoint_url "$mcp_endpoint_url" 2>/dev/null || true
  json_mutate "$STATE_JSON" delete mcp_npm_package 2>/dev/null || true
  json_mutate "$STATE_JSON" delete mcp_command 2>/dev/null || true
  json_mutate "$STATE_JSON" delete mcp_package_dir 2>/dev/null || true
  state_set mcp_server_name "$mcp_server_name" 2>/dev/null || true
  state_set mcp_selected_config_type "$mcp_selected_config_type" 2>/dev/null || true
  state_set mcp_selected_config "$mcp_selected_config_local" 2>/dev/null || true
  state_set mcp_config_dir "$mcp_dir_local" 2>/dev/null || true
  state_set mcp_credentials_file "$node_cred_local" 2>/dev/null || true
  state_set mcp_codex_config "$mcp_codex_config_local" 2>/dev/null || true
  state_set mcp_cursor_config "$mcp_cursor_config_local" 2>/dev/null || true
  state_set mcp_openclaw_config "$mcp_openclaw_config_local" 2>/dev/null || true
  state_set mcp_hermes_config "$mcp_hermes_config_local" 2>/dev/null || true
  state_set mcp_json_config "$mcp_json_config_local" 2>/dev/null || true
  state_set mcp_env_file "$mcp_env_file_local" 2>/dev/null || true
  state_set mcp_readme "$mcp_readme_local" 2>/dev/null || true
  state_set mcp_install_command "$mcp_install_command" 2>/dev/null || true
  state_set mcp_doctor_command "$mcp_doctor_command" 2>/dev/null || true
  _clear_mcp_daemon_state
  state_set agent_workspace "$workspace_local" 2>/dev/null || true
  state_set connect_agent "$cc_agent" 2>/dev/null || true
  state_set connect_agent_cmd "$cc_agent_cmd" 2>/dev/null || true
  state_set connect_mcp_url "$connect_mcp_url" 2>/dev/null || true
  state_set connect_mcp_server_name "$connect_mcp_server_name" 2>/dev/null || true
  state_set connect_mcp_capability "$mcp_capability" 2>/dev/null || true
  if [ -n "$cc_agent_options_toml" ]; then
    state_set connect_agent_options_toml_present "true" 2>/dev/null || true
  else
    state_set connect_agent_options_toml_present "false" 2>/dev/null || true
  fi
  state_set connect_npm_package "$(_connect_npm_package)" 2>/dev/null || true
  state_set connect_repo "$(_connect_repo)" 2>/dev/null || true
  state_set connect_ref "$(_connect_ref)" 2>/dev/null || true
  state_set connect_source_dir "$cc_source" 2>/dev/null || true
  state_set connect_package_dir "$(_local_connect_path "$cc_package_dir")" 2>/dev/null || true
  state_set connect_runtime_dir "$cc_runtime_dir_local" 2>/dev/null || true
  state_set connect_config "$cc_config_local" 2>/dev/null || true
  state_set connect_binary "$cc_binary_local" 2>/dev/null || true
  state_set connect_data_dir "$cc_data_local" 2>/dev/null || true
  state_set connect_admin_from "$admin_from" 2>/dev/null || true
  state_set connect_matrix_session_file "$cc_session_local" 2>/dev/null || true
  state_set connect_matrix_user "$matrix_user" 2>/dev/null || true
  state_set connect_matrix_device "$matrix_device" 2>/dev/null || true
  state_set connect_matrix_homeserver "$matrix_homeserver" 2>/dev/null || true

  if ! install_command=$(_connect_install_command "$cc_binary" "$cc_config" "$service_id" "$service_dir"); then
    phase_set S6_WIRE_LOCAL failed "dirextalk-connect recommendation rendering failed"
    return 1
  fi
  skill_path=$(_agent_skill_install_path "$runtime")
  global_skill_path=$(_agent_global_skill_install_path "$runtime")
  state_set agent_runtime "$runtime" 2>/dev/null || true
  state_set connect_install_policy "$install_policy" 2>/dev/null || true
  state_set connect_install_mode "$install_mode" 2>/dev/null || true
  state_set connect_install_command "$install_command" 2>/dev/null || true
  state_set mcp_install_policy "$install_policy" 2>/dev/null || true
  state_set agent_skill_install_path "$skill_path" 2>/dev/null || true
  state_set agent_global_skill_install_path "$global_skill_path" 2>/dev/null || true
  state_set dirextalk_agent_bridge "dirextalk-connect" 2>/dev/null || true
  _print_connect_guidance "$runtime" "$asurl" "$node_cred_local" "$install_policy" "$install_mode" "$install_command" "$node_id" "$cc_config_local" "$cc_binary_local" "$cc_agent" "$cc_agent_cmd" "$service_id"
  _print_mcp_guidance "$runtime" "$service_id" "$mcp_server_name" "$node_cred_local" "$mcp_dir_local" "$mcp_selected_config_type" "$mcp_selected_config_local" "$mcp_install_command" "$mcp_doctor_command" "$service_dir" "$mcp_endpoint_url"
  if ! _maybe_auto_install_agent "$install_policy" "$runtime" "$cc_agent" "$service_dir" "$cc_config" "$cc_binary" "$service_id"; then
    phase_set S6_WIRE_LOCAL failed "dirextalk-connect auto install/startup was not verified; check daemon logs"
    warn "Inspect the service-scoped daemon logs with the native path recorded in connect_binary and service name $service_id."
    return 1
  fi
  if ! _maybe_auto_install_mcp "$install_policy" "$runtime" "$mcp_server_name" "$node_cred" "$node_id" "$service_dir"; then
    phase_set S6_WIRE_LOCAL failed "MCP enrollment or capability handling failed"
    return 1
  fi

  phase_set S6_WIRE_LOCAL done "credentials.json written;node_id=$node_id;service_id=$service_id;runtime=$runtime;install_policy=$install_policy;install_mode=$install_mode;connect_config=$cc_config_local;mcp_config_dir=$mcp_dir_local;connect_agent=$cc_agent"
  return 0
}
