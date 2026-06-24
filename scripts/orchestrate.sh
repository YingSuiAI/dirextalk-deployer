#!/usr/bin/env bash
# orchestrate.sh - p2p-matrix deployment state-machine engine.
#
# Turns "one AWS credential -> working IM server -> local MCP" into 8 phases
# (S0..S7). State is persisted to $P2P_WORKDIR/state.json and supports:
#   - resume: continue from the first unfinished phase
#   - checkpoints: wait for user/AWS actions without losing progress
#   - destroy: every AWS resource is recorded for destroy.sh
#
# Usage:
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
#   export MESSAGE_SERVER_IMAGE=direxio/message-server:latest
#   # First run asks for region, production domain, instance size, and existing-state handling.
#   # Non-interactive:
#   #   DOMAIN=im.example.com DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 INSTANCE_TYPE=t3.small
#   bash orchestrate.sh                 # run or resume until completion
#   bash orchestrate.sh status          # show current state only
#   bash orchestrate.sh reset           # archive state.json; destroy will no longer know the resources
#
# Exit codes: 0=DONE / 1=phase failed / 2=waiting for user action.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
P2P_INSTALL_SCRIPTS_DIR="$HERE"

# Prefer workspace-local tools when present. On Windows, jq may be downloaded
# into .tools/bin/jq.exe by the operator/system and is discoverable from
# Git Bash/MSYS only when this path is prepended.
REPO_ROOT=$(cd "$HERE/.." && pwd)
if [ -d "$REPO_ROOT/.tools/bin" ]; then
  PATH="$REPO_ROOT/.tools/bin:$PATH"
  export PATH
fi

source "$HERE/lib/state.sh"
source "$HERE/lib/aws.sh"
source "$HERE/lib/domain.sh"

# Phase -> script mapping. Use case instead of declare -A for macOS bash 3.2.
phase_file() {
  case "$1" in
    S0_PREREQ_AWS)      echo "$HERE/phases/s0_prereq_aws.sh" ;;
    S1_PREFLIGHT)       echo "$HERE/phases/s1_preflight.sh" ;;
    S2_DOMAIN)          echo "$HERE/phases/s2_domain.sh" ;;
    S3_PROVISION)       echo "$HERE/phases/s3_provision.sh" ;;
    S4_BOOTSTRAP_STACK) echo "$HERE/phases/s4_bootstrap_stack.sh" ;;
    S5_INIT_TOKENS)     echo "$HERE/phases/s5_init_tokens.sh" ;;
    S6_WIRE_LOCAL)      echo "$HERE/phases/s6_wire_local.sh" ;;
    S7_VERIFY_E2E)      echo "$HERE/phases/s7_verify_e2e.sh" ;;
    *)                  echo "" ;;
  esac
}

# Dependency check.
check_deps() {
  local b missing=""
  for b in aws jq ssh scp curl; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  [ -z "$missing" ] && return 0

  warn "Missing dependencies:$missing"
  case " $missing " in
    *" jq "*)
      warn "jq is required for state.json. If this workspace has .tools/bin/jq.exe, run from a POSIX shell that can see that path."
      ;;
  esac
  case " $missing " in
    *" aws "*)
      warn "Install AWS CLI v2 and configure credentials first:"
      warn "  macOS: curl 'https://awscli.amazonaws.com/AWSCLIV2.pkg' -o AWSCLIV2.pkg && sudo installer -pkg ./AWSCLIV2.pkg -target /"
      warn "  Linux x86_64: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install"
      warn "  Configure: aws configure --profile p2p-matrix"
      warn "  Use: export AWS_PROFILE=p2p-matrix AWS_DEFAULT_REGION=<region>"
      warn "See references/user-journey.md for the AWS CLI setup guide."
      ;;
  esac
  warn "On Windows, use a working POSIX Bash environment such as Git Bash, MSYS2, Cygwin, or WSL. Do not assume C:\\Windows\\System32\\bash.exe is usable; verify with: bash -lc 'echo ok'."
  fail "Install the missing dependencies and rerun."
}

