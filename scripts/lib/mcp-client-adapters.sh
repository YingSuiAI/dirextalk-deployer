# mcp-client-adapters.sh - MCP client config artifacts and install guidance.

_mcp_npm_package() {
  printf '%s\n' "${DIREXTALK_MCP_NPM_PACKAGE:-dirextalk-mcp@latest}"
}

_mcp_command() {
  local service_dir=${1:-}
  if [ -n "${DIREXTALK_MCP_COMMAND:-}" ]; then
    printf '%s\n' "$DIREXTALK_MCP_COMMAND"
    return 0
  fi
  if [ -n "$service_dir" ]; then
    if [ "$(dirextalk_local_path_style)" = "windows" ]; then
      printf '%s/dirextalk-mcp.cmd\n' "$(_mcp_package_dir "$service_dir")"
    else
      printf '%s/dirextalk-mcp\n' "$(_mcp_package_dir "$service_dir")"
    fi
    return 0
  fi
  printf '%s\n' "dirextalk-mcp"
}

_mcp_package_bin_path() {
  local service_dir=$1
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    printf '%s/node_modules/.bin/dirextalk-mcp.cmd\n' "$(_mcp_package_dir "$service_dir")"
  else
    printf '%s/node_modules/.bin/dirextalk-mcp\n' "$(_mcp_package_dir "$service_dir")"
  fi
}

_ensure_mcp_wrapper() {
  local service_dir=$1 wrapper target
  [ -z "${DIREXTALK_MCP_COMMAND:-}" ] || return 0
  wrapper=$(_mcp_command "$service_dir")
  target=$(_mcp_package_bin_path "$service_dir")
  mkdir -p "$(dirname "$wrapper")"
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    cat > "$wrapper" <<'EOF'
@echo off
"%~dp0node_modules\.bin\dirextalk-mcp.cmd" %*
EOF
  else
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -e
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$DIR/node_modules/.bin/dirextalk-mcp" "$@"
EOF
  fi
  chmod 700 "$wrapper" 2>/dev/null || true
  [ -f "$target" ] || return 0
}

_mcp_package_dir() {
  local service_dir=$1
  _mcp_runtime_dir "$service_dir"
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
  local service_dir=${1:-} command package_dir
  command=$(_mcp_command "$service_dir")
  if [ -n "$service_dir" ] && [ -z "${DIREXTALK_MCP_COMMAND:-}" ]; then
    package_dir=$(_mcp_package_dir "$service_dir")
    printf 'npm install --prefix %q %q' "$package_dir" "$(_mcp_npm_package)"
  else
    printf 'if ! command -v %q >/dev/null 2>&1; then npm install -g %q; fi' "$command" "$(_mcp_npm_package)"
  fi
}

_mcp_doctor_command() {
  local credentials_file=$1 node_id=${2:-} service_dir=${3:-}
  printf 'DIREXTALK_CREDENTIALS_FILE=%q' "$(dirextalk_normalize_local_path "$credentials_file")"
  if [ -n "$node_id" ]; then
    printf ' DIREXTALK_AGENT_NODE_ID=%q' "$node_id"
  fi
  printf ' %q doctor --json\n' "$(_mcp_command "$service_dir")"
}

_mcp_command_available() {
  local service_dir=${1:-} command
  command=$(_mcp_command "$service_dir")
  [ -x "$command" ] || command -v "$command" >/dev/null 2>&1
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
  local server_name=$1 credentials_file=$2 service_id=$3
  local credentials_local raw_path path found=0
  credentials_local=$(dirextalk_normalize_local_path "$credentials_file")
  while IFS= read -r raw_path; do
    [ -n "$raw_path" ] || continue
    path=$(_mcp_expand_home_path "$raw_path")
    [ -f "$path" ] || continue
    if grep -Fq "$server_name" "$path" &&
      ! grep -Fq "$credentials_local" "$path"; then
      if [ "$found" -eq 0 ]; then
        warn "Existing MCP config may shadow this deployment because it defines the same server name with different credentials:"
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
  local service_id=$1 service_dir=$2 credentials_file=$3 node_id=${4:-} runtime=${5:-generic}
  local mcp_dir server_name command credentials_local q_server q_command q_credentials q_node
  local codex_config cursor_config json_config openclaw_config openclaw_server_config hermes_config env_file readme
  local openclaw_server_config_local openclaw_server_config_bash openclaw_server_config_ps
  local cursor_config_local cursor_project_config cursor_global_config cursor_project_config_ps cursor_global_config_ps
  local config_type selected_config selected_config_local selected_label
  mcp_dir=$(_mcp_runtime_dir "$service_dir")
  server_name=$(_mcp_server_name "$service_id")
  command=$(_mcp_command "$service_dir")
  credentials_local=$(dirextalk_normalize_local_path "$credentials_file")
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
  config_type=$(_mcp_config_type_for_runtime "$runtime")
  selected_config=$(_mcp_selected_config_path "$service_dir" "$runtime")
  selected_config_local=$(dirextalk_normalize_local_path "$selected_config")

  mkdir -p "$mcp_dir"
  umask 077
  _ensure_mcp_wrapper "$service_dir"
  rm -f "$codex_config" "$cursor_config" "$json_config" "$openclaw_config" "$openclaw_server_config" "$hermes_config" "$mcp_dir/openclaw.mcp.json"

  case "$config_type" in
    codex)
      selected_label="Codex TOML"
      cat > "$codex_config" <<EOF
