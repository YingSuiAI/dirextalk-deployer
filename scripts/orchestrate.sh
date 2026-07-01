#!/usr/bin/env bash
# orchestrate.sh - Direxio deployment state-machine engine.
#
# Turns "one AWS credential -> working Direxio server -> local direxio-connect bridge" into 8 phases
# (S0..S7). State is persisted to $DIREXIO_WORKDIR/state.json and supports:
#   - resume: continue from the first unfinished phase
#   - checkpoints: wait for user/AWS actions without losing progress
#   - destroy: every AWS resource is recorded for destroy.sh
#
# Usage:
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
#   export MESSAGE_SERVER_IMAGE=direxio/message-server:latest
#   # First run asks for region, production domain, instance size, and existing-state handling.
#   # Non-interactive:
#   #   DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 INSTANCE_TYPE=t3.small
#   bash orchestrate.sh                 # run or resume until completion
#   DOMAIN=__DOMAIN__ bash orchestrate.sh status   # show current service state only
#   bash orchestrate.sh reset           # archive state.json; destroy will no longer know the resources
#
# Exit codes: 0=DONE / 1=phase failed / 2=waiting for user action.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DIREXIO_INSTALL_SCRIPTS_DIR="$HERE"

# Prefer workspace-local tools when present.
REPO_ROOT=$(cd "$HERE/.." && pwd)
if [ -d "$REPO_ROOT/.tools/bin" ]; then
  PATH="$REPO_ROOT/.tools/bin:$PATH"
  export PATH
fi

DIREXIO_WORKDIR_WAS_SET=${DIREXIO_WORKDIR+x}

