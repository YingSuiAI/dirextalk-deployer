# mcp-client-adapters.sh - MCP client config artifacts and install guidance.

_mcp_runtime_dir() {
  local service_dir=$1
  printf '%s/mcp\n' "$service_dir"
}

_mcp_endpoint_url() {
  local service_url=${1:-}
  [ -n "$service_url" ] || return 1
  printf '%s/mcp\n' "${service_url%/}"
}

_mcp_codex_config_path() {
  local service_dir=$1
  printf '%s/codex.toml\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_cursor_config_path() {
  local service_dir=$1
  printf '%s/cursor.mcp.json\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_json_config_path() {
  local service_dir=$1
  printf '%s/mcp-servers.json\n' "$(_mcp_runtime_dir "$service_dir")"
}

_mcp_openclaw_config_path() {
  local service_dir=$1
  printf '%s/openclaw.md\n' "$(_mcp_runtime_dir "$service_dir")"
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

_mcp_runtime_capability_records() {
  cat <<'EOF'
acp|session|none
antigravity|project|none
claudecode|session|none
codex|session|codex
copilot|session|none
cursor|project|cursor
devin|unsupported|none
gemini|session|none
iflow|host-managed|none
kimi|session|none
opencode|session|none
pi|conditional|none
qoder|session|none
reasonix|unsupported|none
tmux|conditional|none
openclaw|host-managed|openclaw
hermes|session|hermes
EOF
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

_mcp_config_type_for_runtime() {
  local record
  record=$(_mcp_runtime_record "$1") || return 1
  printf '%s\n' "$record" | awk -F '|' '{ print $3 }'
}

_mcp_selected_config_path() {
  local service_dir=$1 runtime=$2
  case "$(_mcp_config_type_for_runtime "$runtime")" in
    codex) _mcp_codex_config_path "$service_dir" ;;
    cursor) _mcp_cursor_config_path "$service_dir" ;;
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
  local domain=${service_url#https://} q_domain
  domain=${domain#http://}
  domain=${domain%%/*}
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    q_domain=$(_mcp_powershell_single_quote "$domain")
    printf "\$env:DOMAIN = '%s'; & '.\\scripts\\orchestrate.ps1' verify mcp_doctor\n" "$q_domain"
    return 0
  fi
  if [ -n "$domain" ]; then
    printf 'DOMAIN=%q bash scripts/orchestrate.sh verify mcp_doctor\n' "$domain"
  else
    printf 'bash scripts/orchestrate.sh verify mcp_doctor\n'
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

_write_mcp_json_config() {
  local path=$1 server_name=$2 endpoint_url=$3 agent_token=$4 node_id=${5:-}
  mkdir -p "$(dirname "$path")"
  umask 077
  json_build mcp-http-json-config "$server_name" "$endpoint_url" "$agent_token" "$node_id" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

_write_mcp_config_artifacts() {
  local service_id=$1 service_dir=$2 service_url=$3 agent_token=$4 credentials_file=$5 node_id=${6:-} runtime=${7:-generic}
  local mcp_dir server_name endpoint_url q_server q_endpoint q_auth q_node
  local codex_config cursor_config json_config openclaw_config hermes_config env_file readme
  local credentials_file_local
  local cursor_config_local cursor_project_config cursor_global_config cursor_project_config_ps cursor_global_config_ps
  local capability config_type selected_config selected_config_local selected_label
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  server_name=$(_mcp_server_name "$service_id")
  endpoint_url=$(_mcp_endpoint_url "$service_url")
  q_server=$(_mcp_toml_escape "$server_name")
  q_endpoint=$(_mcp_toml_escape "$endpoint_url")
  q_auth=$(_mcp_toml_escape "Bearer $agent_token")
  q_node=$(_mcp_toml_escape "$node_id")
  codex_config=$(_mcp_codex_config_path "$service_dir")
  cursor_config=$(_mcp_cursor_config_path "$service_dir")
  json_config=$(_mcp_json_config_path "$service_dir")
  openclaw_config=$(_mcp_openclaw_config_path "$service_dir")
  hermes_config=$(_mcp_hermes_config_path "$service_dir")
  env_file=$(_mcp_env_file_path "$service_dir")
  readme=$(_mcp_readme_path "$service_dir")
  capability=$(_mcp_runtime_capability "$runtime") || return 1
  config_type=$(_mcp_config_type_for_runtime "$runtime") || return 1
  selected_config=$(_mcp_selected_config_path "$service_dir" "$runtime") || return 1
  if [ -n "$selected_config" ]; then
    selected_config_local=$(dirextalk_normalize_local_path "$selected_config")
  else
    selected_config_local=
  fi
  credentials_file_local=$(dirextalk_normalize_local_path "$credentials_file")

  mkdir -p "$mcp_dir"
  umask 077
  rm -f "$codex_config" "$cursor_config" "$json_config" "$openclaw_config" "$hermes_config" "$mcp_dir/openclaw-server.json" "$mcp_dir/openclaw.mcp.json"

  case "$config_type" in
    codex)
      selected_label="Codex TOML"
      cat > "$codex_config" <<EOF
[mcp_servers."$q_server"]
url = "$q_endpoint"
headers = { Authorization = "$q_auth", "DIREXTALK-Agent-Node-Id" = "$q_node" }
EOF
      chmod 600 "$codex_config" 2>/dev/null || true
      ;;
    cursor)
      selected_label="Cursor JSON"
      _write_mcp_json_config "$cursor_config" "$server_name" "$endpoint_url" "$agent_token" "$node_id"
      ;;
    openclaw)
      selected_label="OpenClaw host-managed guidance"
      cat > "$openclaw_config" <<EOF
# OpenClaw MCP (host-managed)

OpenClaw ACP does not accept per-session MCP servers. Configure this endpoint through a separately reviewed host-managed mechanism:

- Endpoint: $endpoint_url
- Node id: $node_id
- Service credentials: $credentials_file_local

S6 does not mutate OpenClaw's user-global configuration and does not place bearer credentials in process arguments. Keep host enrollment as an explicit operator action.
EOF
      chmod 644 "$openclaw_config" 2>/dev/null || true
      ;;
    hermes)
      selected_label="Hermes JSON"
      _write_mcp_json_config "$hermes_config" "$server_name" "$endpoint_url" "$agent_token" "$node_id"
      ;;
    none)
      selected_label="No standalone client artifact; dirextalk-connect owns injection"
      ;;
    *) return 1 ;;
  esac

  {
    printf 'export DIREXTALK_MCP_URL=%q\n' "$endpoint_url"
    [ -n "$node_id" ] && printf 'export DIREXTALK_AGENT_NODE_ID=%q\n' "$node_id"
  } > "$env_file"
  chmod 600 "$env_file" 2>/dev/null || true

  cursor_config_local=$(dirextalk_normalize_local_path "$cursor_config")
  cursor_project_config='.cursor/mcp.json'
  cursor_global_config='~/.cursor/mcp.json'
  cursor_project_config_ps=$(_mcp_powershell_single_quote "$cursor_project_config")
  cursor_global_config_ps=$(_mcp_powershell_single_quote "$cursor_global_config")
  cat > "$readme" <<EOF
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

The deployer writes a standalone MCP client artifact only when the declarative runtime map names one. Other supported bridge agents rely on dirextalk-connect's capability-specific injection, and conditional or unsupported runtimes never receive a generic fallback. The canonical MCP env artifact connects to the remote HTTP endpoint, so no local MCP CLI, daemon, proxy, or listening port is required.

Cursor can read MCP servers from \`$cursor_project_config\` in a project or \`$cursor_global_config\` globally. The deployer writes the Cursor-ready JSON snippet here, but does not modify a project or global Cursor config by default because it contains a bearer token for this service. After installing or updating Cursor MCP config, fully restart Cursor or use Cursor's MCP settings to reload/enable the server.

If a client already has the same MCP server name, replace or unset that old entry when its URL differs from this deployment. Otherwise the client can keep talking to a stale node even after this deployer writes fresh snippets.

PowerShell example for reviewing the generated Cursor config:

\`\`\`powershell
Get-Content -Raw -LiteralPath '$(_mcp_powershell_single_quote "$cursor_config_local")'
\`\`\`

Suggested Cursor targets:

- Project: \`$cursor_project_config_ps\`
- Global: \`$cursor_global_config_ps\`
EOF
  chmod 644 "$readme" 2>/dev/null || true
}

_maybe_auto_install_mcp() {
  local policy=$1 runtime=${2:-generic} server_name=${3:-} credentials_file=${4:-} node_id=${5:-} service_dir=${6:-}
  local capability
  capability=$(_mcp_runtime_capability "$runtime") || {
    state_set mcp_install_status "unsupported_runtime" 2>/dev/null || true
    warn "No MCP capability is declared for runtime=$runtime."
    return 1
  }
  case "$capability" in
    host-managed)
      warn "runtime=$runtime is host-managed for MCP; S6 will not mutate user-global host configuration."
      state_set mcp_install_status "host_managed" 2>/dev/null || true
      return 0
      ;;
    conditional)
      state_set mcp_install_status "conditional" 2>/dev/null || true
      return 0
      ;;
    unsupported)
      state_set mcp_install_status "unsupported" 2>/dev/null || true
      return 0
      ;;
  esac
  if [ "$policy" != "auto" ]; then
    state_set mcp_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  ok "MCP uses the remote HTTP endpoint; no local MCP CLI install is required."
  state_set mcp_install_status "not_required" 2>/dev/null || true
}

_print_mcp_guidance() {
  local runtime=$1 service_name=$2 server_name=$3 credentials_file=$4 config_dir=$5 selected_type=$6 selected_config=$7 install_command=$8 doctor_command=$9 service_dir=${10:-} endpoint_url=${11:-}
  local capability
  capability=$(_mcp_runtime_capability "$runtime") || capability=undeclared
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

S6 writes a standalone client artifact only when the runtime map names one. Other supported bridge agents rely on dirextalk-connect injection; conditional, unsupported, and undeclared runtimes never receive a generic fallback. No local MCP CLI, daemon, proxy, or listening port is required.
Cursor can load its selected JSON via .cursor/mcp.json or ~/.cursor/mcp.json, but Cursor may require a full restart or MCP settings reload before the server is enabled.
OpenClaw is host-managed. S6 writes a reviewable setup note but never mutates OpenClaw's user-global MCP configuration automatically.
EOF
  _mcp_warn_existing_config_conflicts "$server_name" "$endpoint_url" "$service_name"
}

_mcp_toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_mcp_powershell_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}
