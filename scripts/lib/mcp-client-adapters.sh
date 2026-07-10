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

_mcp_config_type_for_runtime() {
  case "$1" in
    codex) printf 'codex\n' ;;
    cursor) printf 'cursor\n' ;;
    openclaw) printf 'openclaw\n' ;;
    hermes) printf 'hermes\n' ;;
    *) printf 'generic\n' ;;
  esac
}

_mcp_selected_config_path() {
  local service_dir=$1 runtime=$2
  case "$(_mcp_config_type_for_runtime "$runtime")" in
    codex) _mcp_codex_config_path "$service_dir" ;;
    cursor) _mcp_cursor_config_path "$service_dir" ;;
    openclaw) _mcp_openclaw_config_path "$service_dir" ;;
    hermes) _mcp_hermes_config_path "$service_dir" ;;
    *) _mcp_json_config_path "$service_dir" ;;
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

_write_mcp_openclaw_server_config() {
  local path=$1 endpoint_url=$2 agent_token=$3 node_id=${4:-}
  mkdir -p "$(dirname "$path")"
  umask 077
  json_build mcp-http-openclaw-server-config "$endpoint_url" "$agent_token" "$node_id" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

_write_mcp_config_artifacts() {
  local service_id=$1 service_dir=$2 service_url=$3 agent_token=$4 credentials_file=$5 node_id=${6:-} runtime=${7:-generic}
  local mcp_dir server_name endpoint_url q_server q_endpoint q_auth q_node
  local codex_config cursor_config json_config openclaw_config openclaw_server_config hermes_config env_file readme
  local openclaw_server_config_local openclaw_server_config_bash openclaw_server_config_ps
  local cursor_config_local cursor_project_config cursor_global_config cursor_project_config_ps cursor_global_config_ps
  local config_type selected_config selected_config_local selected_label
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
  openclaw_server_config=$(_mcp_openclaw_server_config_path "$service_dir")
  hermes_config=$(_mcp_hermes_config_path "$service_dir")
  env_file=$(_mcp_env_file_path "$service_dir")
  readme=$(_mcp_readme_path "$service_dir")
  config_type=$(_mcp_config_type_for_runtime "$runtime")
  selected_config=$(_mcp_selected_config_path "$service_dir" "$runtime")
  selected_config_local=$(dirextalk_normalize_local_path "$selected_config")

  mkdir -p "$mcp_dir"
  umask 077
  rm -f "$codex_config" "$cursor_config" "$json_config" "$openclaw_config" "$openclaw_server_config" "$hermes_config" "$mcp_dir/openclaw.mcp.json"

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
      selected_label="OpenClaw CLI setup"
      _write_mcp_openclaw_server_config "$openclaw_server_config" "$endpoint_url" "$agent_token" "$node_id"
      openclaw_server_config_local=$(dirextalk_normalize_local_path "$openclaw_server_config")
      openclaw_server_config_bash=$(printf '%q' "$openclaw_server_config_local")
      openclaw_server_config_ps=$(_mcp_powershell_single_quote "$openclaw_server_config_local")
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
      ;;
    hermes)
      selected_label="Hermes JSON"
      _write_mcp_json_config "$hermes_config" "$server_name" "$endpoint_url" "$agent_token" "$node_id"
      ;;
    *)
      selected_label="Generic MCP JSON"
      _write_mcp_json_config "$json_config" "$server_name" "$endpoint_url" "$agent_token" "$node_id"
      ;;
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
- Selected MCP type: $config_type
- Selected MCP config: $selected_config_local
- Selected MCP label: $selected_label
- MCP transport: http
- MCP endpoint: $endpoint_url

The deployer writes only the MCP config for the detected runtime. Runtime-specific snippets are used for Codex, Cursor, OpenClaw, and Hermes. Other MCP-capable supported runtimes receive the generic mcpServers JSON. The selected snippet connects to the remote HTTP MCP endpoint with this service's agent token, so no local MCP CLI, daemon, proxy, or listening port is required.

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
  local openclaw_config payload
  if [ "$policy" != "auto" ]; then
    state_set mcp_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  if [ "$runtime" = "openclaw" ]; then
    [ -n "$server_name" ] || server_name=$(_mcp_server_name local)
    openclaw_config=$(_mcp_openclaw_server_config_path "$service_dir")
    if [ ! -s "$openclaw_config" ]; then
      state_set mcp_install_status "install_failed" 2>/dev/null || true
      warn "OpenClaw MCP server config was not found at $openclaw_config."
      return 1
    fi
    if ! command -v openclaw >/dev/null 2>&1; then
      state_set mcp_install_status "openclaw_missing" 2>/dev/null || true
      warn "OpenClaw runtime detected but openclaw CLI is not on PATH; cannot install MCP config automatically."
      return 1
    fi
    payload=$(cat "$openclaw_config")
    if ! openclaw mcp set "$server_name" "$payload"; then
      state_set mcp_install_status "install_failed" 2>/dev/null || true
      warn "openclaw mcp set failed for $server_name."
      return 1
    fi
    if ! openclaw mcp doctor; then
      state_set mcp_install_status "doctor_failed" 2>/dev/null || true
      warn "openclaw mcp doctor failed after installing $server_name."
      return 1
    fi
    if ! openclaw mcp reload; then
      state_set mcp_install_status "reload_failed" 2>/dev/null || true
      warn "openclaw mcp reload failed after installing $server_name."
      return 1
    fi
    ok "OpenClaw MCP config installed for $server_name."
    state_set mcp_install_status "installed" 2>/dev/null || true
    return 0
  fi
  ok "MCP uses the remote HTTP endpoint; no local MCP CLI install is required."
  state_set mcp_install_status "not_required" 2>/dev/null || true
}

_print_mcp_guidance() {
  local runtime=$1 service_name=$2 server_name=$3 credentials_file=$4 config_dir=$5 selected_type=$6 selected_config=$7 install_command=$8 doctor_command=$9 service_dir=${10:-} endpoint_url=${11:-}
  warn "Dirextalk MCP artifacts written for runtime=$runtime service=$service_name."
  cat >&2 <<EOF
MCP server name:        $server_name
MCP transport:          http
MCP endpoint:           $endpoint_url
MCP config directory:   $config_dir
MCP credential file:    $credentials_file
MCP install note:       $install_command
MCP verify command:     $doctor_command
Selected MCP type:     $selected_type
Selected MCP config:   $selected_config

S6 writes only the MCP config selected for the detected runtime. Codex, Cursor, OpenClaw, and Hermes have dedicated snippets; other MCP-capable supported runtimes use the generic mcpServers JSON. The selected snippet connects directly to the message server HTTP MCP endpoint with the generated service agent token. No local MCP CLI, daemon, proxy, or listening port is required.
Cursor can load its selected JSON via .cursor/mcp.json or ~/.cursor/mcp.json, but Cursor may require a full restart or MCP settings reload before the server is enabled.
For OpenClaw, use the selected CLI setup note so OpenClaw validates and writes mcp.servers itself; do not paste MCP JSON into openclaw.json.
EOF
  _mcp_warn_existing_config_conflicts "$server_name" "$endpoint_url" "$service_name"
}

_mcp_toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_mcp_powershell_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}