source "$HERE/lib/state.sh"
source "$HERE/lib/aws.sh"
source "$HERE/lib/domain.sh"
source "$HERE/lib/operation_report.sh"
source "$HERE/lib/local-paths.sh"

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
  for b in aws ssh scp curl; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  [ -z "$missing" ] && return 0

  warn "Missing dependencies:$missing"
  case " $missing " in
    *" aws "*)
      warn "Install AWS CLI v2 and configure credentials first:"
      warn "  macOS: curl 'https://awscli.amazonaws.com/AWSCLIV2.pkg' -o AWSCLIV2.pkg && sudo installer -pkg ./AWSCLIV2.pkg -target /"
      warn "  Linux x86_64: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install"
      warn "  Configure: aws configure --profile direxio-deployer"
      warn "  Use: export AWS_PROFILE=direxio-deployer AWS_DEFAULT_REGION=<region>"
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
cmd_status_inventory() {
  local nodes state found=0 domain phase current instance service_dir
  nodes="${DIREXIO_HOME:-$HOME/.direxio}/nodes"
  if [ ! -d "$nodes" ]; then
    warn "No local service directory found: $nodes"
    warn "Set DOMAIN=<service domain> when running or inspecting a specific deployment."
    return 0
  fi

  echo "local services: $nodes"
  for state in "$nodes"/*/state.json; do
    [ -f "$state" ] || continue
    found=1
    service_dir=${state%/state.json}
    domain=$(json_get "$state" domain)
    phase=$(json_get "$state" phase)
    instance=$(json_get "$state" resources.instance_id)
    if STATE_JSON="$state" first_unfinished_phase >/dev/null 2>&1; then
      current=$(STATE_JSON="$state" first_unfinished_phase)
    else
      current=${phase:-unknown}
    fi
    printf "  %-32s current=%-18s instance=%s\n" "${domain:-$(basename "$service_dir")}" "${current:-unknown}" "${instance:-none}"
    printf "    service_dir=%s\n" "$service_dir"
    printf "    state_json=%s\n" "$state"
  done

  if [ "$found" -eq 0 ]; then
    warn "No service state files found under $nodes"
  fi
}

phase_user_meaning() {
  case "$1" in
    S0_PREREQ_AWS)      echo "AWS credentials, CLI tooling, or account identity are not ready." ;;
    S1_PREFLIGHT)       echo "AWS region, default VPC, EC2/EIP quota, or Ubuntu AMI checks are not ready." ;;
    S2_DOMAIN)          echo "The long-lived domain, DNS authority, or irreversible Matrix server_name binding is not confirmed." ;;
    S3_PROVISION)       echo "AWS infrastructure provisioning, fixed public IP, security group, or DNS record setup is not complete." ;;
    S4_BOOTSTRAP_STACK) echo "The EC2 instance exists, but cloud-init, Docker, Caddy/TLS, or message-server has not reached healthy state." ;;
    S5_INIT_TOKENS)     echo "The server is not yet returning fresh bootstrap credentials from /opt/p2p/bootstrap.json." ;;
    S6_WIRE_LOCAL)      echo "The cloud service is likely up, but local direxio-connect, service credentials, or MCP snippets are not wired." ;;
    S7_VERIFY_E2E)      echo "The deployed service failed one or more final automated health, Matrix, CORS, TURN, or API checks." ;;
    DONE)               echo "Automated S0-S7 checks are complete." ;;
    *)                  echo "The deployment state is incomplete or unknown." ;;
  esac
}

phase_at_or_after_s3() {
  case "$1" in
    S3_PROVISION|S4_BOOTSTRAP_STACK|S5_INIT_TOKENS|S6_WIRE_LOCAL|S7_VERIFY_E2E|DONE) return 0 ;;
    *) return 1 ;;
  esac
}

recorded_billable_resources() {
  local iid volume pubip eip zone out=""
  iid=$(res_get instance_id)
  volume=$(res_get root_volume_id)
  pubip=$(res_get public_ip)
  eip=$(res_get eip_id)
  zone=$(res_get route53_zone_id)
  [ -n "$iid" ] && out="EC2 $iid"
  if [ -n "$volume" ]; then
    [ -n "$out" ] && out="$out, "
    out="${out}EBS root volume $volume"
  fi
  if [ -n "$pubip" ]; then
    [ -n "$out" ] && out="$out, "
    out="${out}public IPv4 $pubip"
  fi
  if [ -n "$eip" ]; then
    [ -n "$out" ] && out="$out, "
    out="${out}Elastic IP $eip"
  fi
  if [ -n "$zone" ]; then
    [ -n "$out" ] && out="$out, "
    out="${out}Route53 hosted zone $zone"
  fi
  printf '%s\n' "$out"
}

status_billing_impact() {
  local current=$1 billable
  billable=$(recorded_billable_resources)
  if [ -n "$billable" ]; then
    echo "recorded AWS resources may keep billing: $billable"
  elif phase_at_or_after_s3 "$current"; then
    echo "S3 or later may have created billable AWS resources; inspect AWS if state is incomplete"
  else
    echo "no EC2, public IPv4, or EBS resource is recorded yet"
  fi
}

status_resume_safety() {
  local current=$1 billable
  billable=$(recorded_billable_resources)
  if [ -n "$billable" ] || phase_at_or_after_s3 "$current"; then
    echo "do not reset state; fix the issue and rerun with DIREXIO_EXISTING_STATE_ACTION=continue"
  else
    echo "safe to rerun the same command after the next action is complete"
  fi
}

local_refresh_pending() {
  [ "$(state_get connect_install_status)" = "refresh_pending" ]
}

status_local_refresh() {
  if local_refresh_pending; then
    echo "reset/redeploy cleared old credentials, user confirmations, runtime checks, bridge install proof, and MCP install proof"
  fi
}

status_next_action() {
  if local_refresh_pending; then
    case "$1" in
      S4_BOOTSTRAP_STACK|S5_INIT_TOKENS|S6_WIRE_LOCAL|S7_VERIFY_E2E|DONE)
        echo "rerun the deployment workflow to refresh S4-S7, local credentials, MCP snippets, automatic installs, and runtime checks"
        return 0
        ;;
    esac
  fi

  case "$1" in
    S0_PREREQ_AWS)      echo "configure AWS CLI credentials for the selected deployment identity and rerun status" ;;
    S1_PREFLIGHT)       echo "fix AWS region, default VPC, EC2/EIP quota, or AMI availability before creating resources" ;;
    S2_DOMAIN)          echo "confirm the long-lived domain, DNS authority, and irreversible Matrix server_name binding" ;;
    S3_PROVISION)       echo "inspect EC2 provisioning, Elastic IP allocation, security group creation, and DNS record setup" ;;
    S4_BOOTSTRAP_STACK) echo "inspect cloud-init, Docker, Caddy/TLS, and message-server logs over SSH" ;;
    S5_INIT_TOKENS)     echo "inspect /opt/p2p/bootstrap.json, init-tokens.sh, and message-server bootstrap logs" ;;
    S6_WIRE_LOCAL)      echo "refresh local credentials, direxio-connect config, MCP snippets, and agent runtime settings without destroying cloud resources" ;;
    S7_VERIFY_E2E)      echo "inspect the failed health, Matrix, well-known, owner.json/CORS, TURN, MCP, or runtime gate before declaring delivery" ;;
    DONE)               echo "give the user the App domain and eight-digit initialization code, then record App initialization and agent/MCP confirmation separately" ;;
    *)                  echo "inspect state.json and the current phase evidence before taking action" ;;
  esac
}

status_stop_loss() {
  local domain billable
  domain=$(state_get domain)
  billable=$(recorded_billable_resources)
  if [ -z "$billable" ]; then
    echo "no recorded cloud resources need destroy from this state"
  else
    echo "ask the agent to run destroy, or run:"
    if [ "${DIREXIO_LOCAL_PATH_STYLE:-}" = "windows" ] || [ -n "${DIREXIO_WINDOWS_HOME:-}" ]; then
      echo "  \$env:DOMAIN = \"${domain:-__DOMAIN__}\"; .\\scripts\\destroy.ps1"
    else
      echo "  DOMAIN=${domain:-__DOMAIN__} bash $HERE/destroy.sh"
    fi
    echo "  Purchased domains, third-party DNS records, and retained hosted zones are not automatically removed."
  fi
}

print_recovery_summary() {
  local current=$1 status refresh
  status=$(phase_status "$current")
  refresh=$(status_local_refresh)
  echo "-- Recovery summary --"
  echo "Where it is blocked: $current (${status:-unknown}) - $(phase_user_meaning "$current")"
  echo "Billing impact: $(status_billing_impact "$current")"
  echo "Resume safety: $(status_resume_safety "$current")"
  [ -z "$refresh" ] || echo "Local refresh: $refresh"
  echo "Next action: $(status_next_action "$current")"
  printf "Stop-loss: "
  status_stop_loss
}

cmd_status() {
  if [ ! -f "$STATE_JSON" ]; then
    if [ -z "${DOMAIN:-}" ] && [ -z "$DIREXIO_WORKDIR_WAS_SET" ]; then
      cmd_status_inventory
      return 0
    fi
    warn "state.json not found: $STATE_JSON"
    warn "Set DOMAIN=<service domain> or explicit DIREXIO_WORKDIR=<service dir> to inspect a specific deployment."
    return 0
  fi
  echo "run_id     : $(state_get run_id)"
	  echo "region     : $(state_get region)"
	  echo "domain_mode: $(state_get domain_mode)"
	  echo "domain     : $(state_get domain)"
	  echo "instance   : $(state_get instance_type)"
	  echo "dns_ready  : $(state_get dns_ready)"
  echo "current    : $(first_unfinished_phase)"
  local current
  current=$(first_unfinished_phase)
  echo "-- phases --"
  local p
  for p in "${PHASES[@]}"; do
    printf "  %-20s %s\n" "$p" "$(phase_status "$p")"
  done
  echo "-- resources --"
  json_entries "$STATE_JSON" resources | sed 's/^/  /'
  print_recovery_summary "$current"
}

# Delivery summary.
print_delivery() {
  local domain password keyfile pubip iid region statejson envfile agent_room_id runtime install_policy install_mode install_status install_command
  local agent_node_id agent_service_id agent_service_dir agent_cred cc_config cc_binary cc_agent cc_user cc_pkg
  local report_path runtime_summary app_gate real_chat_gate agent_runtime_gate
  domain=$(state_get domain)
  password=$(state_get password)
  if ! printf '%s' "$password" | grep -Eq '^[0-9]{8}$'; then
    warn "state password field is not an exact eight-digit initialization code; rerun S5_INIT_TOKENS before reporting it."
    return 1
  fi
  keyfile=$(res_get key_file); pubip=$(res_get public_ip)
  iid=$(res_get instance_id); region=$(state_get region); statejson="$STATE_JSON"
  envfile=$(state_get agent_env_file)
  agent_node_id=$(state_get agent_node_id)
  agent_service_id=$(state_get agent_service_id)
  agent_service_dir=$(state_get agent_service_dir)
  agent_cred=$(state_get agent_credentials_file)
  agent_room_id=$(state_get agent_room_id)
  runtime=$(state_get agent_runtime)
  cc_config=$(state_get connect_config)
  cc_binary=$(state_get connect_binary)
  cc_agent=$(state_get connect_agent)
  cc_user=$(state_get connect_matrix_user)
  cc_pkg=$(state_get connect_npm_package)
  install_policy=$(state_get connect_install_policy)
  install_mode=$(state_get connect_install_mode)
  install_status=$(state_get connect_install_status)
  install_command=$(state_get connect_install_command)
  runtime_summary=$(json_get "$STATE_JSON" runtime_checks.summary.status "not_run")
  app_gate=$(json_get "$STATE_JSON" user_confirmations.app_initialization.status "pending_user_confirmation")
  real_chat_gate=$(json_get "$STATE_JSON" user_confirmations.real_chat.status "pending_user_confirmation")
  agent_runtime_gate=$(json_get "$STATE_JSON" user_confirmations.agent_mcp_runtime.status "pending_runtime_confirmation")
  echo
  echo -e "\033[32m========== Automated Deployment Gates Passed ==========\033[0m"
  echo "  App domain   : $domain"
  echo "  init code    : $password   <- enter in the App initialization flow"
  echo "  status       : server automation is green; product completion waits for user/runtime confirmation"
  echo "  user gates   : app_initialization=$app_gate real_chat=$real_chat_gate agent_mcp_runtime=$agent_runtime_gate"
  echo "  runtime check: ${runtime_summary:-not_run}"
  echo "  agent node   : ${agent_node_id:-default}"
  echo "  service id   : ${agent_service_id:-not recorded}"
  echo "  service dir  : ${agent_service_dir:-not recorded}"
  echo "  credentials  : init code/password field, access_token, and agent_token written to ${agent_cred:-~/.direxio/nodes/<service_id>/credentials.json}"
  echo "  agent room   : ${agent_room_id:-written to credentials.json}"
  echo "  direxio-connect   : package=${cc_pkg:-direxio-connent@latest} config=${cc_config:-not recorded} command=${cc_binary:-direxio-connect}"
  echo "  matrix user  : ${cc_user:-created during S6}"
  echo "  agent runtime: ${runtime:-unknown}"
  echo "  install mode : policy=${install_policy:-recommend} mode=${install_mode:-direxio-connect} agent=${cc_agent:-codex} status=${install_status:-recommend}"
  [ -n "$install_command" ] && echo "  install cmd  : $install_command"
  echo "  daemon       : ${cc_binary:-direxio-connect} daemon status --service-name ${agent_service_id:-direxio-connect}"
  echo "  env vars     : DIREXIO_DOMAIN, DIREXIO_AGENT_TOKEN, DIREXIO_AGENT_ROOM_ID persisted${envfile:+ via $envfile}"
  echo "  AWS region   : $region"
  echo "  EC2          : $iid ($pubip)"
  echo "  SSH          : ssh -i $keyfile ubuntu@$pubip"
  echo "  state.json   : $statejson"
  echo "  stop billing : ask the agent to destroy this node when finished"
  echo "  Note         : EC2/public IPv4/EBS resources keep billing until destroy is run."
  echo "  security     : delete/disable temporary IAM keys after deployment; rotate/remove root keys if used."
  echo "  Product gate : S7 is green; final product completion still needs App initialization and agent/MCP runtime confirmation."
  if report_path=$(operation_report_write new_deploy automated_gates_complete_user_confirmation_pending "$STATE_JSON" 2>/dev/null); then
    echo "  report       : $report_path"
  else
    echo "  report       : not written; run bash $0 report new_deploy"
  fi
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

ensure_cost_estimate() {
  local output status total region instance_type args
  args=(--state "$STATE_JSON" --write-state)
  if [ -n "${INSTANCE_TYPE:-}" ]; then
    args+=(--instance-type "$INSTANCE_TYPE")
  fi

  if output=$(bash "$HERE/pricing-estimate.sh" "${args[@]}" 2>/dev/null); then
    status=$(printf '%s\n' "$output" | json_stdin_get pricing_status "unknown" 2>/dev/null)
    total=$(printf '%s\n' "$output" | json_stdin_get total_monthly_usd "unknown" 2>/dev/null)
    region=$(printf '%s\n' "$output" | json_stdin_get region "unknown" 2>/dev/null)
    instance_type=$(printf '%s\n' "$output" | json_stdin_get components.ec2_instance.instance_type "unknown" 2>/dev/null)
    log "Cost estimate recorded (status=${status:-unknown}, region=${region:-unknown}, instance=${instance_type:-unknown}, monthly_usd≈${total:-unknown})."
    if [ "$status" = "fallback" ]; then
      warn "AWS Pricing API was unavailable or incomplete; cost_estimate uses conservative fallback values."
    fi
  else
    warn "Could not write AWS cost estimate. Continue only after giving the user a manual billing estimate."
  fi
  ensure_free_tier_credit_notice
}

ensure_free_tier_credit_notice() {
  local output plan_status plan_type amount unit expires
  if output=$(aws freetier get-account-plan-state --output json 2>/dev/null); then
    plan_type=$(printf '%s\n' "$output" | json_stdin_get accountPlanType "unknown" 2>/dev/null)
    plan_status=$(printf '%s\n' "$output" | json_stdin_get accountPlanStatus "unknown" 2>/dev/null)
    amount=$(printf '%s\n' "$output" | json_stdin_get accountPlanRemainingCredits.amount "" 2>/dev/null)
    unit=$(printf '%s\n' "$output" | json_stdin_get accountPlanRemainingCredits.unit "USD" 2>/dev/null)
    expires=$(printf '%s\n' "$output" | json_stdin_get accountPlanExpirationDate "" 2>/dev/null)
    if [ -n "$amount" ]; then
      log "AWS Free Tier plan: type=${plan_type:-unknown}, status=${plan_status:-unknown}, remaining_credits=${amount} ${unit:-USD}${expires:+, expires=$expires}."
      warn "Credits can reduce actual charges, but AWS resources still accrue charges until destroyed; verify credit coverage in AWS Billing Console."
      return 0
    fi
  fi
  warn "AWS new customer accounts may include Free Tier credits, currently advertised as 100 USD initial credits plus possible additional credits."
  warn "Credits may cover a small trial deployment, but coverage is account-specific; verify credits in AWS Billing Console and destroy the node when finished."
}

precheck_new_deploy_domain_env() {
  local domain
  domain=$(domain_normalize "${DOMAIN:-}")
  [ -f "$STATE_JSON" ] && return 0
  if [ "${DOMAIN_MODE:-}" = "ec2" ]; then
    warn "Deployment blocked: DOMAIN_MODE=ec2 temporary-domain mode has been removed."
    warn "Prepare a production domain and use DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1."
    return 2
  fi
  if [ -z "$domain" ]; then
    warn "Deployment blocked: DOMAIN is missing. Direxio requires a confirmed production Matrix server_name."
    warn "Use this skill to prepare domain/DNS, then rerun:"
    warn "  DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  if ! domain_is_formal_name "$domain"; then
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as __DOMAIN__. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
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
  confirmed=$(json_get "$STATE_JSON" domain_confirmed_irreversible false)

  if [ -n "$env_domain" ] && [ -n "$state_domain" ] && [ "$env_domain" != "$state_domain" ]; then
    warn "Deployment blocked: current state is bound to DOMAIN=$state_domain, but this run passed DOMAIN=${env_domain}."
    warn "Do not switch Matrix server_name inside the same service state. Continue with the old domain, destroy and rebuild, or use a different DOMAIN/service directory."
    return 2
  fi
  if [ -n "${DOMAIN_MODE:-}" ] && [ -n "$state_mode" ] && [ "$DOMAIN_MODE" != "$state_mode" ]; then
    warn "Deployment blocked: current state is bound to DOMAIN_MODE=$state_mode, but this run passed DOMAIN_MODE=${DOMAIN_MODE}."
    warn "Continue with the old mode, destroy and rebuild, or use a different DOMAIN/service directory."
    return 2
  fi

  domain=${env_domain:-$state_domain}
  mode=${DOMAIN_MODE:-$state_mode}

  if [ "$mode" = "ec2" ]; then
    warn "Deployment blocked: DOMAIN_MODE=ec2 temporary-domain mode has been removed."
    warn "Prepare a production domain and use DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1."
    return 2
  fi
  if [ -z "$domain" ]; then
    warn "Deployment blocked: DOMAIN is missing. Direxio requires a confirmed production Matrix server_name."
    warn "Use this skill to prepare domain/DNS, then rerun:"
    warn "  DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  if ! domain_is_formal_name "$domain"; then
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as __DOMAIN__. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
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
  resources_count=$(json_length "$STATE_JSON" resources)
  [ "$resources_count" -eq 0 ] && return 0
  if [ "$(json_get "$STATE_JSON" domain_mode)" = "ec2" ]; then
    warn "Found legacy temporary-domain deployment state (domain_mode=ec2). Production deployment no longer supports resuming this mode."
    warn "Destroy and rebuild, or use a new service directory:"
    warn "  DIREXIO_EXISTING_STATE_ACTION=destroy bash $0"
    warn "  DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  confirmed=$(json_get "$STATE_JSON" existing_state_confirmed false)
  [ "$confirmed" = "true" ] && return 0

  action=${DIREXIO_EXISTING_STATE_ACTION:-}
  if [ -z "$action" ] && [ -t 0 ]; then
    warn "Found existing deployment state with recorded AWS resources:"
    json_entries "$STATE_JSON" resources | sed 's/^/  /' >&2
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
      warn "Existing service state must be handled explicitly to avoid accidental reuse or duplicate EC2 creation."
      warn "Resume:  DIREXIO_EXISTING_STATE_ACTION=continue bash $0"
      warn "Rebuild: DIREXIO_EXISTING_STATE_ACTION=destroy bash $0"
      warn "New service: DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash $0"
      return 2 ;;
    *)
      warn "Unknown DIREXIO_EXISTING_STATE_ACTION=$action (expected continue|destroy|abort)."
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
  ensure_cost_estimate
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
      *)  warn "Phase $cur failed (rc=$rc). Fix it and rerun to resume, or ask the agent to destroy this node to remove resources."; return 1 ;;
    esac
  done
}

cmd_report() {
  local operation=${1:-new_deploy} status report_path
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }
  case "$operation" in
    new_deploy) status=automated_gates_complete_user_confirmation_pending ;;
    repair_or_verify) status=verification_report ;;
    update) status=update_report ;;
    reset_app_data) status=reset_app_data_report ;;
    destroy) status=destroy_processed ;;
    *)
      echo "Usage: $0 report [new_deploy|repair_or_verify|update|reset_app_data|destroy]" >&2
      return 1
      ;;
  esac
  report_path=$(operation_report_write "$operation" "$status" "$STATE_JSON")
  echo "operation report: $report_path"
}

cmd_confirm() {
  local gate=${1:-} evidence=${DIREXIO_CONFIRM_EVIDENCE:-}
  local runtime_summary_status runtime_probe_confirmed
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }
  case "$gate" in
    app_initialization|real_chat|agent_mcp_runtime) ;;
    *)
      echo "Usage: $0 confirm [app_initialization|real_chat|agent_mcp_runtime]" >&2
      return 1
      ;;
  esac
  if [ -z "$evidence" ]; then
    warn "confirm $gate requires DIREXIO_CONFIRM_EVIDENCE with a concrete user/runtime evidence note."
    return 1
  fi
  if [ "${#evidence}" -lt 12 ]; then
    warn "DIREXIO_CONFIRM_EVIDENCE is too short; provide a concrete user/runtime evidence note."
    return 1
  fi
  runtime_summary_status=$(json_get "$STATE_JSON" runtime_checks.summary.status "not_run")
  runtime_probe_confirmed=false
  if [ "$gate" = "agent_mcp_runtime" ]; then
    if [ "$runtime_summary_status" != "passed" ]; then
      warn "agent_mcp_runtime confirmation requires runtime_checks.summary.status=passed. Run: DOMAIN=<DOMAIN> bash $0 verify runtime"
      return 1
    fi
    if [ "${DIREXIO_CONFIRM_RUNTIME_PROBE:-0}" != "1" ]; then
      warn "agent_mcp_runtime confirmation requires DIREXIO_CONFIRM_RUNTIME_PROBE=1 after the selected runtime/channel probe is actually confirmed."
      return 1
    fi
    runtime_probe_confirmed=true
  fi
  if [ "$gate" = "agent_mcp_runtime" ]; then
    state_set_object "user_confirmations.$gate" \
      status=confirmed \
      "ts=$(_now)" \
      "evidence=$evidence" \
      "runtime_summary_status=$runtime_summary_status" \
      "runtime_probe_confirmed=$runtime_probe_confirmed"
  else
    state_set_object "user_confirmations.$gate" \
      status=confirmed \
      "ts=$(_now)" \
      "evidence=$evidence"
  fi
  echo "confirmed gate: $gate"
}

cmd_verify_mcp_doctor() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local credentials mcp_cmd node_id out err report token_status report_domain report_room
  credentials=$(json_get "$STATE_JSON" agent_credentials_file)
  [ -n "$credentials" ] || credentials=$(json_get "$STATE_JSON" mcp_credentials_file)
  mcp_cmd=$(json_get "$STATE_JSON" mcp_command "direxio-mcp")
  node_id=$(json_get "$STATE_JSON" agent_node_id)
  [ -n "$credentials" ] || {
    warn "mcp doctor check requires agent_credentials_file or mcp_credentials_file in state.json"
    return 1
  }
  [ -n "$mcp_cmd" ] || mcp_cmd=direxio-mcp

  out=$(mktemp)
  err=$(mktemp)
  if ! DIREXIO_CREDENTIALS_FILE="$credentials" DIREXIO_AGENT_NODE_ID="$node_id" bash -c "$mcp_cmd doctor --json" > "$out" 2> "$err"; then
    state_set_object runtime_checks.mcp_doctor status=failed "ts=$(_now)" "evidence=direxio-mcp doctor failed"
    cat "$err" >&2
    rm -f "$out" "$err"
    return 1
  fi
  if ! json_valid "$out" >/dev/null 2>&1; then
    state_set_object runtime_checks.mcp_doctor status=failed "ts=$(_now)" "evidence=direxio-mcp doctor returned non-json output"
    rm -f "$out" "$err"
    return 1
  fi
  report=$(cat "$out")
  token_status=$(printf '%s\n' "$report" | json_stdin_get token)
  if [ "$token_status" = "redacted" ]; then
    token_status=redacted
  elif [ -n "$token_status" ]; then
    token_status=present_redacted
  else
    token_status=missing
  fi
  report_domain=$(json_get "$out" domain)
  report_room=$(json_get "$out" agent_room_id)
  state_set_object runtime_checks.mcp_doctor \
    status=passed \
    "ts=$(_now)" \
    "evidence=direxio-mcp doctor --json succeeded" \
    "domain=$report_domain" \
    "agent_room_id=$report_room" \
    "token=$token_status"
  rm -f "$out" "$err"
  echo "verified runtime check: mcp_doctor"
}

cmd_verify_mcp_smoke() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local service_url token room_id body code payload url response_room_id response_messages_type
  service_url=$(json_get "$STATE_JSON" as_url)
  if [ -z "$service_url" ]; then
    local domain
    domain=$(json_get "$STATE_JSON" domain)
    [ -n "$domain" ] && service_url="https://$domain"
  fi
  token=$(json_get "$STATE_JSON" agent_token)
  room_id=$(json_get "$STATE_JSON" agent_room_id)
  if [ -z "$service_url" ] || [ -z "$token" ] || [ -z "$room_id" ]; then
    warn "mcp smoke check requires as_url/domain, agent_token, and agent_room_id in state.json"
    return 1
  fi

  body=$(mktemp)
  payload=$(json_build mcp-messages-list "$room_id")
  url="${service_url%/}/_p2p/query"
  code=$(curl -sk -o "$body" -w '%{http_code}' \
    -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -d "$payload" 2>/dev/null)
  if [ "$code" != "200" ] || ! json_assert "$body" messages-response >/dev/null 2>&1; then
    state_set_object runtime_checks.mcp_smoke \
      status=failed \
      "ts=$(_now)" \
      action=mcp.messages.list \
      "evidence=mcp.messages.list returned HTTP $code or invalid response"
    rm -f "$body"
    return 1
  fi

  response_room_id=$(json_get "$body" room_id)
  response_messages_type=$(json_type "$body" messages)
  state_set_object runtime_checks.mcp_smoke \
    status=passed \
    "ts=$(_now)" \
    action=mcp.messages.list \
    "room_id=$room_id" \
    "response_room_id=$response_room_id" \
    "response_messages_type=$response_messages_type" \
    "evidence=read-only backend smoke check succeeded"
  rm -f "$body"
  echo "verified runtime check: mcp_smoke"
}

cmd_verify_mcp_tools() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local credentials mcp_cmd node_id node_cmd node_script out err report
  credentials=$(json_get "$STATE_JSON" agent_credentials_file)
  [ -n "$credentials" ] || credentials=$(json_get "$STATE_JSON" mcp_credentials_file)
  mcp_cmd=$(json_get "$STATE_JSON" mcp_command "direxio-mcp")
  node_id=$(json_get "$STATE_JSON" agent_node_id)
  [ -n "$credentials" ] || {
    warn "mcp tools check requires agent_credentials_file or mcp_credentials_file in state.json"
    return 1
  }
  [ -n "$mcp_cmd" ] || mcp_cmd=direxio-mcp
  node_cmd=$(_node_command)
  [ -n "$node_cmd" ] || {
    warn "mcp tools check requires node or node.exe to run scripts/mcp-tools-list.mjs"
    return 1
  }
  node_script=$(_node_script_path "$node_cmd" "$HERE/mcp-tools-list.mjs")

  out=$(mktemp)
  err=$(mktemp)
  if ! DIREXIO_CREDENTIALS_FILE="$credentials" DIREXIO_AGENT_NODE_ID="$node_id" "$node_cmd" "$node_script" "$mcp_cmd" > "$out" 2> "$err"; then
    state_set_object runtime_checks.mcp_tools status=failed "ts=$(_now)" "evidence=MCP tools/list failed"
    cat "$err" >&2
    rm -f "$out" "$err"
    return 1
  fi
  if ! json_assert "$out" tools-list >/dev/null 2>&1; then
    state_set_object runtime_checks.mcp_tools status=failed "ts=$(_now)" "evidence=MCP tools/list returned invalid output"
    rm -f "$out" "$err"
    return 1
  fi
  report=$(cat "$out")
  state_set_object runtime_checks.mcp_tools \
    status=passed \
    "ts=$(_now)" \
    "evidence=MCP tools/list succeeded" \
    "tool_count=$(json_get "$out" tool_count 0)" \
    "tools=$(json_get "$out" tools "[]")"
  rm -f "$out" "$err"
  echo "verified runtime check: mcp_tools"
}

_node_command() {
  json_node
}

_node_script_path() {
  local node_cmd=$1 script=$2
  case "$node_cmd" in
    *.exe|*.EXE)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$script"
        return 0
      fi
      case "$script" in
        /mnt/[A-Za-z]/*)
          local drive rest
          drive=${script#/mnt/}
          drive=${drive%%/*}
          rest=${script#/mnt/$drive/}
          printf '%s:\\%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | sed 's#/#\\#g')"
          return 0
          ;;
        /[A-Za-z]/*)
          local drive rest
          drive=${script#/}
          drive=${drive%%/*}
          rest=${script#/$drive/}
          printf '%s:\\%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | sed 's#/#\\#g')"
          return 0
          ;;
      esac
      ;;
  esac
  printf '%s\n' "$script"
}

path_dirname() {
  local path=$1
  path=${path%/}
  case "$path" in
    */*) printf '%s\n' "${path%/*}" ;;
    *) printf '.\n' ;;
  esac
}

