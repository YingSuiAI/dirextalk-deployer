# mcp-client-adapters.sh - MCP client config artifacts and install guidance.

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

_mcp_server_name() {
  local service_id=${1:-local}
  printf 'direxio-%s\n' "$service_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+//; s/_+$//; s/^$/direxio_local/'
}

_mcp_install_command() {
  printf 'npm install -g %q' "$(_mcp_npm_package)"
}

_mcp_doctor_command() {
  local credentials_file=$1 node_id=${2:-}
  printf 'DIREXIO_CREDENTIALS_FILE=%q' "$(direxio_normalize_local_path "$credentials_file")"
  if [ -n "$node_id" ]; then
    printf ' DIREXIO_AGENT_NODE_ID=%q' "$node_id"
  fi
  printf ' %q doctor --json\n' "$(_mcp_command)"
}

_mcp_daemon_host() {
  printf '%s\n' "${DIREXIO_MCP_DAEMON_HOST:-127.0.0.1}"
}

_mcp_daemon_port() {
  printf '%s\n' "${DIREXIO_MCP_DAEMON_PORT:-19757}"
}

_mcp_daemon_url() {
  printf 'http://%s:%s/mcp\n' "$(_mcp_daemon_host)" "$(_mcp_daemon_port)"
}

_mcp_daemon_install_command() {
  local service_id=$1 credentials_file=$2 node_id=${3:-}
  printf '%q daemon install --service-name %q --credentials-file %q' "$(_mcp_command)" "$service_id" "$(direxio_normalize_local_path "$credentials_file")"
  if [ -n "$node_id" ]; then
    printf ' --node-id %q' "$node_id"
  fi
  printf ' --host %q --port %q\n' "$(_mcp_daemon_host)" "$(_mcp_daemon_port)"
}

_mcp_daemon_status_command() {
  local service_id=$1
  printf '%q daemon status --service-name %q --json\n' "$(_mcp_command)" "$service_id"
}

_mcp_daemon_proxy_args_json() {
  printf '["proxy","--url","%s"]\n' "$(_mcp_daemon_url "$1")"
}

_mcp_daemon_proxy_args_toml() {
  local url
  url=$(_mcp_toml_escape "$(_mcp_daemon_url "$1")")
  printf '["proxy", "--url", "%s"]\n' "$url"
}

_mcp_daemon_proxy_command() {
  printf '%q proxy --url %q\n' "$(_mcp_command)" "$(_mcp_daemon_url "$1")"
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
  if [ -n "${DIREXIO_MCP_CONFIG_CONFLICT_PATHS:-}" ]; then
    printf '%s\n' "$DIREXIO_MCP_CONFIG_CONFLICT_PATHS" | tr ';' '\n'
    return 0
  fi
  printf '%s\n' \
    '~/.codex/config.toml' \
    '~/.cursor/mcp.json' \
    '~/.hermes/mcp.json' \
    '~/.config/hermes/mcp.json'
}

