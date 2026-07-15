# mcp-client-adapters.sh - MCP client config artifacts and install guidance.

MCP_CLIENT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$MCP_CLIENT_LIB_DIR/remote-mcp-contract.sh"

_mcp_runtime_dir() {
  local service_dir=$1
  printf '%s/mcp\n' "$service_dir"
}

_mcp_endpoint_url() {
  dirextalk_mcp_endpoint_url "$1"
}

_mcp_codex_config_path() {
  local service_dir=$1
  printf '%s/codex.toml\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_cursor_config_path() {
  local service_dir=$1
  printf '%s/cursor.mcp.json\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_openclaw_config_path() {
  local service_dir=$1
  printf '%s/openclaw.md\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_hermes_config_path() {
  local service_dir=$1
  printf '%s/hermes.md\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_hermes_home() {
  local _service_dir=${1:-} configured
  configured=${DIREXTALK_HERMES_MCP_HOME:-${HERMES_HOME:-$HOME/.hermes}}
  dirextalk_normalize_local_path "$configured"
}

_mcp_hermes_profile() {
  local server_name=$1
  printf '%s\n' "${DIREXTALK_HERMES_PROFILE:-$server_name}"
}

_mcp_hermes_source_profile() {
  printf '%s\n' "${DIREXTALK_HERMES_SOURCE_PROFILE:-}"
}

_mcp_host_token_env_key() {
  local server_name=$1 normalized
  normalized=$(printf '%s' "$server_name" | tr '[:lower:]-' '[:upper:]_')
  normalized=$(printf '%s' "$normalized" | sed -E 's/[^A-Z0-9_]+/_/g; s/^_+//; s/_+$//')
  [ -n "$normalized" ] || return 1
  printf 'DIREXTALK_MCP_%s_AGENT_TOKEN\n' "$normalized"
}

_mcp_hermes_profile_marker_path() {
  local profile_dir=$1
  printf '%s/.dirextalk-host-profile.json\n' "$profile_dir"
}

_mcp_readme_path() {
  local service_dir=$1
  printf '%s/README.md\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_runtime_capability_records() {
  cat <<'EOF'
acp|session|none
antigravity|host-managed|none
claudecode|session|none
codex|session|none
copilot|session|none
cursor|host-managed|none
devin|unsupported|none
gemini|session|none
iflow|host-managed|none
kimi|session|none
opencode|session|none
pi|unsupported|none
qoder|session|none
reasonix|unsupported|none
tmux|unsupported|none
openclaw|host-managed|openclaw
hermes|host-managed|hermes
EOF
}

_mcp_host_registry_records() {
  cat <<'EOF'
openclaw|openclaw.mcp.servers
hermes|hermes.mcp_servers
EOF
}

_mcp_host_registry_owner() {
  local runtime=$1 record
  record=$(_mcp_host_registry_records | awk -F '|' -v runtime="$runtime" '$1 == runtime { print $2; exit }')
  [ -n "$record" ] || return 1
  printf '%s\n' "$record"
}

_mcp_runtime_record() {
  local runtime=${1:-} canonical record
  case "$runtime" in
    openclaw|hermes) canonical=$runtime ;;
    *) canonical=$(_connect_agent_alias "$runtime" 2>/dev/null) || return 1 ;;
  esac
  record=$(_mcp_runtime_capability_records | awk -F '|' -v runtime="$canonical" '$1 == runtime { print; exit }')
  [ -n "$record" ] || return 1
  printf '%s\n' "$record"
}

_mcp_runtime_capability() {
  local record
  record=$(_mcp_runtime_record "$1") || return 1
  printf '%s\n' "$record" | awk -F '|' '{ print $2 }'
}

_mcp_effective_capability() {
  local runtime=$1 cc_agent=$2
  if _mcp_host_registry_owner "$runtime" >/dev/null 2>&1; then
    printf 'host-managed\n'
    return 0
  fi
  _mcp_runtime_capability "$cc_agent"
}

_mcp_config_type_for_runtime() {
  local record
  record=$(_mcp_runtime_record "$1") || return 1
  printf '%s\n' "$record" | awk -F '|' '{ print $3 }'
}

_mcp_selected_config_path() {
  local service_dir=$1 runtime=$2
  case "$(_mcp_config_type_for_runtime "$runtime")" in
    openclaw) _mcp_openclaw_config_path "$service_dir" ;;
    hermes) _mcp_hermes_config_path "$service_dir" ;;
    none) return 0 ;;
    *) return 1 ;;
  esac
}