normalize_check_path() {
  direxio_normalize_local_path "$1"
}

paths_match_for_check() {
  direxio_paths_equal "$1" "$2"
}

connect_daemon_agent_error_from_logs() {
  local binary=$1 service_name=$2
  "$binary" daemon logs --service-name "$service_name" -n "${DIREXIO_CONNECT_LOG_TAIL_LINES:-120}" 2>/dev/null \
    | grep -Eio 'ACP_SESSION_INIT_FAILED|ACP metadata is missing|Recreate this ACP session' \
    | head -n 1 || true
}

cmd_verify_connect_daemon() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local service_name service_dir config runtime_dir binary target_work_dir status_out daemon_status work_dir evidence agent_error
  service_name=$(json_get "$STATE_JSON" agent_service_id)
  [ -n "$service_name" ] || service_name=$(json_get "$STATE_JSON" domain)
  service_dir=$(json_get "$STATE_JSON" agent_service_dir)
  config=$(json_get "$STATE_JSON" connect_config)
  runtime_dir=$(json_get "$STATE_JSON" connect_runtime_dir)
  binary=$(json_get "$STATE_JSON" connect_binary "direxio-connect")
  [ -n "$service_name" ] || service_name=direxio-connect
  [ -n "$binary" ] || binary=direxio-connect

  if [ -n "$config" ]; then
    target_work_dir=$(path_dirname "$config")
  elif [ -n "$runtime_dir" ]; then
    target_work_dir="$runtime_dir"
  elif [ -n "$service_dir" ]; then
    target_work_dir="$service_dir/direxio-connect"
  else
    warn "connect daemon check requires connect_config, connect_runtime_dir, or agent_service_dir in state.json"
    return 1
  fi

  case "$binary" in
    */*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *)
      command -v "$binary" >/dev/null 2>&1 || {
        state_set_object runtime_checks.connect_daemon status=failed "ts=$(_now)" "evidence=direxio-connect binary not found"
        warn "connect daemon check could not find binary: $binary"
        return 1
      }
      ;;
  esac

  status_out=$("$binary" daemon status --service-name "$service_name" 2>/dev/null) || {
    state_set_object runtime_checks.connect_daemon status=failed "ts=$(_now)" "service_name=$service_name" "evidence=direxio-connect daemon status failed"
    return 1
  }
  daemon_status=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*Status:[[:space:]]*//p' | head -n 1)
  work_dir=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*WorkDir:[[:space:]]*//p' | head -n 1)

  if [ "$daemon_status" != "Running" ]; then
    evidence="direxio-connect daemon is not Running"
  elif [ -z "$work_dir" ]; then
    evidence="direxio-connect daemon status has no WorkDir"
  elif ! paths_match_for_check "$target_work_dir" "$work_dir"; then
    evidence="direxio-connect daemon belongs to a different service"
  else
    agent_error=$(connect_daemon_agent_error_from_logs "$binary" "$service_name")
    if [ -n "$agent_error" ]; then
      state_set_object runtime_checks.connect_daemon \
        status=failed \
        "ts=$(_now)" \
        "evidence=direxio-connect daemon logs report ACP session initialization failure" \
        "service_name=$service_name" \
        "daemon_status=$daemon_status" \
        "work_dir=$(normalize_check_path "$work_dir")" \
        "expected_work_dir=$(normalize_check_path "$target_work_dir")" \
        "agent_error=$agent_error"
      warn "direxio-connect daemon logs report ACP session initialization failure"
      return 1
    fi
    state_set_object runtime_checks.connect_daemon \
      status=passed \
      "ts=$(_now)" \
      "evidence=direxio-connect daemon is running for this service" \
      "service_name=$service_name" \
      "daemon_status=$daemon_status" \
      "work_dir=$(normalize_check_path "$work_dir")" \
      "expected_work_dir=$(normalize_check_path "$target_work_dir")"
    echo "verified runtime check: connect_daemon"
    return 0
  fi

  state_set_object runtime_checks.connect_daemon \
    status=failed \
    "ts=$(_now)" \
    "evidence=$evidence" \
    "service_name=$service_name" \
    "daemon_status=$daemon_status" \
    "work_dir=$(normalize_check_path "$work_dir")" \
    "expected_work_dir=$(normalize_check_path "$target_work_dir")"
  warn "$evidence"
  return 1
}

