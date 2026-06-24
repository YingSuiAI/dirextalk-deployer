#!/usr/bin/env bash
# S6 WIRE_LOCAL_CLIENT - write service-scoped credentials and Direxio MCP/plugin env.
#
#   ① ~/.direxio/nodes/<service_id>/credentials.json
#   ② ~/.direxio/nodes/<service_id>/env
#   ③ MCP/plugin install guidance for the detected current agent runtime
#
# Tokens change on every rebuild, so local credentials and MCP/plugin env must be refreshed.

_direxio_home() {
  printf '%s\n' "${DIREXIO_HOME:-$HOME/.direxio}"
}

_direxio_service_id() {
  local raw=$1 host
  host=${raw#http://}
  host=${host#https://}
  host=${host%%/*}
  case "$host" in
    *:*) host="${host%%:*}-${host#*:}" ;;
  esac
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]' | sed -E 's/:/-/g; s/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/^$/direxio-service/'
}

_direxio_service_dir() {
  local service_id
  service_id=$(_direxio_service_id "$1")
  printf '%s/nodes/%s\n' "$(_direxio_home)" "$service_id"
}

_detect_agent_runtime() {
  if [ -n "${DIREXIO_AGENT_PLATFORM:-}" ] && [ "${DIREXIO_AGENT_PLATFORM:-}" != "auto" ]; then
    _validate_agent_platform "$DIREXIO_AGENT_PLATFORM"
    printf '%s\n' "$DIREXIO_AGENT_PLATFORM"
    return 0
  fi
  if [ -n "${CODEX_HOME:-}" ] || [ -d "$HOME/.codex" ]; then printf 'codex\n'; return 0; fi
  if [ -n "${CLAUDE_HOME:-}" ] || [ -d "$HOME/.claude" ]; then printf 'claude-code\n'; return 0; fi
  if [ -n "${GEMINI_HOME:-}" ] || [ -d "$HOME/.gemini" ]; then printf 'gemini\n'; return 0; fi
  if [ -n "${CURSOR_HOME:-}" ] || [ -d "$HOME/.cursor" ]; then printf 'cursor\n'; return 0; fi
  if [ -n "${COPILOT_HOME:-}" ] || [ -d "$HOME/.copilot" ]; then printf 'copilot\n'; return 0; fi
  if [ -n "${OPENCLAW_HOME:-}" ] || [ -d "$HOME/.openclaw" ]; then printf 'openclaw\n'; return 0; fi
  if [ -n "${HERMES_HOME:-}" ] || [ -d "$HOME/.hermes" ]; then printf 'hermes\n'; return 0; fi
  printf 'unknown\n'
}

_validate_agent_platform() {
  case "$1" in
    auto|codex|claude-code|gemini|cursor|copilot|openclaw|hermes|generic|unknown) return 0 ;;
    *) fail "DIREXIO_AGENT_PLATFORM must be auto, codex, claude-code, gemini, cursor, copilot, openclaw, hermes, generic, or unknown." ;;
  esac
}

_agent_install_policy() {
  local policy=${DIREXIO_AGENT_INSTALL:-recommend}
  case "$policy" in
    skip|recommend|auto) printf '%s\n' "$policy" ;;
    *) fail "DIREXIO_AGENT_INSTALL must be skip, recommend, or auto." ;;
  esac
}

_agent_install_mode() {
  local runtime=$1 mode=${DIREXIO_AGENT_INSTALL_MODE:-recommended}
  case "$mode" in
    recommended)
      case "$runtime" in
        openclaw|hermes) printf 'native\n' ;;
        codex|generic) printf 'gateway\n' ;;
        *) printf 'mcp\n' ;;
      esac
      ;;
    mcp|native|gateway) printf '%s\n' "$mode" ;;
    *) fail "DIREXIO_AGENT_INSTALL_MODE must be recommended, mcp, native, or gateway." ;;
  esac
}

_agent_config_home() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

_agent_skill_install_path() {
  local runtime=$1
  case "$runtime" in
    codex) printf 'PROJECT_ROOT/.codex/skills/direxio-deployer\n' ;;
    claude-code) printf 'PROJECT_ROOT/.claude/skills/direxio-deployer\n' ;;
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
    codex) printf '${CODEX_HOME:-$HOME/.codex}/skills/direxio-deployer\n' ;;
    claude-code) printf '${CLAUDE_HOME:-$HOME/.claude}/skills/direxio-deployer\n' ;;
    gemini) printf '${GEMINI_HOME:-$HOME/.gemini}/skills/direxio-deployer\n' ;;
    cursor) printf '${CURSOR_HOME:-$HOME/.cursor}/skills/direxio-deployer\n' ;;
    copilot) printf '$HOME/.github/copilot/skills/direxio-deployer\n' ;;
    openclaw) printf '${OPENCLAW_HOME:-$HOME/.openclaw}/skills/direxio-deployer\n' ;;
    hermes) printf '${HERMES_HOME:-$HOME/.hermes}/skills/direxio-deployer\n' ;;
    generic|unknown|*) printf '$HOME/.agent/skills/direxio-deployer\n' ;;
  esac
}

_agent_mcp_config_path() {
  local runtime=$1 node_id=${2:-direxio-agent} config_home
  config_home=$(_agent_config_home)
  case "$runtime" in
    codex) printf '%s/direxio-agent/nodes/%s/mcp.json\n' "${CODEX_HOME:-$HOME/.codex}" "$node_id" ;;
    claude-code) printf '%s/.claude/direxio-agent/nodes/%s/mcp.json\n' "$HOME" "$node_id" ;;
    openclaw) printf '%s/.openclaw/direxio/nodes/%s/mcp.json\n' "$HOME" "$node_id" ;;
    hermes) printf '%s/.hermes/direxio/nodes/%s/mcp.json\n' "$HOME" "$node_id" ;;
    cursor) printf '%s/direxio-agent/nodes/%s/cursor.mcp.json\n' "$config_home" "$node_id" ;;
    copilot) printf '%s/direxio-agent/nodes/%s/copilot.mcp.json\n' "$config_home" "$node_id" ;;
    gemini) printf '%s/.gemini/direxio/nodes/%s/settings.json\n' "$HOME" "$node_id" ;;
    generic|unknown|*) printf '%s/direxio-agent/nodes/%s/mcp.json\n' "$config_home" "$node_id" ;;
  esac
}

_agent_project_mcp_target() {
  local runtime=$1
  case "$runtime" in
    cursor) printf 'PROJECT_ROOT/.cursor/mcp.json\n' ;;
    copilot) printf 'PROJECT_ROOT/.github/copilot/mcp.json\n' ;;
    *) printf '\n' ;;
  esac
}

_agent_install_target_summary() {
  local runtime=$1 mcp_path=$2 project_mcp
  project_mcp=$(_agent_project_mcp_target "$runtime")
  case "$runtime" in
    codex)
      printf 'Codex gateway plus MCP payload at %s; skill clone at %s' "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    claude-code)
      printf 'Claude Code plugin template platforms/claude-code/direxio-agent plus MCP payload at %s; skill clone at %s' "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    cursor)
      printf 'Cursor project MCP target %s plus generated payload at %s; skill clone at %s' "$project_mcp" "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    copilot)
      printf 'GitHub Copilot repository MCP target %s using read-only template by default plus generated payload at %s; skill clone at %s' "$project_mcp" "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    gemini)
      printf 'Gemini settings merge target %s; skill clone at %s' "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    openclaw)
      printf 'OpenClaw native plugin install plus MCP payload at %s; skill clone at %s' "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    hermes)
      printf 'Hermes native config merge into ~/.hermes/config.yaml plus MCP payload at %s; skill clone at %s' "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
    generic|unknown|*)
      printf 'Generic MCP payload at %s; optional generic-cli gateway; skill clone at %s' "$mcp_path" "$(_agent_skill_install_path "$runtime")"
      ;;
  esac
}

_agent_install_command() {
  local runtime=$1 mode=$2 cred=$3 node_id=${4:-direxio-agent} workspace=${5:-$HOME}
  printf 'npx -y -p @direxio/agent-plugins@latest direxio-agent-install --platform %q --mode %q --node-id %q --workspace %q --credentials-file %q --write' "$runtime" "$mode" "$node_id" "$workspace" "$cred"
}

_print_runtime_install_summary() {
  local runtime=$1 mode=$2 mcp_path=$3 project_mcp
  project_mcp=$(_agent_project_mcp_target "$runtime")
  case "$runtime:$mode" in
    openclaw:native)
      cat >&2 <<EOF
Recommended OpenClaw install:
  openclaw plugins install ./platforms/openclaw
  mount $mcp_path or platforms/openclaw/mcp.json in OpenClaw's MCP registry
Native passive listening should use /_p2p/events and /_p2p/command action mcp.messages.send.
EOF
      ;;
    hermes:native)
      cat >&2 <<EOF
Recommended Hermes install:
  merge $mcp_path or platforms/hermes/mcp.json into ~/.hermes/config.yaml mcp_servers
Native passive listening should use /_p2p/events and /_p2p/command action mcp.messages.send.
EOF
      ;;
    codex:gateway)
      cat >&2 <<EOF
Recommended Codex install:
  mount @direxio/agent-plugins Codex plugin templates and run direxio-agent-gateway with codex-app-server.
  MCP payload target: $mcp_path
EOF
      ;;
    cursor:mcp)
      cat >&2 <<EOF
Recommended Cursor install:
  copy or merge the Direxio MCP payload into ${project_mcp:-PROJECT_ROOT/.cursor/mcp.json}
  generated payload target: $mcp_path
EOF
      ;;
    copilot:mcp)
      cat >&2 <<EOF
Recommended GitHub Copilot install:
  use the read-only MCP template by default at ${project_mcp:-PROJECT_ROOT/.github/copilot/mcp.json}
  generated payload target: $mcp_path
EOF
      ;;
    gemini:mcp)
      cat >&2 <<EOF
Recommended Gemini install:
  merge the Direxio MCP settings payload into Gemini settings.
  generated settings target: $mcp_path
EOF
      ;;
    *:mcp)
      cat >&2 <<EOF
Recommended install:
  mount @direxio/local-mcp in the detected agent's MCP configuration.
  generated MCP payload target: $mcp_path
  This platform does not manage a local gateway long process in this deployer.
EOF
      ;;
    *)
      cat >&2 <<EOF
Recommended gateway fallback:
  set DIREXIO_GATEWAY_COMMAND to a local agent CLI that reads stdin and writes stdout.
  generated MCP payload target: $mcp_path
EOF
      ;;
  esac
}

_maybe_auto_install_agent() {
  local policy=$1 runtime=$2 mode=$3 cred=$4 command_text=$5 node_id=${6:-direxio-agent} workspace=${7:-$HOME} installer=${DIREXIO_AGENT_INSTALL_COMMAND:-}
  if [ "$policy" != "auto" ]; then
    state_set agent_install_status "$policy" 2>/dev/null || true
    return 0
  fi
  if [ -n "$installer" ]; then
    if "$installer" --platform "$runtime" --mode "$mode" --node-id "$node_id" --workspace "$workspace" --credentials-file "$cred" --write; then
      state_set agent_install_status "installed" 2>/dev/null || true
      ok "Direxio agent plugin/MCP install completed for $runtime ($mode)."
      return 0
    fi
    state_set agent_install_status "failed" 2>/dev/null || true
    warn "Direxio agent install command failed. Credentials and env were still written; rerun manually:"
    warn "  $command_text"
    return 0
  fi
  if command -v direxio-agent-install >/dev/null 2>&1; then
    installer=direxio-agent-install
    if "$installer" --platform "$runtime" --mode "$mode" --node-id "$node_id" --workspace "$workspace" --credentials-file "$cred" --write; then
      state_set agent_install_status "installed" 2>/dev/null || true
      ok "Direxio agent plugin/MCP install completed for $runtime ($mode)."
      return 0
    fi
    state_set agent_install_status "failed" 2>/dev/null || true
    warn "Direxio agent install command failed. Credentials and env were still written; rerun manually:"
    warn "  $command_text"
    return 0
  fi
  if ! command -v npx >/dev/null 2>&1; then
    warn "DIREXIO_AGENT_INSTALL=auto requested, but neither direxio-agent-install nor npx is on PATH. Run manually after installing Node.js:"
    warn "  $command_text"
    state_set agent_install_status "installer_missing" 2>/dev/null || true
    return 0
  fi
  if npx -y -p @direxio/agent-plugins@latest direxio-agent-install --platform "$runtime" --mode "$mode" --node-id "$node_id" --workspace "$workspace" --credentials-file "$cred" --write; then
    state_set agent_install_status "installed" 2>/dev/null || true
    ok "Direxio agent plugin/MCP install completed for $runtime ($mode)."
  else
    state_set agent_install_status "failed" 2>/dev/null || true
    warn "Direxio agent install command failed. Credentials and env were still written; rerun manually:"
    warn "  $command_text"
  fi
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
  if [ -n "$explicit" ]; then
    raw=$explicit
  else
    host=${domain#http://}
    host=${host#https://}
    host=${host%%/*}
    host=${host%%:*}
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(printf '%s\n%s\n' "$domain" "$room" | sha256sum | awk '{print substr($1,1,10)}')
    else
      digest=$(printf '%s\n%s\n' "$domain" "$room" | shasum -a 256 | awk '{print substr($1,1,10)}')
    fi
    raw="${runtime:-agent}-${host:-direxio}-$digest"
  fi
  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/^$/direxio-agent/'
}

_write_credentials_file() {
  local cred=$1 domain=$2 asurl=$3 token=$4 password=$5 access_token=$6 agent_room_id=$7 node_id=$8
  mkdir -p "$(dirname "$cred")"
  jq -n --arg domain "$domain" --arg url "$asurl" --arg tok "$token" --arg password "$password" --arg access "$access_token" --arg room "$agent_room_id" --arg node_id "$node_id" \
    '{profiles:{default:{domain:$domain,password:$password,access_token:$access,agent_room_id:$room,direxio_domain:$url,direxio_agent_token:$tok,direxio_agent_room_id:$room,direxio_agent_node_id:$node_id}}}' > "$cred"
  chmod 600 "$cred"
}

_persist_agent_env() {
  local asurl=$1 token=$2 access_token=$3 agent_room_id=$4 envfile=${5:-"$(_direxio_home)/env"} node_id=${6:-}
  envfile=$(_write_agent_env_file "$asurl" "$token" "$access_token" "$agent_room_id" "$envfile" "$node_id")
  [ -n "$node_id" ] && export DIREXIO_AGENT_NODE_ID="$node_id"
  export DIREXIO_DOMAIN="$asurl"
  export DIREXIO_AGENT_TOKEN="$token"
  export DIREXIO_AGENT_ROOM_ID="$agent_room_id"
  ok "Persisted Direxio MCP/plugin env vars via $envfile."
  echo "$envfile"
}

_print_mcp_plugin_guidance() {
  local runtime=$1 asurl=$2 cred=$3 envfile=$4 policy=$5 mode=$6 install_command=$7 node_id=$8
  local skill_path global_skill_path mcp_config_path install_target_summary
  skill_path=$(_agent_skill_install_path "$runtime")
  global_skill_path=$(_agent_global_skill_install_path "$runtime")
  mcp_config_path=$(_agent_mcp_config_path "$runtime" "$node_id")
  install_target_summary=$(_agent_install_target_summary "$runtime" "$mcp_config_path")
  if [ "$policy" = "skip" ]; then
    warn "Direxio MCP/plugin install guidance skipped by DIREXIO_AGENT_INSTALL=skip."
    return 0
  fi
  warn "Direxio MCP/plugin install policy: $policy; platform=$runtime; mode=$mode."
  cat >&2 <<EOF
Detected agent runtime: $runtime
MCP package:            @direxio/local-mcp
Agent plugins package:  @direxio/agent-plugins
Local env file:         $envfile
Credential file:        $cred
Install command:        $install_command
Project skill clone:    $skill_path
Global skill fallback:  $global_skill_path
MCP/config payload:     $mcp_config_path
Target summary:         $install_target_summary

Use this stdio MCP server in the current agent config:
  command: npx
  args:    ["-y", "@direxio/local-mcp@latest"]
  env:     DIREXIO_CREDENTIALS_FILE=$cred
           DIREXIO_AGENT_NODE_ID=$node_id

Gateway native send is also available without MCP:
  npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "\$DIREXIO_AGENT_ROOM_ID" --message "hello"
EOF
  _print_runtime_install_summary "$runtime" "$mode" "$mcp_config_path"
}

run_phase() {
  phase_set S6_WIRE_LOCAL in_progress "writing credentials and Direxio MCP/plugin env"
  local domain asurl token access_token password agent_room_id envfile runtime install_policy install_mode install_command
  local node_id service_dir node_cred workspace service_id
  local skill_path global_skill_path mcp_config_path install_target_summary
  domain=$(state_get domain)
  asurl=$(state_get as_url)
  token=$(state_get agent_token)
  access_token=$(state_get access_token)
  password=$(state_get password)
  agent_room_id=$(state_get agent_room_id)
  [ -n "$asurl" ] && [ -n "$token" ] || { phase_set S6_WIRE_LOCAL failed "missing as_url/token"; fail "state is missing as_url/agent_token; complete S5 first."; }
  [ -n "$access_token" ] && [ -n "$password" ] || { phase_set S6_WIRE_LOCAL failed "missing bootstrap credentials"; fail "state is missing password/access_token; complete S5 first."; }
  if [ -z "$agent_room_id" ]; then
    agent_room_id="!agent:$domain"
    state_set agent_room_id "$agent_room_id" 2>/dev/null || true
  fi

  runtime=$(_detect_agent_runtime)
  node_id=$(_agent_node_id "$runtime" "$domain" "$agent_room_id")
  service_id=$(_direxio_service_id "${asurl:-$domain}")
  service_dir=$(_direxio_service_dir "${asurl:-$domain}")
  node_cred="$service_dir/credentials.json"
  envfile="$service_dir/env"
  workspace=${DIREXIO_AGENT_WORKSPACE:-${PWD:-$HOME}}

  # 1) Service-specific credential file.
  _write_credentials_file "$node_cred" "$domain" "$asurl" "$token" "$password" "$access_token" "$agent_room_id" "$node_id"
  ok "Wrote $node_cred (0600)."

  # 2) Persistent service environment for the current Direxio MCP and plugin.
  if ! envfile=$(_persist_agent_env "$asurl" "$token" "$access_token" "$agent_room_id" "$envfile" "$node_id"); then
    phase_set S6_WIRE_LOCAL failed "persistent env write failed"
    fail "failed to persist Direxio MCP/plugin env vars."
  fi
  state_set agent_env_file "$envfile" 2>/dev/null || true
  state_set agent_node_id "$node_id" 2>/dev/null || true
  state_set agent_service_id "$service_id" 2>/dev/null || true
  state_set agent_service_dir "$service_dir" 2>/dev/null || true
  state_set agent_credentials_file "$node_cred" 2>/dev/null || true
  state_set agent_workspace "$workspace" 2>/dev/null || true

  # 3) Installation is runtime-specific and may mutate agent config, so the skill
  # asks the user for confirmation after deployment instead of doing it blindly.
  install_policy=$(_agent_install_policy)
  install_mode=$(_agent_install_mode "$runtime")
  install_command=$(_agent_install_command "$runtime" "$install_mode" "$node_cred" "$node_id" "$workspace")
  skill_path=$(_agent_skill_install_path "$runtime")
  global_skill_path=$(_agent_global_skill_install_path "$runtime")
  mcp_config_path=$(_agent_mcp_config_path "$runtime" "$node_id")
  install_target_summary=$(_agent_install_target_summary "$runtime" "$mcp_config_path")
  state_set agent_runtime "$runtime" 2>/dev/null || true
  state_set agent_install_policy "$install_policy" 2>/dev/null || true
  state_set agent_install_mode "$install_mode" 2>/dev/null || true
  state_set agent_install_command "$install_command" 2>/dev/null || true
  state_set agent_skill_install_path "$skill_path" 2>/dev/null || true
  state_set agent_global_skill_install_path "$global_skill_path" 2>/dev/null || true
  state_set agent_mcp_config_path "$mcp_config_path" 2>/dev/null || true
  state_set agent_install_target_summary "$install_target_summary" 2>/dev/null || true
  state_set direxio_mcp_package "@direxio/local-mcp" 2>/dev/null || true
  state_set direxio_agent_plugins_package "@direxio/agent-plugins" 2>/dev/null || true
  state_set direxio_plugin_repo "@direxio/agent-plugins" 2>/dev/null || true
  _print_mcp_plugin_guidance "$runtime" "$asurl" "$node_cred" "$envfile" "$install_policy" "$install_mode" "$install_command" "$node_id"
  _maybe_auto_install_agent "$install_policy" "$runtime" "$install_mode" "$node_cred" "$install_command" "$node_id" "$workspace"

  phase_set S6_WIRE_LOCAL done "credentials.json written;node_id=$node_id;service_id=$service_id;env_file=$envfile;runtime=$runtime;install_policy=$install_policy;install_mode=$install_mode;mcp_config=$mcp_config_path;mcp_package=@direxio/local-mcp"
  return 0
}
