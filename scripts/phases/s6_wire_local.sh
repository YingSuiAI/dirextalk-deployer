#!/usr/bin/env bash
# S6 WIRE_LOCAL_CLIENT - write service-scoped credentials and direxio-connect env.
#
#   ① ~/.direxio/nodes/<service_id>/credentials.json
#   ② ~/.direxio/nodes/<service_id>/env
#   ③ direxio-connect Matrix config and install guidance for the detected agent runtime
#   ④ MCP client snippets for Codex/OpenClaw/Hermes under the service directory
#
# Tokens change on every rebuild, so local credentials and direxio-connect env must be refreshed.

S6_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$S6_DIR/../lib/paths.sh"
# shellcheck disable=SC1090
source "$S6_DIR/../lib/local-paths.sh"
# S6 local bridge paths honor DIREXIO_LOCAL_PATH_STYLE through local-paths.sh.

_direxio_home() {
  direxio_home
}

_direxio_service_id() {
  direxio_service_id "$1"
}

_direxio_service_dir() {
  direxio_service_dir "$1"
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
    fail "direxio-connect agent must be one of: $(_connect_supported_agents_csv)."
    return 1
  }
  printf '%s\n' "$agent"
}

_detect_agent_runtime() {
  local active_runtime explicit_agent home_runtime
  if [ -n "${DIREXIO_AGENT_PLATFORM:-}" ] && [ "${DIREXIO_AGENT_PLATFORM:-}" != "auto" ]; then
    _validate_agent_platform "$DIREXIO_AGENT_PLATFORM"
    printf '%s\n' "$DIREXIO_AGENT_PLATFORM"
    return 0
  fi
  if [ -n "${DIREXIO_CONNECT_AGENT:-}" ]; then
    explicit_agent=$(_validate_connect_agent "$DIREXIO_CONNECT_AGENT")
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
  [ "${DIREXIO_AGENT_DETECT_PROCESS:-1}" != "0" ] || return 1
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
      fail "DIREXIO_AGENT_PLATFORM must be auto, a direxio-connect agent ($(_connect_supported_agents_csv)), openclaw, hermes, generic, or unknown."
      ;;
  esac
}

_connect_install_policy() {
  local policy=${DIREXIO_AGENT_INSTALL:-auto}
  case "$policy" in
    skip|recommend|auto) printf '%s\n' "$policy" ;;
    *) fail "DIREXIO_AGENT_INSTALL must be skip, recommend, or auto." ;;
  esac
}

_connect_install_mode() {
  local runtime=$1 mode=${DIREXIO_AGENT_INSTALL_MODE:-recommended}
  case "$mode" in
    recommended)
      printf 'direxio-connect\n'
      ;;
    direxio-connect) printf '%s\n' "$mode" ;;
    *) fail "DIREXIO_AGENT_INSTALL_MODE must be recommended or direxio-connect." ;;
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

_connect_agent_type() {
  local runtime=$1 explicit=${DIREXIO_CONNECT_AGENT:-}
  if [ -n "$explicit" ]; then
    _validate_connect_agent "$explicit"
    return 0
  fi
  case "$runtime" in
    openclaw|hermes) printf 'acp\n'; return 0 ;;
  esac
  _validate_connect_agent "$runtime"
}

_connect_agent_command() {
  local agent runtime raw_key var value
  runtime=${2:-$1}
  agent=$(_connect_agent_alias "$1" 2>/dev/null || printf '%s\n' "$1")
  if [ -n "${DIREXIO_CONNECT_AGENT_CMD:-}" ]; then
    printf '%s\n' "$DIREXIO_CONNECT_AGENT_CMD"
    return 0
  fi
  if [ "$runtime" = "hermes" ] && [ "$agent" = "acp" ]; then
    _local_connect_path "${DIREXIO_HERMES_ACP_ADAPTER_COMMAND:-${DIREXIO_CONNECT_BIN:-direxio-connect}}"
    return 0
  fi
  for raw_key in $(_connect_runtime_command_aliases "$runtime") "$agent" $(_connect_agent_command_aliases "$agent"); do
    var="DIREXIO_$(printf '%s' "$raw_key" | tr '[:lower:]-' '[:upper:]_')_COMMAND"
    value=$(printenv "$var" 2>/dev/null || true)
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  case "$runtime" in
    openclaw|hermes) printf '%s\n' "$runtime" ;;
  esac
}

_connect_runtime_command_aliases() {
  case "$1" in
    openclaw) printf '%s\n' openclaw ;;
    hermes) printf '%s\n' hermes ;;
  esac
}

_connect_agent_command_aliases() {
  case "$1" in
    claudecode) printf '%s\n' claude-code claude ;;
    opencode) printf '%s\n' open-code ;;
    antigravity) printf '%s\n' agy ;;
    qoder) printf '%s\n' qodercli ;;
  esac
}

_connect_repo() {
  printf '%s\n' "${DIREXIO_CONNECT_REPO:-https://github.com/YingSuiAI/direxio-connect.git}"
}

_connect_npm_package() {
  printf '%s\n' "${DIREXIO_CONNECT_NPM_PACKAGE:-direxio-connent@latest}"
}

_connect_ref() {
  printf '%s\n' "${DIREXIO_CONNECT_REF:-main}"
}

_connect_source_dir() {
  local service_dir=$1
  printf '%s\n' "${DIREXIO_CONNECT_DIR:-$service_dir/direxio-connect-src}"
}

_connect_runtime_dir() {
  local service_dir=$1
  printf '%s/direxio-connect\n' "$service_dir"
}

_agent_workspace() {
  local service_dir=$1
  if [ -n "${DIREXIO_AGENT_WORKSPACE:-}" ]; then
    printf '%s\n' "$DIREXIO_AGENT_WORKSPACE"
    return 0
  fi
  if [ -n "${DIREXIO_AGENT_WORKSPACE_WINDOWS:-}" ]; then
    printf '%s\n' "$DIREXIO_AGENT_WORKSPACE_WINDOWS"
    return 0
  fi
  printf '%s/workspace\n' "$service_dir"
}

_connect_config_path() {
  local service_dir=$1
  printf '%s/config.toml\n' "$(_connect_runtime_dir "$service_dir")"
}