# Run one phase by sourcing its script, then clear run_phase to avoid leakage.
run_one_phase() {
  local ph=$1 file; file=$(phase_file "$1")
  [ -n "$file" ] && [ -f "$file" ] || fail "Phase script not found: $ph ($file)"
  unset -f run_phase 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$file"
  run_phase
}

# Print current state summary.
cmd_status() {
  state_ensure
  echo "run_id     : $(state_get run_id)"
	  echo "region     : $(state_get region)"
	  echo "domain_mode: $(state_get domain_mode)"
	  echo "domain     : $(state_get domain)"
	  echo "instance   : $(state_get instance_type)"
	  echo "dns_ready  : $(state_get dns_ready)"
  echo "current    : $(first_unfinished_phase)"
  echo "-- phases --"
  local p
  for p in "${PHASES[@]}"; do
    printf "  %-20s %s\n" "$p" "$(phase_status "$p")"
  done
  echo "-- resources --"
  jq -r '.resources | to_entries[]? | "  \(.key)=\(.value)"' "$STATE_JSON"
}

# Delivery summary.
print_delivery() {
  local domain asurl password keyfile pubip iid region statejson envfile agent_room_id runtime mcp_package plugin_pkg install_policy install_mode install_status install_command
  local agent_node_id agent_service_dir agent_cred
  domain=$(state_get domain); asurl=$(state_get as_url)
  password=$(state_get password)
  keyfile=$(res_get key_file); pubip=$(res_get public_ip)
  iid=$(res_get instance_id); region=$(state_get region); statejson="$STATE_JSON"
  envfile=$(state_get agent_env_file)
  agent_node_id=$(state_get agent_node_id)
  agent_service_dir=$(state_get agent_service_dir)
  agent_cred=$(state_get agent_credentials_file)
  agent_room_id=$(state_get agent_room_id)
  runtime=$(state_get agent_runtime)
  mcp_package=$(state_get direxio_mcp_package)
  plugin_pkg=$(state_get direxio_agent_plugins_package)
  [ -n "$plugin_pkg" ] || plugin_pkg=$(state_get direxio_plugin_repo)
  install_policy=$(state_get agent_install_policy)
  install_mode=$(state_get agent_install_mode)
  install_status=$(state_get agent_install_status)
  install_command=$(state_get agent_install_command)
  echo
  echo -e "\033[32m========== Deployment Complete ==========\033[0m"
  echo "  IM URL       : ${asurl:-https://$domain}"
  echo "  password     : $password   <- paste into the IM login form"
  echo "  agent node   : ${agent_node_id:-default}"
  echo "  service dir  : ${agent_service_dir:-not recorded}"
  echo "  tokens       : password, access_token, and agent_token written to ${agent_cred:-~/.direxio/nodes/<service_id>/credentials.json}"
  echo "  agent room   : ${agent_room_id:-written to credentials.json}"
  echo "  MCP package  : ${mcp_package:-@direxio/local-mcp}"
  echo "  plugins pkg  : ${plugin_pkg:-@direxio/agent-plugins}"
  echo "  agent runtime: ${runtime:-unknown}"
  echo "  install mode : policy=${install_policy:-recommend} mode=${install_mode:-recommended} status=${install_status:-recommend}"
  [ -n "$install_command" ] && echo "  install cmd  : $install_command"
  echo "  gateway send : npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room \"\$DIREXIO_AGENT_ROOM_ID\" --message \"hello\""
  echo "  env vars     : DIREXIO_DOMAIN, DIREXIO_AGENT_TOKEN, DIREXIO_AGENT_ROOM_ID persisted${envfile:+ via $envfile}"
  echo "  AWS region   : $region"
  echo "  EC2          : $iid ($pubip)"
  echo "  SSH          : ssh -i $keyfile ubuntu@$pubip"
  echo "  state.json   : $statejson"
  echo "  Destroy      : bash $HERE/destroy.sh"
  echo "  Note         : run destroy when finished, otherwise EC2/EIP resources keep billing."
}