_mcp_server_name() {
  local service_id=${1:-local}
  printf 'dirextalk-%s\n' "$service_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+//; s/_+$//; s/^$/dirextalk_local/'
}

_mcp_install_command() {
  local service_url=${1:-} service_dir=${2:-} endpoint
  endpoint=$(_mcp_endpoint_url "$service_url" 2>/dev/null || printf '<service-url>/mcp')
  printf 'No local MCP CLI install is needed; configure the MCP client URL %s.' "$endpoint"
}

_mcp_doctor_command() {
  local service_url=$1 credentials_file=${2:-} node_id=${3:-} service_dir=${4:-}
  local domain=${service_url#https://}
  domain=${domain#http://}
  domain=${domain%%/*}
  if [ -n "$domain" ]; then
    dirextalk_render_env_command DOMAIN "$domain" bash scripts/orchestrate.sh verify mcp_doctor
    printf '\n'
  else
    dirextalk_render_local_command bash scripts/orchestrate.sh verify mcp_doctor
    printf '\n'
  fi
}

_mcp_expand_home_path() {
  local path=$1
  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${path#~/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

_mcp_config_conflict_paths() {
  if [ -n "${DIREXTALK_MCP_CONFIG_CONFLICT_PATHS:-}" ]; then
    printf '%s\n' "$DIREXTALK_MCP_CONFIG_CONFLICT_PATHS" | tr ';' '\n'
    return 0
  fi
  printf '%s\n' \
    '~/.codex/config.toml' \
    '~/.cursor/mcp.json' \
    '~/.hermes/mcp.json' \
    '~/.config/hermes/mcp.json'
}

_mcp_warn_existing_config_conflicts() {
  local server_name=$1 endpoint_url=$2 service_id=$3
  local raw_path path found=0
  while IFS= read -r raw_path; do
    [ -n "$raw_path" ] || continue
    path=$(_mcp_expand_home_path "$raw_path")
    [ -f "$path" ] || continue
    if grep -Fq "$server_name" "$path" &&
      ! grep -Fq "$endpoint_url" "$path"; then
      if [ "$found" -eq 0 ]; then
        warn "Existing MCP config may shadow this deployment because it defines the same server name with a different URL:"
        found=1
      fi
      warn "  $path"
    fi
  done <<EOF
$(_mcp_config_conflict_paths)
EOF
  if [ "$found" -ne 0 ]; then
    warn "Replace or unset that MCP server entry before testing $server_name, then reload or restart the MCP client."
  fi
}

_openclaw_mcp_probe() {
  local server_name=$1 command profile
  [ -n "$server_name" ] || return 1
  command=$(_openclaw_command) || return $?
  profile=${DIREXTALK_OPENCLAW_PROFILE:-}
  if [ -n "$profile" ]; then
    "$command" --profile "$profile" mcp probe "$server_name" --json >/dev/null 2>&1
  else
    "$command" mcp probe "$server_name" --json >/dev/null 2>&1
  fi
}

_mcp_credentials_value() {
  local credentials_file=$1 key=$2 value
  [ -f "$credentials_file" ] || return 1
  value=$(json_get "$credentials_file" "profiles.default.$key" 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

_openclaw_mcp_register() {
  local server_name=$1 credentials_file=$2 command profile token_env
  [ -n "$server_name" ] && [ -f "$credentials_file" ] || return 1
  command=$(_openclaw_command) || return $?
  token_env=$(_mcp_host_token_env_key "$server_name") || return 1
  profile=${DIREXTALK_OPENCLAW_PROFILE:-}
  if [ -n "$profile" ]; then
    if ! (
      set -o pipefail
      json_build openclaw-mcp-patch "$credentials_file" "$server_name" "$token_env" 2>/dev/null |
        "$command" --profile "$profile" config patch --stdin >/dev/null 2>&1
    ); then
      return 1
    fi
  elif ! (
    set -o pipefail
    json_build openclaw-mcp-patch "$credentials_file" "$server_name" "$token_env" 2>/dev/null |
      "$command" config patch --stdin >/dev/null 2>&1
  ); then
    return 1
  fi
}

_openclaw_mcp_remove() {
  local server_name=$1 token_env=$2 profile=${3:-} config_path=${4:-} command
  [ -n "$server_name" ] && [ -n "$token_env" ] || return 1
  command=$(_openclaw_command) || return $?
  if [ -n "$profile" ]; then
    if [ -n "$config_path" ]; then
      (
        set -o pipefail
        OPENCLAW_CONFIG_PATH="$config_path" json_build openclaw-mcp-cleanup-patch "$server_name" "$token_env" 2>/dev/null |
          OPENCLAW_CONFIG_PATH="$config_path" "$command" --profile "$profile" config patch --stdin >/dev/null 2>&1
      )
    else
      (
        set -o pipefail
        json_build openclaw-mcp-cleanup-patch "$server_name" "$token_env" 2>/dev/null |
          "$command" --profile "$profile" config patch --stdin >/dev/null 2>&1
      )
    fi
  elif [ -n "$config_path" ]; then
    (
      set -o pipefail
      OPENCLAW_CONFIG_PATH="$config_path" json_build openclaw-mcp-cleanup-patch "$server_name" "$token_env" 2>/dev/null |
        OPENCLAW_CONFIG_PATH="$config_path" "$command" config patch --stdin >/dev/null 2>&1
    )
  else
    (
      set -o pipefail
      json_build openclaw-mcp-cleanup-patch "$server_name" "$token_env" 2>/dev/null |
        "$command" config patch --stdin >/dev/null 2>&1
    )
  fi
}

_hermes_profile_config_path() {
  local hermes_home=$1 profile=$2 command=$3 config_path
  [ -n "$hermes_home" ] && [ -n "$profile" ] && [ -n "$command" ] || return 1
  config_path=$(HERMES_HOME="$hermes_home" "$command" -p "$profile" config path 2>/dev/null) || return 1
  [ -n "$config_path" ] || return 1
  dirextalk_execution_path "$config_path"
}

_hermes_profile_dir() {
  local hermes_home=$1 profile=$2 command=$3 config_path
  config_path=$(_hermes_profile_config_path "$hermes_home" "$profile" "$command") || return 1
  dirname "$config_path"
}

_hermes_profile_has_model() {
  local hermes_home=$1 profile=${2:-} command=$3 status model
  [ -n "$hermes_home" ] && [ -n "$command" ] || return 1
  if [ -n "$profile" ]; then
    status=$(HERMES_HOME="$hermes_home" "$command" -p "$profile" status 2>/dev/null) || return 1
  else
    status=$(HERMES_HOME="$hermes_home" "$command" status 2>/dev/null) || return 1
  fi
  model=$(printf '%s\n' "$status" | awk -F 'Model:' '/Model:/ { value=$2; sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); print value; exit }')
  if [ -z "$model" ] || [ "$model" = "(not set)" ]; then
    return 1
  fi
  return 0
}

_hermes_profile_marker_matches() {
  local marker=$1 server_name=$2
  [ -f "$marker" ] || return 1
  [ "$(json_get "$marker" server_name 2>/dev/null || true)" = "$server_name" ] &&
    [ "$(json_get "$marker" managed_by 2>/dev/null || true)" = "dirextalk-deployer" ]
}

_ensure_hermes_mcp_profile() {
  local server_name=$1 service_dir=$2 command hermes_home profile source_profile config_path profile_dir marker owned=false
  [ -n "$server_name" ] && [ -n "$service_dir" ] || return 1
  command=$(_hermes_command) || return $?
  hermes_home=$(_mcp_hermes_home "$service_dir") || return 1
  profile=$(_mcp_hermes_profile "$server_name") || return 1
  [ -n "$profile" ] || return 1

  if [ -n "${DIREXTALK_HERMES_PROFILE:-}" ]; then
    profile_dir=$(_hermes_profile_dir "$hermes_home" "$profile" "$command") || return 1
  elif profile_dir=$(_hermes_profile_dir "$hermes_home" "$profile" "$command" 2>/dev/null); then
    marker=$(_mcp_hermes_profile_marker_path "$profile_dir") || return 1
    _hermes_profile_marker_matches "$marker" "$server_name" || return 1
    owned=true
  else
    source_profile=$(_mcp_hermes_source_profile) || return 1
    _hermes_profile_has_model "$hermes_home" "$source_profile" "$command" || return 1
    if [ -n "$source_profile" ]; then
      HERMES_HOME="$hermes_home" "$command" profile create "$profile" --clone-from "$source_profile" --no-alias >/dev/null 2>&1 || return 1
    else
      HERMES_HOME="$hermes_home" "$command" profile create "$profile" --clone --no-alias >/dev/null 2>&1 || return 1
    fi
    profile_dir=$(_hermes_profile_dir "$hermes_home" "$profile" "$command") || return 1
    dirextalk_restrict_private_directory "$profile_dir" || return 1
    marker=$(_mcp_hermes_profile_marker_path "$profile_dir") || return 1
    dirextalk_atomic_write "$marker" 600 json_build object \
      managed_by=dirextalk-deployer \
      "server_name=$server_name" \
      "profile=$profile" || return 1
    owned=true
  fi

  _hermes_profile_has_model "$hermes_home" "$profile" "$command" || return 1
  printf '%s|%s|%s|%s\n' "$profile_dir" "$owned" "$hermes_home" "$profile"
}

_hermes_python_command() {
  local command=$1 explicit=${DIREXTALK_HERMES_PYTHON:-} command_dir candidate shebang interpreter
  [ -n "$command" ] || return 1
  if [ -n "$explicit" ]; then
    dirextalk_normalize_local_path "$explicit"
    return 0
  fi
  command_dir=$(dirname "$command") || return 1
  for candidate in "$command_dir/python.exe" "$command_dir/python"; do
    if [ -x "$candidate" ]; then
      dirextalk_normalize_local_path "$candidate"
      return 0
    fi
  done
  case "$command" in
    *.exe|*.EXE) ;;
    *)
      if [ -r "$command" ]; then
        IFS= read -r shebang < "$command" || true
        case "$shebang" in
          '#!'*)
            interpreter=${shebang#\#!}
            interpreter=${interpreter%% *}
            if [ -x "$interpreter" ]; then
              dirextalk_normalize_local_path "$interpreter"
              return 0
            fi
            ;;
        esac
      fi
      ;;
  esac
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import hermes_cli' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 127
}

_hermes_native_upsert_script() {
  cat <<'PY'
import os
import sys

from hermes_cli.config import save_env_value
from hermes_cli.mcp_config import _save_mcp_server

name = os.environ["DIREXTALK_MCP_NAME"]
url = os.environ["DIREXTALK_HERMES_ENDPOINT_URL"]
env_key = os.environ["DIREXTALK_MCP_ENV_KEY"]
token = sys.stdin.buffer.read().decode("utf-8").rstrip("\r\n")
if not token or "\n" in token or "\r" in token:
    raise SystemExit(2)
save_env_value(env_key, token)
ok = _save_mcp_server(name, {
    "url": url,
    "headers": {"Authorization": f"Bearer ${{{env_key}}}"},
    "enabled": True,
})
raise SystemExit(0 if ok else 3)
PY
}

_hermes_native_probe_script() {
  cat <<'PY'
import os

from hermes_cli.mcp_config import _get_mcp_servers, _probe_single_server

name = os.environ["DIREXTALK_MCP_NAME"]
config = _get_mcp_servers().get(name)
if not isinstance(config, dict):
    raise SystemExit(2)
tools = _probe_single_server(name, config)
raise SystemExit(0 if tools else 3)
PY
}

_hermes_native_remove_script() {
  cat <<'PY'
import os

from hermes_cli.config import remove_env_value
from hermes_cli.mcp_config import _remove_mcp_server

_remove_mcp_server(os.environ["DIREXTALK_MCP_NAME"])
remove_env_value(os.environ["DIREXTALK_MCP_ENV_KEY"])
PY
}

_hermes_mcp_register() {
  local server_name=$1 credentials_file=$2 service_dir=$3 profile_info profile_dir owned hermes_home profile command python token endpoint env_key
  [ -n "$server_name" ] && [ -f "$credentials_file" ] && [ -n "$service_dir" ] || return 1
  profile_info=$(_ensure_hermes_mcp_profile "$server_name" "$service_dir") || return 1
  profile_dir=${profile_info%%|*}
  profile_info=${profile_info#*|}
  owned=${profile_info%%|*}
  profile_info=${profile_info#*|}
  hermes_home=${profile_info%%|*}
  profile=${profile_info#*|}
  command=$(_hermes_command) || return $?
  python=$(_hermes_python_command "$command") || return $?
  token=$(_mcp_credentials_value "$credentials_file" agent_token) || return 1
  endpoint=$(_mcp_credentials_value "$credentials_file" mcp_url) || return 1
  env_key=$(_mcp_host_token_env_key "$server_name") || return 1
  case "$endpoint" in https://*/mcp) ;; *) return 1 ;; esac
  if ! (
    set -o pipefail
    printf '%s' "$token" |
      HERMES_HOME="$profile_dir" DIREXTALK_MCP_NAME="$server_name" DIREXTALK_HERMES_ENDPOINT_URL="$endpoint" DIREXTALK_MCP_ENV_KEY="$env_key" \
        "$python" -c "$(_hermes_native_upsert_script)" >/dev/null 2>&1
  ); then
    return 1
  fi
  printf '%s|%s|%s|%s|%s\n' "$profile_dir" "$owned" "$hermes_home" "$profile" "$env_key"
}

_hermes_mcp_probe() {
  local server_name=$1 service_dir=$2 command profile hermes_home profile_dir python
  [ -n "$server_name" ] && [ -n "$service_dir" ] || return 1
  command=$(_hermes_command) || return $?
  profile=$(_mcp_hermes_profile "$server_name") || return 1
  hermes_home=$(_mcp_hermes_home "$service_dir") || return 1
  profile_dir=$(_hermes_profile_dir "$hermes_home" "$profile" "$command") || return 1
  _hermes_profile_has_model "$hermes_home" "$profile" "$command" || return 1
  python=$(_hermes_python_command "$command") || return $?
  HERMES_HOME="$profile_dir" DIREXTALK_MCP_NAME="$server_name" \
    "$python" -c "$(_hermes_native_probe_script)" >/dev/null 2>&1
}

_hermes_mcp_remove() {
  local hermes_home=$1 profile=$2 server_name=$3 env_key=$4 command profile_dir python
  [ -n "$hermes_home" ] && [ -n "$profile" ] && [ -n "$server_name" ] && [ -n "$env_key" ] || return 1
  command=$(_hermes_command) || return $?
  profile_dir=$(_hermes_profile_dir "$hermes_home" "$profile" "$command") || return 1
  python=$(_hermes_python_command "$command") || return $?
  HERMES_HOME="$profile_dir" DIREXTALK_MCP_NAME="$server_name" DIREXTALK_MCP_ENV_KEY="$env_key" \
    "$python" -c "$(_hermes_native_remove_script)" >/dev/null 2>&1
}

_render_openclaw_mcp_guidance() {
  local endpoint_url=$1 node_id=$2 credentials_file=$3 capability=$4
  cat <<EOF || return 1
# OpenClaw MCP host context

Effective connect-agent MCP capability: $capability

- Endpoint: $endpoint_url
- Node id: $node_id
- Service credentials: $credentials_file

EOF
  if [ "$capability" = "host-managed" ]; then
    cat <<'EOF' || return 1
OpenClaw ACP does not accept per-session MCP servers. With `DIREXTALK_AGENT_INSTALL=auto`, S6 registers this endpoint in OpenClaw's native `mcp.servers` registry through `openclaw config patch --stdin`, stores the service token as a service-specific local config variable, and then requires `openclaw mcp probe <server-name> --json` to list tools before bridge startup. The token is never passed as a process argument or written to this guidance file. Use an inherited `OPENCLAW_CONFIG_PATH` or `DIREXTALK_OPENCLAW_PROFILE` when the service needs an isolated OpenClaw registry/profile; destroy removes the managed server entry and its service token variable.

EOF
  else
    cat <<'EOF' || return 1
The explicitly selected dirextalk-connect backend owns MCP handling for this capability; this host note is retained for review only.

EOF
  fi
  cat <<'EOF' || return 1
S6 never runs `mcp set` and does not place bearer credentials in process arguments.
EOF
}

_render_hermes_mcp_guidance() {
  local endpoint_url=$1 node_id=$2 credentials_file=$3 hermes_home=$4 profile=$5 server_name=$6
  cat <<EOF || return 1
# Hermes MCP host context

Hermes owns this endpoint through its native \`mcp_servers\` registry; dirextalk-connect only owns the conversation bridge.

- Endpoint: $endpoint_url
- Node id: $node_id
- Service credentials: $credentials_file
- Native Hermes home: HERMES_HOME=$hermes_home
- Service profile: $profile

S6 creates the generated service profile in this native Hermes home by cloning the currently configured Hermes profile, then writes the endpoint through Hermes's installed runtime API. It requires live tool discovery before bridge startup and deletes that generated profile on destroy. The cloned profile contains the model/provider configuration needed by Hermes and is private to the current local user.

S6 performs the native live-tool probe automatically; use the deployer's
\`verify mcp_tools\` check for a later service-level confirmation.

For an explicit \`DIREXTALK_HERMES_PROFILE\`, S6 uses that existing profile and removes only this deployment's MCP server and token on destroy. S6 never generates a generic Hermes MCP JSON file or passes bearer credentials in process arguments.
EOF
}

_write_mcp_config_artifacts() {
  local service_id=$1 service_dir=$2 service_url=$3 _agent_token=$4 credentials_file=$5 node_id=${6:-} runtime=${7:-generic}
  local mcp_dir server_name endpoint_url
  local codex_config cursor_config legacy_json_config legacy_hermes_json openclaw_config hermes_config readme
  local credentials_file_local hermes_home hermes_home_local hermes_profile
  local capability=${8:-} config_type selected_config selected_config_local selected_label
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  server_name=$(_mcp_server_name "$service_id")
  endpoint_url=$(_mcp_endpoint_url "$service_url")
  codex_config=$(_mcp_codex_config_path "$service_dir")
  cursor_config=$(_mcp_cursor_config_path "$service_dir")
  legacy_json_config="$mcp_dir/mcp-servers.json"
  legacy_hermes_json="$mcp_dir/hermes.mcp.json"
  openclaw_config=$(_mcp_openclaw_config_path "$service_dir")
  hermes_config=$(_mcp_hermes_config_path "$service_dir")
  readme=$(_mcp_readme_path "$service_dir")
  if [ -z "$capability" ]; then
    capability=$(_mcp_runtime_capability "$runtime") || return 1
  fi
  config_type=$(_mcp_config_type_for_runtime "$runtime") || return 1
  selected_config=$(_mcp_selected_config_path "$service_dir" "$runtime") || return 1
  if [ -n "$selected_config" ]; then
    selected_config_local=$(dirextalk_normalize_local_path "$selected_config")
  else
    selected_config_local=
  fi
  credentials_file_local=$(dirextalk_normalize_local_path "$credentials_file")
  hermes_home=$(_mcp_hermes_home "$service_dir") || return 1
  hermes_home_local=$(dirextalk_normalize_local_path "$hermes_home") || return 1
  hermes_profile=$(_mcp_hermes_profile "$server_name") || return 1

  mkdir -p "$mcp_dir" || return 1
  if [ "$config_type" = "hermes" ]; then
    mkdir -p "$hermes_home" || return 1
  fi
  umask 077
  rm -f "$legacy_json_config" "$legacy_hermes_json" "$mcp_dir/openclaw-server.json" "$mcp_dir/openclaw.mcp.json" "$mcp_dir/env" || return 1
  case "$config_type" in
    codex) rm -f "$cursor_config" "$openclaw_config" "$hermes_config" || return 1 ;;
    cursor) rm -f "$codex_config" "$openclaw_config" "$hermes_config" || return 1 ;;
    openclaw) rm -f "$codex_config" "$cursor_config" "$hermes_config" || return 1 ;;
    hermes) rm -f "$codex_config" "$cursor_config" "$openclaw_config" || return 1 ;;
    none) rm -f "$codex_config" "$cursor_config" "$openclaw_config" "$hermes_config" || return 1 ;;
    *) return 1 ;;
  esac

  case "$config_type" in
    openclaw)
      selected_label="OpenClaw host guidance ($capability)"
      dirextalk_atomic_write "$openclaw_config" 644 _render_openclaw_mcp_guidance "$endpoint_url" "$node_id" "$credentials_file_local" "$capability" || return 1
      ;;
    hermes)
      selected_label="Hermes host guidance ($capability)"
      dirextalk_atomic_write "$hermes_config" 644 _render_hermes_mcp_guidance "$endpoint_url" "$node_id" "$credentials_file_local" "$hermes_home_local" "$hermes_profile" "$server_name" || return 1
      ;;
    none)
      selected_label="No standalone client artifact; dirextalk-connect owns injection"
      ;;
    *) return 1 ;;
  esac

  if ! dirextalk_atomic_write "$readme" 644 cat <<EOF
# Dirextalk MCP Config

This deployment uses the message server's HTTP MCP endpoint directly:

\`\`\`bash
$endpoint_url
\`\`\`

Config snippets:

- Selected runtime: $runtime
- MCP capability: $capability
- Selected MCP type: $config_type
- Selected MCP config: $selected_config_local
- Selected MCP label: $selected_label
- MCP transport: http
- MCP endpoint: $endpoint_url

Session agents receive canonical MCP data through dirextalk-connect. With the automatic policy, OpenClaw and Hermes update their native host registries and require a live native tool probe; other host-managed, unsupported, and undeclared runtimes never receive a generic standalone fallback. No local MCP CLI, daemon, proxy, env artifact, or listening port is required.

If a client already has the same MCP server name, replace or unset that old entry when its URL differs from this deployment. Otherwise the client can keep talking to a stale node even after this deployer writes fresh snippets.

EOF
  then
    return 1
  fi
}

_maybe_auto_install_mcp() {
  local policy=$1 runtime=${2:-generic} server_name=${3:-} credentials_file=${4:-} node_id=${5:-} service_dir=${6:-}
  local capability=${7:-}
  if [ -z "$capability" ]; then
    capability=$(_mcp_runtime_capability "$runtime") || {
      state_set mcp_install_status "unsupported_runtime" 2>/dev/null || true
      warn "No MCP capability is declared for runtime=$runtime."
      return 1
    }
  fi
  case "$capability" in
    host-managed)
      if [ "$policy" != "auto" ]; then
        state_set mcp_host_probe_status "not_run_host_action_required" 2>/dev/null || true
        state_set mcp_install_status "host_action_required" 2>/dev/null || true
        return 0
      fi
      if [ "$runtime" = "openclaw" ]; then
        local openclaw_token_env
        openclaw_token_env=$(_mcp_host_token_env_key "$server_name") || return 1
        state_set mcp_host_registry_owner "openclaw" 2>/dev/null || true
        state_set mcp_host_registry_server "$server_name" 2>/dev/null || true
        state_set mcp_host_token_env_key "$openclaw_token_env" 2>/dev/null || true
        state_set mcp_openclaw_profile "${DIREXTALK_OPENCLAW_PROFILE:-}" 2>/dev/null || true
        state_set mcp_openclaw_config_path "$(dirextalk_normalize_local_path "${OPENCLAW_CONFIG_PATH:-}")" 2>/dev/null || true
        if ! _openclaw_mcp_register "$server_name" "$credentials_file"; then
          warn "OpenClaw native MCP registration failed; S6 will not start the bridge."
          state_set mcp_host_registration_status "failed" 2>/dev/null || true
          state_set mcp_host_probe_status "not_run" 2>/dev/null || true
          state_set mcp_install_status "host_registration_failed" 2>/dev/null || true
          return 1
        fi
        state_set mcp_host_registration_status "registered" 2>/dev/null || true
        if ! _openclaw_mcp_probe "$server_name"; then
          warn "OpenClaw native MCP registration completed but its live tool probe failed; S6 will not start the bridge."
          state_set mcp_host_probe_status "failed" 2>/dev/null || true
          state_set mcp_install_status "host_probe_failed" 2>/dev/null || true
          return 1
        fi
        ok "OpenClaw MCP server was registered and its native tool probe passed."
        state_set mcp_host_probe_status "passed" 2>/dev/null || true
        state_set mcp_install_status "auto_installed" 2>/dev/null || true
        return 0
      fi
      if [ "$runtime" = "hermes" ]; then
        local hermes_registration hermes_profile_dir hermes_profile_owned hermes_home hermes_profile hermes_token_env
        if ! hermes_registration=$(_hermes_mcp_register "$server_name" "$credentials_file" "$service_dir"); then
          warn "Hermes MCP profile setup or native registration failed; S6 will not start the bridge."
          state_set mcp_host_registry_owner "hermes" 2>/dev/null || true
          state_set mcp_host_registration_status "failed" 2>/dev/null || true
          state_set mcp_host_probe_status "not_run" 2>/dev/null || true
          state_set mcp_install_status "host_registration_failed" 2>/dev/null || true
          return 1
        fi
        hermes_profile_dir=${hermes_registration%%|*}
        hermes_registration=${hermes_registration#*|}
        hermes_profile_owned=${hermes_registration%%|*}
        hermes_registration=${hermes_registration#*|}
        hermes_home=${hermes_registration%%|*}
        hermes_registration=${hermes_registration#*|}
        hermes_profile=${hermes_registration%%|*}
        hermes_token_env=${hermes_registration#*|}
        state_set mcp_host_registry_owner "hermes" 2>/dev/null || true
        state_set mcp_host_registry_server "$server_name" 2>/dev/null || true
        state_set mcp_host_token_env_key "$hermes_token_env" 2>/dev/null || true
        state_set mcp_hermes_home "$(dirextalk_normalize_local_path "$hermes_home")" 2>/dev/null || true
        state_set mcp_hermes_profile "$hermes_profile" 2>/dev/null || true
        state_set mcp_hermes_profile_dir "$(dirextalk_normalize_local_path "$hermes_profile_dir")" 2>/dev/null || true
        state_set mcp_hermes_profile_owned "$hermes_profile_owned" 2>/dev/null || true
        state_set mcp_host_registration_status "registered" 2>/dev/null || true
        if ! _hermes_mcp_probe "$server_name" "$service_dir"; then
          warn "Hermes MCP registration completed but its native tool probe failed; S6 will not start the bridge."
          state_set mcp_host_probe_status "failed" 2>/dev/null || true
          state_set mcp_install_status "host_probe_failed" 2>/dev/null || true
          return 1
        fi
        ok "Hermes MCP profile was registered and its native tool probe passed."
        state_set mcp_host_probe_status "passed" 2>/dev/null || true
        state_set mcp_install_status "auto_installed" 2>/dev/null || true
        return 0
      fi
      if [ "${DIREXTALK_MCP_HOST_READY:-}" = "1" ]; then
        warn "runtime=$runtime uses operator-confirmed host-managed MCP enrollment; no official live probe is available, S6 did not mutate user-global host configuration, and runtime MCP verification remains required."
        state_set mcp_host_probe_status "not_available_operator_confirmed" 2>/dev/null || true
        state_set mcp_install_status "operator_confirmed_host_managed" 2>/dev/null || true
        return 0
      fi
      warn "runtime=$runtime requires explicit host-managed MCP enrollment before the dirextalk-connect bridge starts; S6 will not mutate user-global host configuration. Complete enrollment, set DIREXTALK_MCP_HOST_READY=1, and let the current agent rerun the deployer."
      state_set mcp_host_probe_status "not_run_host_action_required" 2>/dev/null || true
      state_set mcp_install_status "host_action_required" 2>/dev/null || true
      return 2
      ;;
    conditional)
      state_set mcp_host_probe_status "not_applicable" 2>/dev/null || true
      state_set mcp_install_status "conditional" 2>/dev/null || true
      warn "runtime=$runtime has conditional MCP support and no declared consuming extension or wrapper was verified; refusing to continue."
      return 1
      ;;
    unsupported)
      state_set mcp_host_probe_status "not_applicable" 2>/dev/null || true
      state_set mcp_install_status "unsupported" 2>/dev/null || true
      warn "runtime=$runtime does not support the canonical remote MCP contract; refusing to continue."
      return 1
      ;;
  esac
  state_set mcp_host_probe_status "not_applicable" 2>/dev/null || true
  if [ "$policy" != "auto" ]; then
    state_set mcp_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  ok "MCP uses the remote HTTP endpoint; no local MCP CLI install is required."
  state_set mcp_install_status "not_required" 2>/dev/null || true
}

_print_mcp_guidance() {
  local runtime=$1 service_name=$2 server_name=$3 credentials_file=$4 config_dir=$5 selected_type=$6 selected_config=$7 install_command=$8 doctor_command=$9 service_dir=${10:-} endpoint_url=${11:-}
  local capability=${12:-}
  if [ -z "$capability" ]; then
    capability=$(_mcp_runtime_capability "$runtime") || capability=undeclared
  fi
  warn "Dirextalk MCP artifacts written for runtime=$runtime service=$service_name."
  cat >&2 <<EOF
MCP server name:        $server_name
MCP transport:          http
MCP endpoint:           $endpoint_url
MCP capability:         $capability
MCP config directory:   $config_dir
MCP credential file:    $credentials_file
MCP install note:       $install_command
MCP verify command:     $doctor_command
Selected MCP type:     $selected_type
Selected MCP config:   $selected_config

Session agents rely on dirextalk-connect injection. With the automatic policy, OpenClaw and Hermes register the endpoint in their native host registry and must pass a live tool probe; other host-managed, unsupported, and undeclared runtimes never receive a generic fallback. No local MCP CLI, daemon, proxy, or listening port is required.
EOF
  if [ "$runtime" = "openclaw" ]; then
    if [ "$capability" = "host-managed" ]; then
      warn "OpenClaw ACP is host-managed. In auto mode S6 registers this deployment in the selected native registry, then requires its native tool probe to pass before bridge startup."
    else
      warn "OpenClaw host guidance is retained, but effective MCP capability=$capability follows the explicitly selected connect agent."
    fi
  fi
  _mcp_warn_existing_config_conflicts "$server_name" "$endpoint_url" "$service_name"
}