_mcp_npm_package() {
  printf '%s\n' "${DIREXIO_MCP_NPM_PACKAGE:-direxio-mcp@latest}"
}

_mcp_command() {
  printf '%s\n' "${DIREXIO_MCP_COMMAND:-direxio-mcp}"
}

_mcp_runtime_dir() {
  local service_dir=$1
  printf '%s/mcp\n' "$service_dir"
}

_mcp_codex_config_path() {
  local service_dir=$1
  printf '%s/codex.toml\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_json_config_path() {
  local service_dir=$1
  printf '%s/mcp-servers.json\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_openclaw_config_path() {
  local service_dir=$1
  printf '%s/openclaw.md\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_openclaw_server_config_path() {
  local service_dir=$1
  printf '%s/openclaw-server.json\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_hermes_config_path() {
  local service_dir=$1
  printf '%s/hermes.mcp.json\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_env_file_path() {
  local service_dir=$1
  printf '%s/env\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_readme_path() {
  local service_dir=$1
  printf '%s/README.md\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_server_name() {
  local service_id=${1:-local}
  printf 'direxio-%s\n' "$service_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+//; s/_+$//; s/^$/direxio_local/'
}

_connect_binary_path() {
  local service_dir=$1
  printf '%s\n' "${DIREXIO_CONNECT_BIN:-direxio-connect}"
}

_connect_agent_options_toml() {
  local runtime=${1:-} agent=${2:-} args_toml q_display
  if [ -n "${DIREXIO_CONNECT_AGENT_OPTIONS_TOML:-}" ]; then
    printf '%s\n' "$DIREXIO_CONNECT_AGENT_OPTIONS_TOML"
    return 0
  fi
  case "$runtime:$agent" in
    openclaw:acp)
      args_toml=$(_openclaw_acp_args_toml) || return 1
      q_display=$(_toml_escape "OpenClaw ACP")
      printf 'args = %s\n' "$args_toml"
      printf 'display_name = "%s"\n' "$q_display"
      ;;
    hermes:acp)
      args_toml=$(_hermes_acp_args_toml)
      q_display=$(_toml_escape "Hermes ACP")
      printf 'args = %s\n' "$args_toml"
      printf 'display_name = "%s"\n' "$q_display"
      ;;
  esac
}

_openclaw_acp_args_toml() {
  local url token_file session missing=
  if [ -n "${DIREXIO_OPENCLAW_ACP_ARGS_TOML:-}" ]; then
    printf '%s\n' "$DIREXIO_OPENCLAW_ACP_ARGS_TOML"
    return 0
  fi
  url=${DIREXIO_OPENCLAW_ACP_URL:-}
  token_file=${DIREXIO_OPENCLAW_ACP_TOKEN_FILE:-}
  session=${DIREXIO_OPENCLAW_ACP_SESSION:-}
  if [ -n "$url" ] && [ -n "$token_file" ] && [ -n "$session" ]; then
    token_file=$(_local_connect_path "$token_file")
    _toml_array acp --url "$url" --token-file "$token_file" --session "$session"
    return 0
  fi
  if [ -n "$url" ] || [ -n "$token_file" ]; then
    [ -n "$url" ] || missing="${missing} DIREXIO_OPENCLAW_ACP_URL"
    [ -n "$token_file" ] || missing="${missing} DIREXIO_OPENCLAW_ACP_TOKEN_FILE"
    [ -n "$session" ] || missing="${missing} DIREXIO_OPENCLAW_ACP_SESSION"
    fail "OpenClaw ACP explicit Gateway settings are incomplete:${missing}. Set all of DIREXIO_OPENCLAW_ACP_URL, DIREXIO_OPENCLAW_ACP_TOKEN_FILE, and DIREXIO_OPENCLAW_ACP_SESSION; otherwise leave URL/token-file unset so openclaw acp can auto-detect from its config."
    return 1
  fi
  # Fallback: OpenClaw acp auto-discovers gateway from ~/.openclaw/openclaw.json.
  warn "OpenClaw ACP: Gateway URL/token-file not set; using session '${session:-agent:main:main}' and letting openclaw acp auto-detect the Gateway from its config."
  _toml_array acp --session "${session:-agent:main:main}"
}

_hermes_acp_args_toml() {
  local hermes_cmd
  hermes_cmd=${DIREXIO_HERMES_COMMAND:-hermes}
  hermes_cmd=$(_local_connect_path "$hermes_cmd")
  if [ -n "${DIREXIO_HERMES_ACP_ARGS_TOML:-}" ]; then
    _toml_array_prepend "$DIREXIO_HERMES_ACP_ARGS_TOML" hermes-acp-adapter -- "$hermes_cmd"
    return 0
  fi
  _toml_array hermes-acp-adapter -- "$hermes_cmd" acp
}

_toml_array() {
  local first=1 value q_value
  printf '['
  for value in "$@"; do
    q_value=$(_toml_escape "$value")
    if [ "$first" -eq 0 ]; then
      printf ', '
    fi
    printf '"%s"' "$q_value"
    first=0
  done
  printf ']\n'
}

_toml_array_prepend() {
  local suffix_toml=$1 prefix_toml suffix_inner
  shift
  prefix_toml=$(_toml_array "$@")
  suffix_inner=$(printf '%s' "$suffix_toml" | sed -E 's/^[[:space:]]*\[[[:space:]]*//; s/[[:space:]]*\][[:space:]]*$//')
  if [ -z "$suffix_inner" ]; then
    printf '%s\n' "$prefix_toml"
    return 0
  fi
  printf '%s, %s]\n' "${prefix_toml%]}" "$suffix_inner"
}

_toml_has_key() {
  local toml=$1 key=$2
  printf '%s\n' "$toml" | grep -Eq "^[[:space:]]*${key}[[:space:]]*="
}

_connect_default_agent_options_toml() {
  local agent=$1 custom_toml=${2:-}
  case "$agent" in
    codex)
      _toml_has_key "$custom_toml" backend || printf 'backend = "app_server"\n'
      _toml_has_key "$custom_toml" app_server_url || printf 'app_server_url = "stdio"\n'
      _toml_has_key "$custom_toml" mode || printf 'mode = "yolo"\n'
      ;;
  esac
}

_toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_powershell_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
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
  enabled=$(_lower "${DIREXIO_SPEECH_ENABLED:-auto}")
  case "$enabled" in
    0|false|off|no|disabled) return 0 ;;
    ""|1|true|on|yes|auto|enabled) ;;
    *) fail "DIREXIO_SPEECH_ENABLED must be auto, true, or false." ;;
  esac

  provider=$(_lower "${DIREXIO_SPEECH_PROVIDER:-openai}")
  language=${DIREXIO_SPEECH_LANGUAGE:-zh}
  case "$provider" in
    openai)
      api_key=$(_env_first DIREXIO_SPEECH_OPENAI_API_KEY DIREXIO_SPEECH_API_KEY OPENAI_API_KEY)
      base_url=$(_env_first DIREXIO_SPEECH_OPENAI_BASE_URL DIREXIO_SPEECH_BASE_URL OPENAI_BASE_URL)
      model=$(_env_first DIREXIO_SPEECH_OPENAI_MODEL DIREXIO_SPEECH_MODEL)
      ;;
    groq)
      api_key=$(_env_first DIREXIO_SPEECH_GROQ_API_KEY DIREXIO_SPEECH_API_KEY GROQ_API_KEY)
      model=$(_env_first DIREXIO_SPEECH_GROQ_MODEL DIREXIO_SPEECH_MODEL)
      ;;
    qwen)
      api_key=$(_env_first DIREXIO_SPEECH_QWEN_API_KEY DIREXIO_SPEECH_API_KEY DASHSCOPE_API_KEY DASH_SCOPE_API_KEY)
      base_url=$(_env_first DIREXIO_SPEECH_QWEN_BASE_URL DIREXIO_SPEECH_BASE_URL)
      model=$(_env_first DIREXIO_SPEECH_QWEN_MODEL DIREXIO_SPEECH_MODEL)
      ;;
    gemini)
      api_key=$(_env_first DIREXIO_SPEECH_GEMINI_API_KEY DIREXIO_SPEECH_API_KEY GEMINI_API_KEY GOOGLE_API_KEY)
      model=$(_env_first DIREXIO_SPEECH_GEMINI_MODEL DIREXIO_SPEECH_MODEL)
      ;;
    *) fail "DIREXIO_SPEECH_PROVIDER must be openai, groq, qwen, or gemini." ;;
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
  direxio_local_path_style
}

_local_connect_path() {
  direxio_normalize_local_path "$1"
}

_mcp_install_command() {
  printf 'npm install -g %q' "$(_mcp_npm_package)"
}

_mcp_doctor_command() {
  local credentials_file=$1 node_id=${2:-}
  printf 'DIREXIO_CREDENTIALS_FILE=%q' "$(_local_connect_path "$credentials_file")"
  if [ -n "$node_id" ]; then
    printf ' DIREXIO_AGENT_NODE_ID=%q' "$node_id"
  fi
  printf ' %q doctor --json\n' "$(_mcp_command)"
}