runtime_check_status() {
  local check=$1
  json_get "$STATE_JSON" "runtime_checks.$check.status" "not_run"
}

runtime_status_counts_as_failure() {
  local status=$1
  case "$status" in
    passed|manual_pending|skipped) return 1 ;;
    *) return 0 ;;
  esac
}

cmd_verify_runtime() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local rc=0 failed_count=0 connect_status doctor_status tools_status smoke_status status install_status install_policy service_name

  install_status=$(json_get "$STATE_JSON" connect_install_status)
  install_policy=$(json_get "$STATE_JSON" connect_install_policy)
  service_name=$(json_get "$STATE_JSON" agent_service_id)
  [ -n "$service_name" ] || service_name=$(json_get "$STATE_JSON" domain)
  if [ "$install_status" = "recommend" ] || { [ "$install_status" = "skip" ] && [ "${install_policy:-skip}" = "skip" ]; }; then
    state_set_object runtime_checks.connect_daemon \
      status=manual_pending \
      "ts=$(_now)" \
      "evidence=direxio-connect daemon install is an explicit operator action for policy=$install_status" \
      "service_name=${service_name:-direxio-connect}"
  else
    cmd_verify_connect_daemon >/dev/null || rc=1
  fi
  cmd_verify_mcp_doctor >/dev/null || rc=1
  cmd_verify_mcp_tools >/dev/null || rc=1
  cmd_verify_mcp_smoke >/dev/null || rc=1

  connect_status=$(runtime_check_status connect_daemon)
  doctor_status=$(runtime_check_status mcp_doctor)
  tools_status=$(runtime_check_status mcp_tools)
  smoke_status=$(runtime_check_status mcp_smoke)

  for status in "$connect_status" "$doctor_status" "$tools_status" "$smoke_status"; do
    runtime_status_counts_as_failure "$status" && failed_count=$((failed_count + 1))
  done

  if [ "$failed_count" -eq 0 ]; then
    state_set_object runtime_checks.summary \
      status=passed \
      "ts=$(_now)" \
      failed_count=0 \
      "evidence=all runtime checks passed" \
      "checks.connect_daemon=$connect_status" \
      "checks.mcp_doctor=$doctor_status" \
      "checks.mcp_tools=$tools_status" \
      "checks.mcp_smoke=$smoke_status"
    echo "verified runtime checks: passed"
    return 0
  fi

  state_set_object runtime_checks.summary \
    status=failed \
    "ts=$(_now)" \
    "failed_count=$failed_count" \
    "evidence=one or more runtime checks failed" \
    "checks.connect_daemon=$connect_status" \
    "checks.mcp_doctor=$doctor_status" \
    "checks.mcp_tools=$tools_status" \
    "checks.mcp_smoke=$smoke_status"
  warn "runtime checks failed: $failed_count"
  return "${rc:-1}"
}

cmd_verify() {
  case "${1:-}" in
    connect_daemon) cmd_verify_connect_daemon ;;
    mcp_doctor) cmd_verify_mcp_doctor ;;
    mcp_smoke) cmd_verify_mcp_smoke ;;
    mcp_tools) cmd_verify_mcp_tools ;;
    runtime) cmd_verify_runtime ;;
    *)
      echo "Usage: $0 verify [connect_daemon|mcp_doctor|mcp_smoke|mcp_tools|runtime]" >&2
      return 1
      ;;
  esac
}

# Entry point.
case "${1:-run}" in
  run)    cmd_run ;;
  status) cmd_status ;;
  report) shift; cmd_report "${1:-new_deploy}" ;;
  confirm) shift; cmd_confirm "${1:-}" ;;
  verify) shift; cmd_verify "${1:-}" ;;
  reset)
    [ -f "$STATE_JSON" ] && { mv "$STATE_JSON" "$STATE_JSON.reset-$(date -u +%Y%m%d%H%M%S)"; warn "Archived old state.json."; }
    warn "Warning: after reset, destroy no longer has state data. Any remaining AWS resources must be removed manually." ;;
  *) echo "Usage: $0 [run|status|report|confirm|verify|reset]"; exit 1 ;;
esac