_mcp_warn_existing_config_conflicts() {
  local server_name=$1 credentials_file=$2 service_id=$3
  local credentials_local daemon_url raw_path path found=0
  credentials_local=$(direxio_normalize_local_path "$credentials_file")
  daemon_url=$(_mcp_daemon_url "$service_id")
  while IFS= read -r raw_path; do
    [ -n "$raw_path" ] || continue
    path=$(_mcp_expand_home_path "$raw_path")
    [ -f "$path" ] || continue
    if grep -Fq "$server_name" "$path" &&
      { ! grep -Fq "$credentials_local" "$path" || ! grep -Fq "$daemon_url" "$path"; }; then
      if [ "$found" -eq 0 ]; then
        warn "Existing MCP config may shadow this deployment because it defines the same server name with different credentials or proxy URL:"
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

_run_mcp_daemon_install() {
  local service_id=$1 credentials_file=$2 node_id=${3:-}
  if [ -n "$node_id" ]; then
    "$(_mcp_command)" daemon install \
      --service-name "$service_id" \
      --credentials-file "$(direxio_normalize_local_path "$credentials_file")" \
      --node-id "$node_id" \
      --host "$(_mcp_daemon_host)" \
      --port "$(_mcp_daemon_port)"
  else
    "$(_mcp_command)" daemon install \
      --service-name "$service_id" \
      --credentials-file "$(direxio_normalize_local_path "$credentials_file")" \
      --host "$(_mcp_daemon_host)" \
      --port "$(_mcp_daemon_port)"
  fi
}

_write_mcp_json_config() {
  local path=$1 server_name=$2 command=$3 credentials_file=$4 node_id=${5:-} args_json=${6:-}
  mkdir -p "$(dirname "$path")"
  umask 077
  json_build mcp-json-config "$server_name" "$command" "$credentials_file" "$node_id" "$args_json" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

_write_mcp_openclaw_server_config() {
  local path=$1 command=$2 credentials_file=$3 node_id=${4:-} args_json=${5:-}
  mkdir -p "$(dirname "$path")"
  umask 077
  json_build mcp-openclaw-server-config "$command" "$credentials_file" "$node_id" "$args_json" > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

_write_mcp_config_artifacts() {
  local service_id=$1 service_dir=$2 credentials_file=$3 node_id=${4:-}
  local mcp_dir server_name command credentials_local q_server q_command q_credentials q_node
  local codex_config cursor_config json_config openclaw_config openclaw_server_config hermes_config env_file readme
  local openclaw_server_config_local openclaw_server_config_bash openclaw_server_config_ps
  local cursor_config_local cursor_project_config cursor_global_config cursor_project_config_ps cursor_global_config_ps
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  server_name=$(_mcp_server_name "$service_id")
  command=$(_mcp_command)
  local proxy_args_json proxy_args_toml
  proxy_args_json=$(_mcp_daemon_proxy_args_json "$service_id")
  proxy_args_toml=$(_mcp_daemon_proxy_args_toml "$service_id")
  credentials_local=$(direxio_normalize_local_path "$credentials_file")
  q_server=$(_mcp_toml_escape "$server_name")
  q_command=$(_mcp_toml_escape "$command")
  q_credentials=$(_mcp_toml_escape "$credentials_local")
  q_node=$(_mcp_toml_escape "$node_id")
  codex_config=$(_mcp_codex_config_path "$service_dir")
  cursor_config=$(_mcp_cursor_config_path "$service_dir")
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
args = $proxy_args_toml
env = { DIREXIO_CREDENTIALS_FILE = "$q_credentials", DIREXIO_AGENT_NODE_ID = "$q_node" }
EOF
  chmod 600 "$codex_config" 2>/dev/null || true

  rm -f "$mcp_dir/openclaw.mcp.json"
  _write_mcp_json_config "$json_config" "$server_name" "$command" "$credentials_local" "$node_id" "$proxy_args_json"
  _write_mcp_json_config "$cursor_config" "$server_name" "$command" "$credentials_local" "$node_id" "$proxy_args_json"
  _write_mcp_openclaw_server_config "$openclaw_server_config" "$command" "$credentials_local" "$node_id" "$proxy_args_json"
  _write_mcp_json_config "$hermes_config" "$server_name" "$command" "$credentials_local" "$node_id" "$proxy_args_json"

  openclaw_server_config_local=$(direxio_normalize_local_path "$openclaw_server_config")
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

  {
    printf 'export DIREXIO_CREDENTIALS_FILE=%q\n' "$credentials_local"
    [ -n "$node_id" ] && printf 'export DIREXIO_AGENT_NODE_ID=%q\n' "$node_id"
  } > "$env_file"
  chmod 600 "$env_file" 2>/dev/null || true

  cursor_config_local=$(direxio_normalize_local_path "$cursor_config")
  cursor_project_config='.cursor/mcp.json'
  cursor_global_config='~/.cursor/mcp.json'
  cursor_project_config_ps=$(_mcp_powershell_single_quote "$cursor_project_config")
  cursor_global_config_ps=$(_mcp_powershell_single_quote "$cursor_global_config")
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

- Codex TOML: $(direxio_normalize_local_path "$codex_config")
- Cursor JSON: $cursor_config_local
- OpenClaw CLI setup: $(direxio_normalize_local_path "$openclaw_config")
- Hermes JSON: $(direxio_normalize_local_path "$hermes_config")
- Generic JSON: $(direxio_normalize_local_path "$json_config")

Generated Codex, Cursor, OpenClaw, Hermes, and generic JSON snippets use a stdio proxy command that connects to the service-scoped direxio-mcp daemon at $(_mcp_daemon_url "$service_id"). Install or refresh that daemon with:

\`\`\`bash
$(_mcp_daemon_install_command "$service_id" "$credentials_file" "$node_id")
\`\`\`

Cursor can read MCP servers from \`$cursor_project_config\` in a project or \`$cursor_global_config\` globally. The deployer writes the Cursor-ready JSON snippet here, but does not modify a project or global Cursor config by default because it contains machine-local credential paths. After installing or updating Cursor MCP config, fully restart Cursor or use Cursor's MCP settings to reload/enable the server.

If a client already has the same MCP server name, replace or unset that old entry when its \`DIREXIO_CREDENTIALS_FILE\` or proxy URL differs from this deployment. Otherwise the client can keep talking to a stale node even after this deployer writes fresh snippets.

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
  local policy=$1 service_id=${2:-} credentials_file=${3:-} node_id=${4:-}
  if [ "$policy" != "auto" ]; then
    state_set mcp_install_status "$policy" 2>/dev/null || true
    state_set mcp_daemon_install_status "$policy" 2>/dev/null || true
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
    state_set mcp_daemon_install_status "install_skipped" 2>/dev/null || true
    return 0
  fi
  if [ -z "$service_id" ] || [ -z "$credentials_file" ]; then
    state_set mcp_daemon_install_status "missing_inputs" 2>/dev/null || true
    warn "direxio-mcp daemon install skipped because service id or credentials file is missing."
    return 0
  fi
  if _run_mcp_daemon_install "$service_id" "$credentials_file" "$node_id"; then
    state_set mcp_daemon_install_status "installed" 2>/dev/null || true
    ok "direxio-mcp daemon installed for $service_id."
  else
    state_set mcp_daemon_install_status "install_failed" 2>/dev/null || true
    warn "direxio-mcp daemon install failed. Hermes can still use the generated stdio snippets after manual recovery."
  fi
}

_print_mcp_guidance() {
  local runtime=$1 service_name=$2 server_name=$3 credentials_file=$4 config_dir=$5 codex_config=$6 openclaw_config=$7 hermes_config=$8 install_command=$9 doctor_command=${10} cursor_config=${11:-}
  warn "Direxio MCP artifacts written for runtime=$runtime service=$service_name."
  cat >&2 <<EOF
MCP server name:        $server_name
MCP config directory:   $config_dir
MCP credential file:    $credentials_file
MCP install command:    $install_command
MCP doctor command:     $doctor_command
MCP daemon install:     $(_mcp_daemon_install_command "$service_name" "$credentials_file" "")
MCP daemon status:      $(_mcp_daemon_status_command "$service_name")
MCP daemon URL:         $(_mcp_daemon_url "$service_name")
MCP stdio proxy:        $(_mcp_daemon_proxy_command "$service_name")
Codex TOML snippet:     $codex_config
Cursor JSON snippet:    ${cursor_config:-not generated}
OpenClaw CLI setup:    $openclaw_config
Hermes JSON snippet:   $hermes_config

Codex, Cursor, OpenClaw, Hermes, and generic JSON artifacts use direxio-mcp's stdio proxy to reach the service-scoped local MCP daemon, so the tool surface can survive client restarts and host-runtime restarts.
Cursor can load the generated JSON via .cursor/mcp.json or ~/.cursor/mcp.json, but Cursor may require a full restart or MCP settings reload before the server is enabled.
For OpenClaw, use the CLI setup note so OpenClaw validates and writes mcp.servers itself; do not paste MCP JSON into openclaw.json.
EOF
  _mcp_warn_existing_config_conflicts "$server_name" "$credentials_file" "$service_name"
}

_mcp_toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_mcp_powershell_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}