_write_mcp_json_config() {
  local path=$1 server_name=$2 command=$3 credentials_file=$4 node_id=${5:-}
  mkdir -p "$(dirname "$path")"
  umask 077
  json_build mcp-json-config "$server_name" "$command" "$credentials_file" "$node_id" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

_write_mcp_openclaw_server_config() {
  local path=$1 command=$2 credentials_file=$3 node_id=${4:-}
  mkdir -p "$(dirname "$path")"
  umask 077
  json_build mcp-openclaw-server-config "$command" "$credentials_file" "$node_id" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

_write_mcp_config_artifacts() {
  local service_id=$1 service_dir=$2 credentials_file=$3 node_id=${4:-}
  local mcp_dir server_name command credentials_local q_server q_command q_credentials q_node
  local codex_config json_config openclaw_config openclaw_server_config hermes_config env_file readme
  local openclaw_server_config_local openclaw_server_config_bash openclaw_server_config_ps
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  server_name=$(_mcp_server_name "$service_id")
  command=$(_mcp_command)
  credentials_local=$(_local_connect_path "$credentials_file")
  q_server=$(_toml_escape "$server_name")
  q_command=$(_toml_escape "$command")
  q_credentials=$(_toml_escape "$credentials_local")
  q_node=$(_toml_escape "$node_id")
  codex_config=$(_mcp_codex_config_path "$service_dir")
  json_config=$(_mcp_json_config_path "$service_dir")
  openclaw_config=$(_mcp_openclaw_config_path "$service_dir")
  openclaw_server_config=$(_mcp_openclaw_server_config_path "$service_dir")
  hermes_config=$(_mcp_hermes_config_path "$service_dir")
  env_file=$(_mcp_env_file_path "$service_dir")
  readme=$(_mcp_readme_path "$service_dir")

  mkdir -p "$mcp_dir"
  umask 077
  cat > "$codex_config" <<EOF
[mcp_servers."$q_server"]
command = "$q_command"
env = { DIREXIO_CREDENTIALS_FILE = "$q_credentials", DIREXIO_AGENT_NODE_ID = "$q_node" }
EOF
  chmod 600 "$codex_config" 2>/dev/null || true

  rm -f "$mcp_dir/openclaw.mcp.json"
  _write_mcp_json_config "$json_config" "$server_name" "$command" "$credentials_local" "$node_id"
  _write_mcp_openclaw_server_config "$openclaw_server_config" "$command" "$credentials_local" "$node_id"
  _write_mcp_json_config "$hermes_config" "$server_name" "$command" "$credentials_local" "$node_id"

  openclaw_server_config_local=$(_local_connect_path "$openclaw_server_config")
  openclaw_server_config_bash=$(printf '%q' "$openclaw_server_config_local")
  openclaw_server_config_ps=$(_powershell_single_quote "$openclaw_server_config_local")
  cat > "$openclaw_config" <<EOF
# OpenClaw MCP Setup

OpenClaw must manage MCP servers through its own CLI/schema. Do not paste Codex/Hermes mcpServers snippets, or any raw top-level mcp block from this directory, into openclaw.json.

Server object for openclaw mcp set:

$openclaw_server_config_local

POSIX/Git Bash:

\`\`\`bash
openclaw mcp set $server_name "\$(cat $openclaw_server_config_bash)"
openclaw mcp doctor
openclaw mcp reload
\`\`\`

PowerShell:

\`\`\`powershell
openclaw mcp set $server_name (Get-Content -Raw -LiteralPath '$openclaw_server_config_ps')
openclaw mcp doctor
openclaw mcp reload
\`\`\`

This writes the server under OpenClaw's mcp.servers schema after OpenClaw validates it.
EOF
  chmod 644 "$openclaw_config" 2>/dev/null || true

  {
    printf 'export DIREXIO_CREDENTIALS_FILE=%q\n' "$credentials_local"
    [ -n "$node_id" ] && printf 'export DIREXIO_AGENT_NODE_ID=%q\n' "$node_id"
  } > "$env_file"
  chmod 600 "$env_file" 2>/dev/null || true

  cat > "$readme" <<EOF
# Direxio MCP Config

Install the local MCP package:

\`\`\`bash
$(_mcp_install_command)
\`\`\`

Check this service's MCP credentials:

\`\`\`bash
$(_mcp_doctor_command "$credentials_file" "$node_id")
\`\`\`

Config snippets:

- Codex TOML: $(_local_connect_path "$codex_config")
- OpenClaw CLI setup: $(_local_connect_path "$openclaw_config")
- Hermes JSON: $(_local_connect_path "$hermes_config")
- Generic JSON: $(_local_connect_path "$json_config")
EOF
  chmod 644 "$readme" 2>/dev/null || true
}

_create_connect_matrix_session() {
  local asurl=$1 agent_auth_token=$2 device_id=$3 out=$4 body code http_body
  local max_attempts interval max_interval attempt preview sleep_for
  body=$(json_build matrix-session-create "$device_id")
  max_attempts=${DIREXIO_MATRIX_SESSION_CREATE_MAX:-12}
  interval=${DIREXIO_MATRIX_SESSION_RETRY_INTERVAL:-2}
  max_interval=${DIREXIO_MATRIX_SESSION_RETRY_MAX_INTERVAL:-10}
  attempt=1
  sleep_for=$interval
  while [ "$attempt" -le "$max_attempts" ]; do
    http_body=$(mktemp)
    code=$(curl -sk \
      --connect-timeout "${DIREXIO_MATRIX_SESSION_CURL_CONNECT_TIMEOUT:-10}" \
      --max-time "${DIREXIO_MATRIX_SESSION_CURL_MAX_TIME:-20}" \
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

_write_connect_config() {
  local config_path=$1 data_dir=$2 project=$3 agent=$4 workspace=$5 homeserver=$6 matrix_token=$7 matrix_user=$8 room_id=$9 admin_from=${10:-} agent_cmd=${11:-} agent_options_toml=${12:-}
  local q_data q_project q_agent q_workspace q_homeserver q_token q_user q_room q_admin_from q_agent_cmd speech_toml default_agent_options_toml
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
  speech_toml=$(_connect_speech_config_toml)
  default_agent_options_toml=$(_connect_default_agent_options_toml "$agent" "$agent_options_toml")
  umask 077
  cat > "$config_path" <<EOF
language = "zh"
data_dir = "$q_data"
EOF
  if [ -n "$speech_toml" ]; then
    printf '\n%s\n' "$speech_toml" >> "$config_path"
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
  local binary=$1 config=$2 service_name=$3
  [ -n "$service_name" ] || service_name=direxio-connect
  printf 'npm install -g %q && %q daemon install --config %q --service-name %q --force' "$(_connect_npm_package)" "$binary" "$(_local_connect_path "$config")" "$service_name"
}

_connect_daemon_is_running() {
  local binary=$1 service_name=$2 status
  [ -n "$service_name" ] || service_name=direxio-connect
  status=$("$binary" daemon status --service-name "$service_name" 2>/dev/null || true)
  printf '%s\n' "$status" | grep -Eq 'Status:[[:space:]]*Running'
}

_connect_daemon_has_agent_startup_error() {
  local binary=$1 service_name=$2 logs
  [ -n "$service_name" ] || service_name=direxio-connect
  logs=$("$binary" daemon logs --service-name "$service_name" -n "${DIREXIO_CONNECT_LOG_TAIL_LINES:-120}" 2>/dev/null || true)
  printf '%s\n' "$logs" | grep -Eiq 'ACP_SESSION_INIT_FAILED|ACP metadata is missing|Recreate this ACP session'
}

_maybe_auto_install_connect() {
  local policy=$1 runtime=$2 cc_agent=$3 service_dir=$4 config_path=$5 binary=$6 service_name=$7
  local repo ref src commit config_arg
  [ -n "$service_name" ] || service_name=$(basename "$service_dir")
  if [ "$policy" != "auto" ]; then
    state_set connect_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  config_arg=$(_local_connect_path "$config_path")
  if [ "${DIREXIO_CONNECT_INSTALL_FROM:-npm}" != "source" ]; then
    if ! command -v npm >/dev/null 2>&1; then
      warn "DIREXIO_AGENT_INSTALL=auto requested, but npm is not on PATH. Install Node.js or set DIREXIO_CONNECT_INSTALL_FROM=source."
      state_set connect_install_status "npm_missing" 2>/dev/null || true
      return 0
    fi
    if npm install -g "$(_connect_npm_package)" && "$binary" daemon install --config "$config_arg" --service-name "$service_name" --force; then
      if ! _connect_daemon_is_running "$binary" "$service_name"; then
        state_set connect_install_status "install_failed" 2>/dev/null || true
        warn "direxio-connect daemon install returned success, but daemon status is not Running. Check the local agent command and direxio-connect logs."
        return 0
      fi
      if _connect_daemon_has_agent_startup_error "$binary" "$service_name"; then
        state_set connect_install_status "install_failed" 2>/dev/null || true
        warn "direxio-connect daemon is Running, but logs show ACP session initialization failed. Check OpenClaw ACP URL, token-file, and session."
        return 0
      fi
      state_set connect_install_status "installed" 2>/dev/null || true
      ok "direxio-connect daemon installed from npm for $runtime using Matrix room bridge."
    else
      state_set connect_install_status "install_failed" 2>/dev/null || true
      warn "direxio-connect npm install or daemon install failed. Config is available for manual start."
    fi
    return 0
  fi

  repo=$(_connect_repo)
  ref=$(_connect_ref)
  src=$(_connect_source_dir "$service_dir")
  if ! command -v git >/dev/null 2>&1 || ! command -v go >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    warn "DIREXIO_CONNECT_INSTALL_FROM=source requested, but git, go, and make are required to build direxio-connect from source."
    state_set connect_install_status "build_tool_missing" 2>/dev/null || true
    return 0
  fi
  if [ ! -d "$src/.git" ]; then
    mkdir -p "$(dirname "$src")"
    if ! git clone "$repo" "$src"; then
      state_set connect_install_status "clone_failed" 2>/dev/null || true
      warn "direxio-connect clone failed from $repo"
      return 0
    fi
  fi
  if ! git -C "$src" fetch --all --tags --prune; then
    state_set connect_install_status "fetch_failed" 2>/dev/null || true
    warn "direxio-connect fetch failed in $src"
    return 0
  fi
  if ! git -C "$src" checkout "$ref"; then
    state_set connect_install_status "checkout_failed" 2>/dev/null || true
    warn "direxio-connect checkout failed for ref $ref"
    return 0
  fi
  commit=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)
  state_set connect_commit "$commit" 2>/dev/null || true
  if ! (cd "$src" && AGENTS="$cc_agent" PLATFORMS_INCLUDE=matrix NO_WEB=1 make build-noweb); then
    state_set connect_install_status "build_failed" 2>/dev/null || true
    warn "direxio-connect build failed for runtime=$runtime agent=$cc_agent"
    return 0
  fi
  binary="$(_connect_runtime_dir "$service_dir")/bin/direxio-connect"
  mkdir -p "$(dirname "$binary")"
  if ! cp "$src/direxio-connect" "$binary" 2>/dev/null && ! cp "$src/direxio-connect.exe" "$binary" 2>/dev/null; then
    state_set connect_install_status "binary_copy_failed" 2>/dev/null || true
    warn "direxio-connect binary was not found after build in $src"
    return 0
  fi
  chmod 700 "$binary" 2>/dev/null || true
  if "$binary" daemon install --config "$config_arg" --service-name "$service_name" --force; then
    if ! _connect_daemon_is_running "$binary" "$service_name"; then
      state_set connect_install_status "install_failed" 2>/dev/null || true
      warn "direxio-connect daemon install returned success, but daemon status is not Running. Check the local agent command and direxio-connect logs."
      return 0
    fi
    if _connect_daemon_has_agent_startup_error "$binary" "$service_name"; then
      state_set connect_install_status "install_failed" 2>/dev/null || true
      warn "direxio-connect daemon is Running, but logs show ACP session initialization failed. Check OpenClaw ACP URL, token-file, and session."
      return 0
    fi
    state_set connect_install_status "installed" 2>/dev/null || true
    ok "direxio-connect daemon installed for $runtime using Matrix room bridge."
  else
    state_set connect_install_status "install_failed" 2>/dev/null || true
    warn "direxio-connect daemon install failed. Config and binary are available for manual start."
  fi
}

_maybe_auto_install_mcp() {
  local policy=$1
  if [ "$policy" != "auto" ]; then
    state_set mcp_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    warn "DIREXIO_AGENT_INSTALL=auto requested, but npm is not on PATH. Install Node.js to install direxio-mcp automatically."
    state_set mcp_install_status "npm_missing" 2>/dev/null || true
    return 0
  fi
  if npm install -g "$(_mcp_npm_package)"; then
    state_set mcp_install_status "installed" 2>/dev/null || true
    ok "direxio-mcp installed from npm."
  else
    state_set mcp_install_status "install_failed" 2>/dev/null || true
    warn "direxio-mcp npm install failed. MCP config artifacts and install command are available for manual recovery."
  fi
}

_agent_skill_install_path() {
  local runtime=$1
  case "$runtime" in
    acp) printf 'PROJECT_ROOT/.agents/skills/direxio-deployer\n' ;;
    antigravity) printf 'PROJECT_ROOT/.antigravity/skills/direxio-deployer\n' ;;
    codex) printf 'PROJECT_ROOT/.codex/skills/direxio-deployer\n' ;;
    claude|claude-code|claudecode) printf 'PROJECT_ROOT/.claude/skills/direxio-deployer\n' ;;
    devin) printf 'PROJECT_ROOT/.devin/skills/direxio-deployer\n' ;;
    iflow) printf 'PROJECT_ROOT/.iflow/skills/direxio-deployer\n' ;;
    kimi) printf 'PROJECT_ROOT/.kimi/skills/direxio-deployer\n' ;;
    opencode) printf 'PROJECT_ROOT/.opencode/skills/direxio-deployer\n' ;;
    pi) printf 'PROJECT_ROOT/.pi/agent/skills/direxio-deployer\n' ;;
    qoder) printf 'PROJECT_ROOT/.qoder/skills/direxio-deployer\n' ;;
    reasonix) printf 'PROJECT_ROOT/.reasonix/skills/direxio-deployer\n' ;;
    tmux) printf 'PROJECT_ROOT/.agent/skills/direxio-deployer\n' ;;
    gemini) printf 'PROJECT_ROOT/.gemini/skills/direxio-deployer\n' ;;
    cursor) printf 'PROJECT_ROOT/.cursor/skills/direxio-deployer\n' ;;
    copilot) printf 'PROJECT_ROOT/.github/copilot/skills/direxio-deployer\n' ;;
    openclaw) printf 'PROJECT_ROOT/.openclaw/skills/direxio-deployer\n' ;;
    hermes) printf 'PROJECT_ROOT/.hermes/skills/direxio-deployer\n' ;;
    generic|unknown|*) printf 'PROJECT_ROOT/.agent/skills/direxio-deployer\n' ;;
  esac
}

_agent_global_skill_install_path() {
  local runtime=$1
  case "$runtime" in
    acp) printf '$HOME/.agents/skills/direxio-deployer\n' ;;
    antigravity) printf '${ANTIGRAVITY_HOME:-$HOME/.antigravity}/skills/direxio-deployer\n' ;;
    codex) printf '${CODEX_HOME:-$HOME/.codex}/skills/direxio-deployer\n' ;;
    claude|claude-code|claudecode) printf '${CLAUDE_HOME:-${CLAUDECODE_HOME:-$HOME/.claude}}/skills/direxio-deployer\n' ;;
    devin) printf '${DEVIN_HOME:-$HOME/.devin}/skills/direxio-deployer\n' ;;
    iflow) printf '${IFLOW_HOME:-$HOME/.iflow}/skills/direxio-deployer\n' ;;
    kimi) printf '${KIMI_HOME:-$HOME/.kimi}/skills/direxio-deployer\n' ;;
    opencode) printf '${OPENCODE_HOME:-$HOME/.opencode}/skills/direxio-deployer\n' ;;
    pi) printf '${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/skills/direxio-deployer\n' ;;
    qoder) printf '${QODER_HOME:-$HOME/.qoder}/skills/direxio-deployer\n' ;;
    reasonix) printf '${REASONIX_HOME:-$HOME/.reasonix}/skills/direxio-deployer\n' ;;
    tmux) printf '$HOME/.agent/skills/direxio-deployer\n' ;;
    gemini) printf '${GEMINI_HOME:-$HOME/.gemini}/skills/direxio-deployer\n' ;;
    cursor) printf '${CURSOR_HOME:-$HOME/.cursor}/skills/direxio-deployer\n' ;;
    copilot) printf '$HOME/.github/copilot/skills/direxio-deployer\n' ;;
    openclaw) printf '${OPENCLAW_HOME:-$HOME/.openclaw}/skills/direxio-deployer\n' ;;
    hermes) printf '${HERMES_HOME:-$HOME/.hermes}/skills/direxio-deployer\n' ;;
    generic|unknown|*) printf '$HOME/.agent/skills/direxio-deployer\n' ;;
  esac
}

_connect_install_command() {
  local binary=$1 config=$2 service_name=$3
  _connect_daemon_install_command "$binary" "$config" "$service_name"
}

_print_runtime_install_summary() {
  local runtime=$1 mode=$2 config_path=$3 binary=$4 cc_agent=$5 cc_agent_cmd=${6:-} service_name=${7:-}
  cat >&2 <<EOF
Recommended direxio-connect install:
  runtime:        $runtime
  direxio-connect agent: $cc_agent
  agent command:  ${cc_agent_cmd:-default PATH lookup}
  mode:           $mode
  service name:   $service_name
  config:         $config_path
  binary:         $binary
  daemon install: $(_connect_daemon_install_command "$binary" "$config_path" "$service_name")
EOF
}

_maybe_auto_install_agent() {
  _maybe_auto_install_connect "$@"
}

_write_agent_env_file() {
  local asurl=$1 token=$2 access_token=$3 agent_room_id=$4 envfile=${5:-"$(_direxio_home)/env"} node_id=${6:-}
  mkdir -p "$(dirname "$envfile")"
  umask 077
  {
    [ -n "$node_id" ] && printf 'export DIREXIO_AGENT_NODE_ID=%q\n' "$node_id"
    printf 'export DIREXIO_DOMAIN=%q\n' "$asurl"
    printf 'export DIREXIO_AGENT_TOKEN=%q\n' "$token"
    printf 'export DIREXIO_AGENT_ROOM_ID=%q\n' "$agent_room_id"
  } > "$envfile"
  chmod 600 "$envfile"
  echo "$envfile"
}

_agent_node_id() {
  local runtime=$1 domain=$2 room=$3 explicit host digest raw
  explicit=${DIREXIO_AGENT_NODE_ID:-}
  host=${domain#http://}
  host=${host#https://}
  host=${host%%/*}
  host=${host%%:*}
  if [ -n "$explicit" ] && { [ "${DIREXIO_AGENT_NODE_ID_FORCE:-}" = "1" ] || _agent_node_id_matches_host "$explicit" "$host"; }; then
    raw=$explicit
  else
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(printf '%s\n%s\n' "$domain" "$room" | sha256sum | awk '{print substr($1,1,10)}')
    else
      digest=$(printf '%s\n%s\n' "$domain" "$room" | shasum -a 256 | awk '{print substr($1,1,10)}')
    fi
    raw="${runtime:-agent}-${host:-direxio}-$digest"
  fi
  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/^$/direxio-agent/'
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

_persist_agent_env() {
  local asurl=$1 token=$2 access_token=$3 agent_room_id=$4 envfile=${5:-"$(_direxio_home)/env"} node_id=${6:-}
  envfile=$(_write_agent_env_file "$asurl" "$token" "$access_token" "$agent_room_id" "$envfile" "$node_id")
  [ -n "$node_id" ] && export DIREXIO_AGENT_NODE_ID="$node_id"
  export DIREXIO_DOMAIN="$asurl"
  export DIREXIO_AGENT_TOKEN="$token"
  export DIREXIO_AGENT_ROOM_ID="$agent_room_id"
  ok "Persisted Direxio direxio-connect env vars via $envfile."
  echo "$envfile"
}

_print_connect_guidance() {
  local runtime=$1 asurl=$2 cred=$3 envfile=$4 policy=$5 mode=$6 install_command=$7 node_id=$8 cc_config=$9 cc_binary=${10} cc_agent=${11} cc_agent_cmd=${12:-} service_name=${13:-}
  local skill_path global_skill_path
  skill_path=$(_agent_skill_install_path "$runtime")
  global_skill_path=$(_agent_global_skill_install_path "$runtime")
  if [ "$policy" = "skip" ]; then
    warn "Direxio direxio-connect install guidance skipped by DIREXIO_AGENT_INSTALL=skip."
    return 0
  fi
  warn "Direxio direxio-connect install policy: $policy; platform=$runtime; mode=$mode."
  cat >&2 <<EOF
Detected agent runtime: $runtime
direxio-connect agent:       $cc_agent
Local env file:         $envfile
Credential file:        $cred
direxio-connect config:      $cc_config
direxio-connect binary:      $cc_binary
direxio-connect agent cmd:   ${cc_agent_cmd:-default PATH lookup}
direxio-connect service:     $service_name
Install command:        $install_command
Project skill clone:    $skill_path
Global skill fallback:  $global_skill_path
Env keys:               DIREXIO_DOMAIN, DIREXIO_AGENT_TOKEN, DIREXIO_AGENT_ROOM_ID, DIREXIO_AGENT_NODE_ID

direxio-connect will use Matrix Client-Server sync as @agent:<server> and is restricted to DIREXIO_AGENT_ROOM_ID.
It talks directly to the Direxio homeserver for the agents room conversation.
EOF
  _print_runtime_install_summary "$runtime" "$mode" "$cc_config" "$cc_binary" "$cc_agent" "$cc_agent_cmd" "$service_name"
}

_print_mcp_guidance() {
  local runtime=$1 service_name=$2 server_name=$3 credentials_file=$4 config_dir=$5 codex_config=$6 openclaw_config=$7 hermes_config=$8 install_command=$9 doctor_command=${10}
  warn "Direxio MCP artifacts written for runtime=$runtime service=$service_name."
  cat >&2 <<EOF
MCP server name:        $server_name
MCP config directory:   $config_dir
MCP credential file:    $credentials_file
MCP install command:    $install_command
MCP doctor command:     $doctor_command
Codex TOML snippet:     $codex_config
OpenClaw CLI setup:    $openclaw_config
Hermes JSON snippet:   $hermes_config

These artifacts use direxio-mcp over stdio and point to the service-scoped DIREXIO_CREDENTIALS_FILE.
For OpenClaw, use the CLI setup note so OpenClaw validates and writes mcp.servers itself; do not paste MCP JSON into openclaw.json.
EOF
}

run_phase() {
  phase_set S6_WIRE_LOCAL in_progress "writing credentials and direxio-connect Matrix bridge config"
  local domain asurl token access_token password agent_room_id envfile runtime install_policy install_mode install_command
  local node_id service_dir node_cred workspace workspace_local service_id cc_agent cc_agent_cmd cc_agent_options_toml cc_runtime_dir cc_config cc_config_local cc_data cc_data_local cc_binary cc_session cc_source
  local mcp_dir mcp_dir_local mcp_server_name mcp_install_command mcp_doctor_command mcp_codex_config mcp_openclaw_config mcp_hermes_config mcp_json_config mcp_env_file mcp_readme
  local mcp_codex_config_local mcp_openclaw_config_local mcp_hermes_config_local mcp_json_config_local mcp_env_file_local mcp_readme_local node_cred_local
  local matrix_token matrix_user matrix_device matrix_homeserver
  local skill_path global_skill_path
  domain=$(state_get domain)
  asurl=$(state_get as_url)
  token=$(state_get agent_token)
  access_token=$(state_get access_token)
  password=$(state_get password)
  agent_room_id=$(state_get agent_room_id)
  [ -n "$domain" ] && [ -n "$asurl" ] && [ -n "$token" ] || { phase_set S6_WIRE_LOCAL failed "missing domain/as_url/token"; fail "state is missing domain/as_url/agent_token; complete S5 first."; }
  [ -n "$access_token" ] && [ -n "$password" ] || { phase_set S6_WIRE_LOCAL failed "missing bootstrap credentials"; fail "state is missing password/access_token; complete S5 first."; }
  _validate_real_agent_room_id "$agent_room_id"

  runtime=$(_detect_agent_runtime)
  cc_agent=$(_connect_agent_type "$runtime")
  cc_agent_cmd=$(_connect_agent_command "$cc_agent" "$runtime")
  cc_agent_options_toml=$(_connect_agent_options_toml "$runtime" "$cc_agent")
  node_id=$(_agent_node_id "$runtime" "$domain" "$agent_room_id")
  service_id=$(_direxio_service_id "${asurl:-$domain}")
  service_dir=$(_direxio_service_dir "${asurl:-$domain}")
  node_cred="$service_dir/credentials.json"
  envfile="$service_dir/env"
  workspace=$(_agent_workspace "$service_dir")
  admin_from="@owner:$domain"
  cc_runtime_dir=$(_connect_runtime_dir "$service_dir")
  cc_config=$(_connect_config_path "$service_dir")
  cc_config_local=$(_local_connect_path "$cc_config")
  cc_data="$cc_runtime_dir/data"
  cc_data_local=$(_local_connect_path "$cc_data")
  cc_binary=$(_connect_binary_path "$service_dir")
  cc_session="$cc_runtime_dir/matrix-session.json"
  cc_source=$(_connect_source_dir "$service_dir")

  _write_credentials_file "$node_cred" "$domain" "$asurl" "$token" "$password" "$access_token" "$agent_room_id" "$node_id"
  ok "Wrote $node_cred (0600)."
  node_cred_local=$(_local_connect_path "$node_cred")

  _write_mcp_config_artifacts "$service_id" "$service_dir" "$node_cred" "$node_id"
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  mcp_dir_local=$(_local_connect_path "$mcp_dir")
  mcp_server_name=$(_mcp_server_name "$service_id")
  mcp_codex_config=$(_mcp_codex_config_path "$service_dir")
  mcp_openclaw_config=$(_mcp_openclaw_config_path "$service_dir")
  mcp_hermes_config=$(_mcp_hermes_config_path "$service_dir")
  mcp_json_config=$(_mcp_json_config_path "$service_dir")
  mcp_env_file=$(_mcp_env_file_path "$service_dir")
  mcp_readme=$(_mcp_readme_path "$service_dir")
  mcp_codex_config_local=$(_local_connect_path "$mcp_codex_config")
  mcp_openclaw_config_local=$(_local_connect_path "$mcp_openclaw_config")
  mcp_hermes_config_local=$(_local_connect_path "$mcp_hermes_config")
  mcp_json_config_local=$(_local_connect_path "$mcp_json_config")
  mcp_env_file_local=$(_local_connect_path "$mcp_env_file")
  mcp_readme_local=$(_local_connect_path "$mcp_readme")
  mcp_install_command=$(_mcp_install_command)
  mcp_doctor_command=$(_mcp_doctor_command "$node_cred" "$node_id")
  ok "Wrote MCP config snippets under $mcp_dir."

  if ! envfile=$(_persist_agent_env "$asurl" "$token" "$access_token" "$agent_room_id" "$envfile" "$node_id"); then
    phase_set S6_WIRE_LOCAL failed "persistent env write failed"
    fail "failed to persist Direxio direxio-connect env vars."
  fi

  mkdir -p "$workspace"
  mkdir -p "$cc_runtime_dir"
  if ! _create_connect_matrix_session "$asurl" "$token" "DIREXIO_CONNECT_${node_id}" "$cc_session"; then
    phase_set S6_WIRE_LOCAL failed "agent Matrix session creation failed"
    fail "failed to create direxio-connect Matrix session via agent.matrix_session.create."
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
  _write_connect_config "$cc_config" "$cc_data_local" "$node_id" "$cc_agent" "$workspace_local" "$matrix_homeserver" "$matrix_token" "$matrix_user" "$agent_room_id" "$admin_from" "$cc_agent_cmd" "$cc_agent_options_toml"
  ok "Wrote direxio-connect Matrix config $cc_config (0600)."

  state_set agent_env_file "$envfile" 2>/dev/null || true
  state_set agent_node_id "$node_id" 2>/dev/null || true
  state_set agent_service_id "$service_id" 2>/dev/null || true
  state_set agent_service_dir "$service_dir" 2>/dev/null || true
  state_set agent_credentials_file "$node_cred" 2>/dev/null || true
  state_set mcp_npm_package "$(_mcp_npm_package)" 2>/dev/null || true
  state_set mcp_command "$(_mcp_command)" 2>/dev/null || true
  state_set mcp_server_name "$mcp_server_name" 2>/dev/null || true
  state_set mcp_config_dir "$mcp_dir_local" 2>/dev/null || true
  state_set mcp_credentials_file "$node_cred_local" 2>/dev/null || true
  state_set mcp_codex_config "$mcp_codex_config_local" 2>/dev/null || true
  state_set mcp_openclaw_config "$mcp_openclaw_config_local" 2>/dev/null || true
  state_set mcp_hermes_config "$mcp_hermes_config_local" 2>/dev/null || true
  state_set mcp_json_config "$mcp_json_config_local" 2>/dev/null || true
  state_set mcp_env_file "$mcp_env_file_local" 2>/dev/null || true
  state_set mcp_readme "$mcp_readme_local" 2>/dev/null || true
  state_set mcp_install_command "$mcp_install_command" 2>/dev/null || true
  state_set mcp_doctor_command "$mcp_doctor_command" 2>/dev/null || true
  state_set agent_workspace "$workspace" 2>/dev/null || true
  state_set connect_agent "$cc_agent" 2>/dev/null || true
  state_set connect_agent_cmd "$cc_agent_cmd" 2>/dev/null || true
  if [ -n "$cc_agent_options_toml" ]; then
    state_set connect_agent_options_toml_present "true" 2>/dev/null || true
  else
    state_set connect_agent_options_toml_present "false" 2>/dev/null || true
  fi
  state_set connect_npm_package "$(_connect_npm_package)" 2>/dev/null || true
  state_set connect_repo "$(_connect_repo)" 2>/dev/null || true
  state_set connect_ref "$(_connect_ref)" 2>/dev/null || true
  state_set connect_source_dir "$cc_source" 2>/dev/null || true
  state_set connect_runtime_dir "$cc_runtime_dir" 2>/dev/null || true
  state_set connect_config "$cc_config_local" 2>/dev/null || true
  state_set connect_binary "$cc_binary" 2>/dev/null || true
  state_set connect_data_dir "$cc_data_local" 2>/dev/null || true
  state_set connect_admin_from "$admin_from" 2>/dev/null || true
  state_set connect_matrix_session_file "$cc_session" 2>/dev/null || true
  state_set connect_matrix_user "$matrix_user" 2>/dev/null || true
  state_set connect_matrix_device "$matrix_device" 2>/dev/null || true
  state_set connect_matrix_homeserver "$matrix_homeserver" 2>/dev/null || true

  install_policy=$(_connect_install_policy)
  install_mode=$(_connect_install_mode "$runtime")
  install_command=$(_connect_install_command "$cc_binary" "$cc_config" "$service_id")
  skill_path=$(_agent_skill_install_path "$runtime")
  global_skill_path=$(_agent_global_skill_install_path "$runtime")
  state_set agent_runtime "$runtime" 2>/dev/null || true
  state_set connect_install_policy "$install_policy" 2>/dev/null || true
  state_set connect_install_mode "$install_mode" 2>/dev/null || true
  state_set connect_install_command "$install_command" 2>/dev/null || true
  state_set mcp_install_policy "$install_policy" 2>/dev/null || true
  state_set agent_skill_install_path "$skill_path" 2>/dev/null || true
  state_set agent_global_skill_install_path "$global_skill_path" 2>/dev/null || true
  state_set direxio_agent_bridge "direxio-connect" 2>/dev/null || true
  _print_connect_guidance "$runtime" "$asurl" "$node_cred" "$envfile" "$install_policy" "$install_mode" "$install_command" "$node_id" "$cc_config_local" "$cc_binary" "$cc_agent" "$cc_agent_cmd" "$service_id"
  _print_mcp_guidance "$runtime" "$service_id" "$mcp_server_name" "$node_cred_local" "$mcp_dir_local" "$mcp_codex_config_local" "$mcp_openclaw_config_local" "$mcp_hermes_config_local" "$mcp_install_command" "$mcp_doctor_command"
  _maybe_auto_install_agent "$install_policy" "$runtime" "$cc_agent" "$service_dir" "$cc_config" "$cc_binary" "$service_id"
  _maybe_auto_install_mcp "$install_policy"

  phase_set S6_WIRE_LOCAL done "credentials.json written;node_id=$node_id;service_id=$service_id;env_file=$envfile;runtime=$runtime;install_policy=$install_policy;install_mode=$install_mode;connect_config=$cc_config;mcp_config_dir=$mcp_dir;connect_agent=$cc_agent"
  return 0
}
