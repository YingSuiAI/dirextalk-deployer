#!/usr/bin/env bash
# connect-agent-adapters.sh - dirextalk-connect agent backend defaults.
#
# This module hides agent/platform-specific command and TOML option details
# behind the small interface S6 needs.

_connect_agent_type() {
  local runtime=$1 explicit=${DIREXTALK_CONNECT_AGENT:-}
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
  if [ -n "${DIREXTALK_CONNECT_AGENT_CMD:-}" ]; then
    printf '%s\n' "$DIREXTALK_CONNECT_AGENT_CMD"
    return 0
  fi
  if [ "$runtime" = "hermes" ] && [ "$agent" = "acp" ]; then
    dirextalk_normalize_local_path "${DIREXTALK_HERMES_ACP_ADAPTER_COMMAND:-${DIREXTALK_CONNECT_BIN:-dirextalk-connect}}"
    return 0
  fi
  for raw_key in $(_connect_runtime_command_aliases "$runtime") "$agent" $(_connect_agent_command_aliases "$agent"); do
    var="DIREXTALK_$(printf '%s' "$raw_key" | tr '[:lower:]-' '[:upper:]_')_COMMAND"
    value=$(printenv "$var" 2>/dev/null || true)
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  if [ "$agent" = "cursor" ] && [ "$(dirextalk_local_path_style)" = "windows" ]; then
    _cursor_agent_windows_command && return 0
  fi
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

_cursor_agent_windows_command() {
  local candidate
  for candidate in \
    "${DIREXTALK_CURSOR_AGENT_COMMAND:-}" \
    "${DIREXTALK_CURSOR_COMMAND:-}" \
    "${LOCALAPPDATA:-}/cursor-agent/agent.cmd" \
    "${LOCALAPPDATA:-}/Programs/cursor-agent/agent.cmd"
  do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    dirextalk_normalize_local_path "$candidate"
    return 0
  done
  command -v agent.cmd 2>/dev/null || command -v agent 2>/dev/null || true
}

_cursor_agent_latest_version_dir() {
  local versions_dir=$1
  [ -d "$versions_dir" ] || return 1
  ls -1d "$versions_dir"/[0-9][0-9][0-9][0-9].* 2>/dev/null \
    | sort -V \
    | tail -1
}

_cursor_agent_prepare_windows() {
  local agent_root="${LOCALAPPDATA:-}/cursor-agent"
  local versions_dir="$agent_root/versions"
  local dist_dir="$versions_dir/dist-package"
  local latest

  if [ ! -f "$agent_root/agent.cmd" ]; then
    warn "Cursor Agent CLI is missing at $agent_root/agent.cmd. Install it before S6 auto wiring:"
    warn "  powershell -NoProfile -ExecutionPolicy Bypass -Command \"irm 'https://cursor.com/install?win32=true' | iex\""
    warn "Then run: & \"\$env:LOCALAPPDATA\\cursor-agent\\agent.cmd\" login"
    return 1
  fi

  if [ ! -f "$dist_dir/node.exe" ]; then
    latest=$(_cursor_agent_latest_version_dir "$versions_dir") || latest=
    if [ -n "$latest" ] && [ -f "$latest/node.exe" ]; then
      if [ -e "$dist_dir" ]; then
        rm -rf "$dist_dir" 2>/dev/null || true
      fi
      if command -v cmd.exe >/dev/null 2>&1; then
        cmd.exe /C mklink /J "$dist_dir" "$latest" >/dev/null 2>&1 || ln -s "$latest" "$dist_dir" 2>/dev/null || true
      else
        ln -s "$latest" "$dist_dir" 2>/dev/null || true
      fi
      if [ -f "$dist_dir/node.exe" ]; then
        ok "Linked Cursor Agent dist-package to $(basename "$latest") for legacy launchers."
      fi
    fi
  fi

  if [ ! -f "$dist_dir/node.exe" ]; then
    warn "Cursor Agent CLI is installed but dist-package/node.exe is missing."
    warn "Reinstall with: irm 'https://cursor.com/install?win32=true' | iex"
    return 1
  fi

  return 0
}

_connect_agent_options_toml() {
  local runtime=${1:-} agent=${2:-} args_toml q_display
  if [ -n "${DIREXTALK_CONNECT_AGENT_OPTIONS_TOML:-}" ]; then
    printf '%s\n' "$DIREXTALK_CONNECT_AGENT_OPTIONS_TOML"
    return 0
  fi
  case "$runtime:$agent" in
    cursor:cursor)
      printf 'mode = "%s"\n' "$(_toml_escape "${DIREXTALK_CURSOR_MODE:-yolo}")"
      ;;
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
  if [ -n "${DIREXTALK_OPENCLAW_ACP_ARGS_TOML:-}" ]; then
    printf '%s\n' "$DIREXTALK_OPENCLAW_ACP_ARGS_TOML"
    return 0
  fi
  url=${DIREXTALK_OPENCLAW_ACP_URL:-}
  token_file=${DIREXTALK_OPENCLAW_ACP_TOKEN_FILE:-}
  session=${DIREXTALK_OPENCLAW_ACP_SESSION:-}
  if [ -n "$url" ] && [ -n "$token_file" ] && [ -n "$session" ]; then
    token_file=$(dirextalk_normalize_local_path "$token_file")
    _toml_array acp --url "$url" --token-file "$token_file" --session "$session"
    return 0
  fi
  if [ -n "$url" ] || [ -n "$token_file" ]; then
    [ -n "$url" ] || missing="${missing} DIREXTALK_OPENCLAW_ACP_URL"
    [ -n "$token_file" ] || missing="${missing} DIREXTALK_OPENCLAW_ACP_TOKEN_FILE"
    [ -n "$session" ] || missing="${missing} DIREXTALK_OPENCLAW_ACP_SESSION"
    fail "OpenClaw ACP explicit Gateway settings are incomplete:${missing}. Set all of DIREXTALK_OPENCLAW_ACP_URL, DIREXTALK_OPENCLAW_ACP_TOKEN_FILE, and DIREXTALK_OPENCLAW_ACP_SESSION; otherwise leave URL/token-file unset so openclaw acp can auto-detect from its config."
    return 1
  fi
  # Fallback: OpenClaw acp auto-discovers gateway from ~/.openclaw/openclaw.json.
  warn "OpenClaw ACP Gateway settings were not provided; generated config will let 'openclaw acp' auto-detect the Gateway from local OpenClaw config."
  _toml_array acp --session "${session:-agent:main:main}"
}

_hermes_acp_args_toml() {
  local hermes_cmd
  hermes_cmd=${DIREXTALK_HERMES_COMMAND:-hermes}
  hermes_cmd=$(dirextalk_normalize_local_path "$hermes_cmd")
  if [ -n "${DIREXTALK_HERMES_ACP_ARGS_TOML:-}" ]; then
    _toml_array_prepend "$DIREXTALK_HERMES_ACP_ARGS_TOML" hermes-acp-adapter -- "$hermes_cmd"
    return 0
  fi
  _toml_array hermes-acp-adapter -- "$hermes_cmd" acp
}

_toml_array() {
  local first=1 value q_value
  printf '['
  for value in "$@"; do
    q_value=$(_toml_escape "$value")
    [ "$first" -eq 0 ] && printf ', '
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
      ;;
  esac
  _toml_has_key "$custom_toml" mode || printf 'mode = "yolo"\n'
}

_toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