ensure_region_selected() {
  local region
  region=$(state_get region)
  if [ -z "$region" ]; then
    region=${AWS_DEFAULT_REGION:-${AWS_REGION:-}}
    [ -z "$region" ] && region=$(aws_configured_region)
    if [ -z "$region" ] && [ -t 0 ]; then
      warn "Choose an AWS region. Region affects latency, price, default VPC, and EC2 quota."
      printf "AWS region [us-east-1]: " >&2
      read -r region
      region=${region:-us-east-1}
    fi
    if [ -z "$region" ]; then
      warn "Confirm AWS region first. This script will not silently default to us-east-1."
      warn "Set it with aws configure or AWS_DEFAULT_REGION."
      warn "Example: AWS_DEFAULT_REGION=ap-southeast-1 bash $0"
      warn "Or:      AWS_DEFAULT_REGION=us-east-1 bash $0"
      return 2
    fi
    state_set region "$region"
  fi
  export AWS_DEFAULT_REGION="$region"
  return 0
}

precheck_new_deploy_domain_env() {
  local domain
  domain=$(domain_normalize "${DOMAIN:-}")
  [ -f "$STATE_JSON" ] && return 0
  if [ "${DOMAIN_MODE:-}" = "ec2" ]; then
    warn "Deployment blocked: DOMAIN_MODE=ec2 temporary-domain mode has been removed."
    warn "Prepare a production domain and use DOMAIN=im.example.com DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1."
    return 2
  fi
  if [ -z "$domain" ]; then
    warn "Deployment blocked: DOMAIN is missing. P2P-IM requires a confirmed production Matrix server_name."
    warn "Use this skill to prepare domain/DNS, then rerun:"
    warn "  DOMAIN=im.example.com DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  if ! domain_is_formal_name "$domain"; then
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as im.example.com. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
    return 2
  fi
  if [ "${CONFIRM_DOMAIN_BINDING:-0}" != "1" ]; then
    warn "Deployment blocked: Matrix server_name domain binding has not been confirmed."
    warn "Rerun after confirmation:"
    warn "  DOMAIN=$domain DOMAIN_MODE=${DOMAIN_MODE:-user} CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  return 0
}

ensure_production_domain_selected() {
  local state_domain state_mode env_domain domain mode confirmed
  state_domain=$(state_get domain)
  state_domain=$(domain_normalize "$state_domain")
  state_mode=$(state_get domain_mode)
  env_domain=$(domain_normalize "${DOMAIN:-}")
  confirmed=$(jq -r '.domain_confirmed_irreversible // false' "$STATE_JSON")

  if [ -n "$env_domain" ] && [ -n "$state_domain" ] && [ "$env_domain" != "$state_domain" ]; then
    warn "Deployment blocked: current state is bound to DOMAIN=$state_domain, but this run passed DOMAIN=${env_domain}."
    warn "Do not switch Matrix server_name inside the same deployment state. Continue with the old domain, destroy and rebuild, or use a new P2P_WORKDIR."
    return 2
  fi
  if [ -n "${DOMAIN_MODE:-}" ] && [ -n "$state_mode" ] && [ "$DOMAIN_MODE" != "$state_mode" ]; then
    warn "Deployment blocked: current state is bound to DOMAIN_MODE=$state_mode, but this run passed DOMAIN_MODE=${DOMAIN_MODE}."
    warn "Continue with the old mode, destroy and rebuild, or use a new P2P_WORKDIR."
    return 2
  fi

  domain=${env_domain:-$state_domain}
  mode=${DOMAIN_MODE:-$state_mode}

  if [ "$mode" = "ec2" ]; then
    warn "Deployment blocked: DOMAIN_MODE=ec2 temporary-domain mode has been removed."
    warn "Prepare a production domain and use DOMAIN=im.example.com DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1."
    return 2
  fi
  if [ -z "$domain" ]; then
    warn "Deployment blocked: DOMAIN is missing. P2P-IM requires a confirmed production Matrix server_name."
    warn "Use this skill to prepare domain/DNS, then rerun:"
    warn "  DOMAIN=im.example.com DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  if ! domain_is_formal_name "$domain"; then
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as im.example.com. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
    return 2
  fi
  if [ "$confirmed" != "true" ] && [ "${CONFIRM_DOMAIN_BINDING:-0}" != "1" ]; then
    warn "Deployment blocked: Matrix server_name domain binding has not been confirmed."
    warn "After $domain becomes server_name, changing the domain is effectively a new homeserver identity."
    warn "Rerun after confirmation:"
    warn "  DOMAIN=$domain DOMAIN_MODE=${mode:-user} CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  return 0
}

