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
  local service_dir=$1
  printf '%s\n' "${DIREXTALK_HERMES_MCP_HOME:-$service_dir/hermes}"
}

_mcp_hermes_profile() {
  local server_name=$1
  printf '%s\n' "${DIREXTALK_HERMES_PROFILE:-$server_name}"
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
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    dirextalk_render_env_command DOMAIN "$domain" '.\scripts\orchestrate.ps1' verify mcp_doctor
    printf '\n'
    return 0
  fi
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
  command=${DIREXTALK_OPENCLAW_COMMAND:-openclaw}
  profile=${DIREXTALK_OPENCLAW_PROFILE:-}
  if ! command -v "$command" >/dev/null 2>&1 && [ ! -f "$command" ]; then
    return 127
  fi
  if [ -n "$profile" ]; then
    "$command" --profile "$profile" mcp probe "$server_name" --json >/dev/null 2>&1
  else
    "$command" mcp probe "$server_name" --json >/dev/null 2>&1
  fi
}

_hermes_mcp_probe() {
  local server_name=$1 service_dir=$2 command profile hermes_home
  [ -n "$server_name" ] && [ -n "$service_dir" ] || return 1
  command=${DIREXTALK_HERMES_COMMAND:-hermes}
  profile=$(_mcp_hermes_profile "$server_name") || return 1
  hermes_home=$(_mcp_hermes_home "$service_dir") || return 1
  if ! command -v "$command" >/dev/null 2>&1 && [ ! -f "$command" ]; then
    return 127
  fi
  HERMES_HOME="$hermes_home" "$command" -p "$profile" mcp test "$server_name" >/dev/null 2>&1
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
OpenClaw ACP does not accept per-session MCP servers. Enroll the endpoint in OpenClaw's native `mcp.servers` registry. With automatic installation, complete that enrollment before rerunning S6 with `DIREXTALK_MCP_HOST_READY=1`; S6 then requires `openclaw mcp probe <server-name> --json` to pass before bridge startup. Use an inherited `OPENCLAW_CONFIG_PATH` or `DIREXTALK_OPENCLAW_PROFILE` when the service needs an isolated OpenClaw registry/profile.

EOF
  else
    cat <<'EOF' || return 1
The explicitly selected dirextalk-connect backend owns MCP handling for this capability; this host note is retained for review only.

EOF
  fi
  cat <<'EOF' || return 1
S6 never runs `mcp set`, does not mutate OpenClaw's user-global configuration, and does not place bearer credentials in process arguments.
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
- Service-isolated home: HERMES_HOME=$hermes_home
- Service-isolated profile: $profile

After enrolling the server in that exact home/profile, verify it without secret argv:

\`\`\`bash
HERMES_HOME=$hermes_home hermes -p $profile mcp test $server_name
\`\`\`

S6 only creates the empty service-isolated home and this guidance file. Before setting \`DIREXTALK_MCP_HOST_READY=1\`, use the installed Hermes version's official profile create/clone workflow to create \`$profile\` inside that HERMES_HOME, then enroll the server in that profile's native \`mcp_servers\` registry. S6 does not assume the profile exists, mutate the real user Hermes home, or generate a generic Hermes MCP JSON file.
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

The deployer writes only token-free host guidance when the declarative runtime map names one. Session agents receive canonical MCP data through dirextalk-connect; host-managed, unsupported, and undeclared runtimes never receive a generic or token-bearing standalone fallback. No local MCP CLI, daemon, proxy, env artifact, or listening port is required.

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
      if [ "${DIREXTALK_MCP_HOST_READY:-}" = "1" ]; then
        if [ "$runtime" = "openclaw" ]; then
          if ! _openclaw_mcp_probe "$server_name"; then
            warn "OpenClaw host enrollment was declared ready, but the secret-free live MCP probe failed. S6 will not start the bridge or mutate OpenClaw configuration."
            state_set mcp_host_probe_status "failed" 2>/dev/null || true
            state_set mcp_install_status "host_probe_failed" 2>/dev/null || true
            return 2
          fi
          warn "OpenClaw host-managed MCP enrollment passed the secret-free live probe; S6 did not mutate user-global host configuration."
          state_set mcp_host_probe_status "passed" 2>/dev/null || true
          state_set mcp_install_status "host_probe_passed" 2>/dev/null || true
          return 0
        fi
        if [ "$runtime" = "hermes" ]; then
          if ! _hermes_mcp_probe "$server_name" "$service_dir"; then
            warn "Hermes host enrollment was declared ready, but the service-isolated secret-free MCP test failed. S6 will not start the bridge or mutate the real user Hermes home."
            state_set mcp_host_probe_status "failed" 2>/dev/null || true
            state_set mcp_install_status "host_probe_failed" 2>/dev/null || true
            return 2
          fi
          warn "Hermes host-managed MCP enrollment passed the service-isolated secret-free live test; S6 did not mutate the real user Hermes home."
          state_set mcp_host_probe_status "passed" 2>/dev/null || true
          state_set mcp_install_status "host_probe_passed" 2>/dev/null || true
          return 0
        fi
        warn "runtime=$runtime uses operator-confirmed host-managed MCP enrollment; no official live probe is available, S6 did not mutate user-global host configuration, and runtime MCP verification remains required."
        state_set mcp_host_probe_status "not_available_operator_confirmed" 2>/dev/null || true
        state_set mcp_install_status "operator_confirmed_host_managed" 2>/dev/null || true
        return 0
      fi
      warn "runtime=$runtime requires explicit host-managed MCP enrollment before the dirextalk-connect bridge starts; S6 will not mutate user-global host configuration. Complete enrollment, set DIREXTALK_MCP_HOST_READY=1, and rerun."
      state_set mcp_host_probe_status "not_run_host_action_required" 2>/dev/null || true
      state_set mcp_install_status "host_action_required" 2>/dev/null || true
      if [ "$policy" = "auto" ]; then
        return 2
      fi
      return 0
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

S6 writes only token-free host guidance when the runtime map names one. Session agents rely on dirextalk-connect injection; host-managed, unsupported, and undeclared runtimes never receive a generic or token-bearing fallback. No local MCP CLI, daemon, proxy, or listening port is required.
EOF
  if [ "$runtime" = "openclaw" ]; then
    if [ "$capability" = "host-managed" ]; then
      warn "OpenClaw ACP is host-managed. Complete explicit host enrollment before setting DIREXTALK_MCP_HOST_READY=1; S6 never mutates OpenClaw's user-global MCP configuration automatically."
    else
      warn "OpenClaw host guidance is retained, but effective MCP capability=$capability follows the explicitly selected connect agent."
    fi
  fi
  _mcp_warn_existing_config_conflicts "$server_name" "$endpoint_url" "$service_name"
}