[mcp_servers."$q_server"]
command = "$q_command"
env = { DIREXTALK_CREDENTIALS_FILE = "$q_credentials", DIREXTALK_AGENT_NODE_ID = "$q_node" }
EOF
      chmod 600 "$codex_config" 2>/dev/null || true
      ;;
    cursor)
      selected_label="Cursor JSON"
      _write_mcp_json_config "$cursor_config" "$server_name" "$command" "$credentials_local" "$node_id"
      ;;
    openclaw)
      selected_label="OpenClaw CLI setup"
      _write_mcp_openclaw_server_config "$openclaw_server_config" "$command" "$credentials_local" "$node_id"
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
      _write_mcp_json_config "$hermes_config" "$server_name" "$command" "$credentials_local" "$node_id"
      ;;
    *)
      selected_label="Generic MCP JSON"
      _write_mcp_json_config "$json_config" "$server_name" "$command" "$credentials_local" "$node_id"
      ;;
  esac

  {
    printf 'export DIREXTALK_CREDENTIALS_FILE=%q\n' "$credentials_local"
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

Install the local MCP package:

\`\`\`bash
$(_mcp_install_command "$service_dir")
\`\`\`

Check this service's MCP credentials:

\`\`\`bash
$(_mcp_doctor_command "$credentials_file" "$node_id" "$service_dir")
\`\`\`

Config snippets:

- Selected runtime: $runtime
- Selected MCP type: $config_type
- Selected MCP config: $selected_config_local
- Selected MCP label: $selected_label

The deployer writes only the MCP config for the detected runtime. Runtime-specific snippets are used for Codex, Cursor, OpenClaw, and Hermes. Other MCP-capable supported runtimes receive the generic mcpServers JSON. The selected snippet launches this service's dirextalk-mcp binary directly over stdio with this service's credentials, so no local MCP daemon, HTTP proxy, or listening port is required.

Cursor can read MCP servers from \`$cursor_project_config\` in a project or \`$cursor_global_config\` globally. The deployer writes the Cursor-ready JSON snippet here, but does not modify a project or global Cursor config by default because it contains machine-local credential paths. After installing or updating Cursor MCP config, fully restart Cursor or use Cursor's MCP settings to reload/enable the server.

If a client already has the same MCP server name, replace or unset that old entry when its \`DIREXTALK_CREDENTIALS_FILE\` differs from this deployment. Otherwise the client can keep talking to a stale node even after this deployer writes fresh snippets.

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
  local policy=$1 service_id=${2:-} credentials_file=${3:-} node_id=${4:-} service_dir=${5:-}
  local package_dir
  if [ "$policy" != "auto" ]; then
    state_set mcp_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  if [ -z "$service_dir" ] && [ -n "$credentials_file" ]; then
    service_dir=$(dirname "$credentials_file")
  fi
  package_dir=$(_mcp_package_dir "$service_dir")
  if command -v npm >/dev/null 2>&1; then
    mkdir -p "$package_dir"
    if npm install --prefix "$package_dir" "$(_mcp_npm_package)"; then
      _ensure_mcp_wrapper "$service_dir"
      ok "dirextalk-mcp package refreshed for this service."
    elif ! _mcp_command_available "$service_dir"; then
      state_set mcp_install_status "install_failed" 2>/dev/null || true
      warn "dirextalk-mcp service-scoped npm install failed and no existing service binary is available. MCP config artifacts and install command are available for manual recovery."
      return 0
    else
      warn "dirextalk-mcp service-scoped npm update failed; continuing with the existing service binary."
    fi
  elif ! _mcp_command_available "$service_dir"; then
      warn "DIREXTALK_AGENT_INSTALL=auto requested, but npm is not on PATH. Install Node.js to install dirextalk-mcp automatically."
      state_set mcp_install_status "npm_missing" 2>/dev/null || true
      return 0
  else
    warn "npm is not on PATH; continuing with the existing service-scoped dirextalk-mcp binary."
  fi
  state_set mcp_install_status "installed" 2>/dev/null || true
}

_print_mcp_guidance() {
  local runtime=$1 service_name=$2 server_name=$3 credentials_file=$4 config_dir=$5 selected_type=$6 selected_config=$7 install_command=$8 doctor_command=$9 service_dir=${10:-}
  warn "Dirextalk MCP artifacts written for runtime=$runtime service=$service_name."
  cat >&2 <<EOF
MCP server name:        $server_name
MCP config directory:   $config_dir
MCP credential file:    $credentials_file
MCP install command:    $install_command
MCP doctor command:     $doctor_command
Selected MCP type:     $selected_type
Selected MCP config:   $selected_config

S6 writes only the MCP config selected for the detected runtime. Codex, Cursor, OpenClaw, and Hermes have dedicated snippets; other MCP-capable supported runtimes use the generic mcpServers JSON. The selected snippet launches this service's dirextalk-mcp directly over stdio with the generated service credentials. No MCP daemon, HTTP proxy, or listening port is required.
Cursor can load its selected JSON via .cursor/mcp.json or ~/.cursor/mcp.json, but Cursor may require a full restart or MCP settings reload before the server is enabled.
For OpenClaw, use the selected CLI setup note so OpenClaw validates and writes mcp.servers itself; do not paste MCP JSON into openclaw.json.
EOF
  _mcp_warn_existing_config_conflicts "$server_name" "$credentials_file" "$service_name"
}

_mcp_toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_mcp_powershell_single_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}