guard_existing_state() {
  [ -f "$STATE_JSON" ] || return 0
  local resources_count confirmed action
  resources_count=$(jq -r '.resources | length' "$STATE_JSON")
  [ "$resources_count" -eq 0 ] && return 0
  if [ "$(jq -r '.domain_mode // empty' "$STATE_JSON")" = "ec2" ]; then
    warn "Found legacy temporary-domain deployment state (domain_mode=ec2). Production deployment no longer supports resuming this mode."
    warn "Destroy and rebuild, or use a new P2P_WORKDIR:"
    warn "  P2P_EXISTING_STATE_ACTION=destroy bash $0"
    warn "  P2P_WORKDIR=~/.direxio/deploy-new DOMAIN=im.example.com DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  confirmed=$(jq -r '.existing_state_confirmed // false' "$STATE_JSON")
  [ "$confirmed" = "true" ] && return 0

  action=${P2P_EXISTING_STATE_ACTION:-}
  if [ -z "$action" ] && [ -t 0 ]; then
    warn "Found existing deployment state with recorded AWS resources:"
    jq -r '.resources | to_entries[]? | "  \(.key)=\(.value)"' "$STATE_JSON" >&2
    warn "Choose: continue=resume / destroy=destroy and rebuild / abort=stop now"
    printf "Action [abort]: " >&2
    read -r action
    action=${action:-abort}
  fi

  case "$action" in
    continue)
      state_set_raw existing_state_confirmed 'true'
      warn "Continuing with existing state and resources."
      return 0 ;;
    destroy)
      warn "Destroying AWS resources recorded in state.json, then starting over."
      bash "$HERE/destroy.sh" "$STATE_JSON" || return 1
      return 0 ;;
    ""|abort)
      warn "Existing state must be handled explicitly to avoid accidental reuse or duplicate EC2 creation."
      warn "Resume:  P2P_EXISTING_STATE_ACTION=continue bash $0"
      warn "Rebuild: P2P_EXISTING_STATE_ACTION=destroy bash $0"
      warn "New dir: P2P_WORKDIR=~/.direxio/deploy-new bash $0"
      return 2 ;;
    *)
      warn "Unknown P2P_EXISTING_STATE_ACTION=$action (expected continue|destroy|abort)."
      return 2 ;;
  esac
}

# Main loop: start at the first unfinished phase.
cmd_run() {
  precheck_new_deploy_domain_env || return $?
  check_deps
  guard_existing_state || return $?
  state_ensure
  ensure_production_domain_selected || return $?
  ensure_region_selected || return $?
  log "State machine started. state.json = $STATE_JSON"

  while true; do
    local cur; cur=$(first_unfinished_phase)
    if [ "$cur" = "DONE" ]; then
      ok "All phases completed."
      print_delivery
      return 0
    fi
    log "Entering phase $cur (current status=$(phase_status "$cur"))"

    local rc=0
    run_one_phase "$cur" || rc=$?

    case "$rc" in
      0)  ok "Phase $cur completed." ;;
      2)  warn "Phase $cur is waiting for user action (credentials/quota/confirmation). Resolve it and rerun this script to resume."; return 2 ;;
      *)  warn "Phase $cur failed (rc=$rc). Fix it and rerun to resume, or run bash destroy.sh to remove resources."; return 1 ;;
    esac
  done
}

# Entry point.
case "${1:-run}" in
  run)    cmd_run ;;
  status) cmd_status ;;
  reset)
    [ -f "$STATE_JSON" ] && { mv "$STATE_JSON" "$STATE_JSON.reset-$(date -u +%Y%m%d%H%M%S)"; warn "Archived old state.json."; }
    warn "Warning: after reset, destroy no longer has state data. Any remaining AWS resources must be removed manually." ;;
  *) echo "Usage: $0 [run|status|reset]"; exit 1 ;;
esac
