#!/usr/bin/env bash
# orchestrate.sh - Dirextalk deployment state-machine engine.
#
# Turns "one AWS credential -> working Dirextalk server -> local dirextalk-connect bridge" into 8 phases
# (S0..S7). State is persisted to $DIREXTALK_WORKDIR/state.json and supports:
#   - resume: continue from the first unfinished phase
#   - checkpoints: wait for user/AWS actions without losing progress
#   - destroy: every AWS resource is recorded for destroy.sh
#
# Usage:
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
#   # Normal server selection resolves a stable GitHub Release to an immutable digest.
#   # First run asks for region, production domain, instance size, and existing-state handling.
#   # Non-interactive:
#   #   DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1 INSTANCE_TYPE=t3.small
#   bash orchestrate.sh                 # run or resume until completion
#   DOMAIN=__DOMAIN__ bash orchestrate.sh status   # show current service state only
#   bash orchestrate.sh reset           # archive state.json; destroy will no longer know the resources
#
# Exit codes: 0=DONE / 1=phase failed / 2=waiting for user action.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
DIREXTALK_INSTALL_SCRIPTS_DIR="$HERE"

# Prefer workspace-local tools when present.
REPO_ROOT=$(cd "$HERE/.." && pwd)
if [ -d "$REPO_ROOT/.tools/bin" ]; then
  PATH="$REPO_ROOT/.tools/bin:$PATH"
  export PATH
fi

DIREXTALK_WORKDIR_WAS_SET=${DIREXTALK_WORKDIR+x}

source "$HERE/lib/state.sh"
source "$HERE/lib/aws.sh"
source "$HERE/lib/domain.sh"
source "$HERE/lib/operation_report.sh"
source "$HERE/lib/local-paths.sh"
source "$HERE/lib/connect-daemon-logs.sh"
source "$HERE/lib/region.sh"
source "$HERE/lib/http-secrets.sh"
source "$HERE/lib/server-release.sh"

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
  for b in aws ssh curl; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  [ -z "$missing" ] && return 0

  warn "Missing dependencies:$missing"
  case " $missing " in
    *" aws "*)
      warn "Install AWS CLI v2 and configure credentials first:"
      warn "  macOS: curl 'https://awscli.amazonaws.com/AWSCLIV2.pkg' -o AWSCLIV2.pkg && sudo installer -pkg ./AWSCLIV2.pkg -target /"
      warn "  Linux x86_64: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install"
      warn "  Configure: aws configure --profile dirextalk-deployer"
      warn "  Use: export AWS_PROFILE=dirextalk-deployer AWS_DEFAULT_REGION=<region>"
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
  nodes="${DIREXTALK_HOME:-$HOME/.dirextalk}/nodes"
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
    S1_PREFLIGHT)       echo "AWS region, cloud provider choice, or provider-specific checks are not ready." ;;
    S2_DOMAIN)          echo "The long-lived domain, DNS authority, or irreversible Matrix server_name binding is not confirmed." ;;
    S3_PROVISION)       echo "AWS infrastructure provisioning, fixed public IP, security group, or DNS record setup is not complete." ;;
    S4_BOOTSTRAP_STACK) echo "The cloud instance exists, but cloud-init, Docker, Caddy/TLS, or message-server has not reached healthy state." ;;
    S5_INIT_TOKENS)     echo "The server is not yet returning fresh bootstrap credentials from /var/dirextalk-message-server/p2p/bootstrap.json." ;;
    S6_WIRE_LOCAL)      echo "The cloud service is likely up, but local dirextalk-connect, service credentials, or MCP snippets are not wired." ;;
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
  local provider iid volume pubip eip zone lightsail_instance static_ip out=""
  provider=$(state_get cloud_provider)
  iid=$(res_get instance_id)
  lightsail_instance=$(res_get lightsail_instance_name)
  static_ip=$(res_get lightsail_static_ip_name)
  volume=$(res_get root_volume_id)
  pubip=$(res_get public_ip)
  eip=$(res_get eip_id)
  zone=$(res_get route53_zone_id)
  if [ "$provider" = "lightsail" ]; then
    [ -n "$lightsail_instance" ] && out="Lightsail instance $lightsail_instance"
    if [ -n "$static_ip" ]; then
      [ -n "$out" ] && out="$out, "
      out="${out}Lightsail static IP $static_ip"
    fi
  else
    [ -n "$iid" ] && out="EC2 $iid"
  fi
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
    echo "no cloud instance, public IPv4, or storage resource is recorded yet"
  fi
}

status_resume_safety() {
  local current=$1 billable
  billable=$(recorded_billable_resources)
  if [ -n "$billable" ] || phase_at_or_after_s3 "$current"; then
    echo "do not reset state; fix the issue and rerun with DIREXTALK_EXISTING_STATE_ACTION=continue"
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
    S1_PREFLIGHT)       echo "fix AWS region, cloud provider choice, or provider-specific quota before creating resources" ;;
    S2_DOMAIN)          echo "confirm the long-lived domain, DNS authority, and irreversible Matrix server_name binding" ;;
    S3_PROVISION)       echo "inspect Lightsail/EC2 provisioning, fixed public IP allocation, firewall/security group creation, and DNS record setup" ;;
    S4_BOOTSTRAP_STACK) echo "inspect cloud-init, Docker, Caddy/TLS, and message-server logs over SSH" ;;
    S5_INIT_TOKENS)     echo "inspect /var/dirextalk-message-server/p2p/bootstrap.json, init-tokens.sh, and message-server bootstrap logs" ;;
    S6_WIRE_LOCAL)      echo "refresh local credentials, dirextalk-connect config, MCP snippets, and agent runtime settings without destroying cloud resources" ;;
    S7_VERIFY_E2E)      echo "inspect the failed health, Matrix, well-known, owner.json/CORS, TURN, MCP, or runtime gate before declaring delivery" ;;
    DONE)               echo "give the user the App domain and eight-digit initialization code, then record App initialization and agent/MCP confirmation separately" ;;
    *)                  echo "inspect state.json and the current phase evidence before taking action" ;;
  esac
}

status_stop_loss() {
  local domain billable command
  domain=$(state_get domain)
  billable=$(recorded_billable_resources)
  if [ -z "$billable" ]; then
    echo "no recorded cloud resources need destroy from this state"
  else
    echo "ask the agent to run destroy, or run:"
    if [ "${DIREXTALK_LOCAL_PATH_STYLE:-}" = "windows" ] || [ -n "${DIREXTALK_WINDOWS_HOME:-}" ]; then
      command=$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_env_command DOMAIN "${domain:-__DOMAIN__}" '.\scripts\destroy.ps1') || return 1
    else
      command=$(dirextalk_render_env_command DOMAIN "${domain:-__DOMAIN__}" bash "$HERE/destroy.sh") || return 1
    fi
    echo "  $command"
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
    if [ -z "${DOMAIN:-}" ] && [ -z "$DIREXTALK_WORKDIR_WAS_SET" ]; then
      cmd_status_inventory
      return 0
    fi
    warn "state.json not found: $STATE_JSON"
    warn "Set DOMAIN=<service domain> or explicit DIREXTALK_WORKDIR=<service dir> to inspect a specific deployment."
    return 0
  fi
  echo "run_id     : $(state_get run_id)"
	  echo "region     : $(state_get region)"
	  echo "cloud      : $(state_get cloud_provider)"
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
delivery_runtime_checks_strictly_passed() {
  local summary connect doctor tools smoke
  summary=$(json_get "$STATE_JSON" runtime_checks.summary.status "not_run")
  connect=$(json_get "$STATE_JSON" runtime_checks.connect_daemon.status "not_run")
  doctor=$(json_get "$STATE_JSON" runtime_checks.mcp_doctor.status "not_run")
  tools=$(json_get "$STATE_JSON" runtime_checks.mcp_tools.status "not_run")
  smoke=$(json_get "$STATE_JSON" runtime_checks.mcp_smoke.status "not_run")

  [ "$summary" = "passed" ] &&
    [ "$connect" = "passed" ] &&
    [ "$doctor" = "passed" ] &&
    [ "$tools" = "passed" ] &&
    [ "$smoke" = "passed" ]
}

delivery_runtime_checks_summary() {
  printf 'summary=%s connect_daemon=%s mcp_doctor=%s mcp_tools=%s mcp_smoke=%s\n' \
    "$(json_get "$STATE_JSON" runtime_checks.summary.status "not_run")" \
    "$(json_get "$STATE_JSON" runtime_checks.connect_daemon.status "not_run")" \
    "$(json_get "$STATE_JSON" runtime_checks.mcp_doctor.status "not_run")" \
    "$(json_get "$STATE_JSON" runtime_checks.mcp_tools.status "not_run")" \
    "$(json_get "$STATE_JSON" runtime_checks.mcp_smoke.status "not_run")"
}

ensure_delivery_runtime_checks() {
  local verify_rc=0 retry_command
  warn "Final delivery requires live runtime checks; running: verify runtime"
  cmd_verify_runtime || verify_rc=$?

  if [ "$verify_rc" -eq 0 ] && delivery_runtime_checks_strictly_passed; then
    return 0
  fi

  warn "Final delivery blocked because runtime checks did not all pass: $(delivery_runtime_checks_summary)"
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    retry_command=$(dirextalk_render_env_command DOMAIN "$(state_get domain)" '.\scripts\orchestrate.ps1' verify runtime) || return 1
  else
    retry_command=$(dirextalk_render_env_command DOMAIN "$(state_get domain)" bash "$0" verify runtime) || return 1
  fi
  warn "Fix the failed check, then rerun: $retry_command"
  return 1
}

print_delivery() {
  local domain password keyfile pubip iid region statejson agent_room_id runtime install_policy install_mode install_status install_command
  local cloud_provider cloud_label
  local agent_node_id agent_service_id agent_service_dir agent_cred cc_config cc_binary cc_agent cc_user cc_pkg
  local mcp_endpoint
  local report_path runtime_summary app_gate real_chat_gate agent_runtime_gate daemon_command ssh_command report_command
  domain=$(state_get domain)
  password=$(state_get password)
  if ! printf '%s' "$password" | grep -Eq '^[0-9]{8}$'; then
    warn "state password field is not an exact eight-digit initialization code; rerun S5_INIT_TOKENS before reporting it."
    return 1
  fi
  ensure_delivery_runtime_checks || return $?
  keyfile=$(res_get key_file); pubip=$(res_get public_ip)
  iid=$(res_get instance_id); region=$(state_get region); statejson="$STATE_JSON"
  cloud_provider=$(state_get cloud_provider)
  if [ "$cloud_provider" = "lightsail" ]; then
    cloud_label="Lightsail"
  else
    cloud_label="EC2"
  fi
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
  mcp_endpoint=$(state_get mcp_endpoint_url)
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
  echo "  credentials  : init code/password field, access_token, and agent_token written to ${agent_cred:-~/.dirextalk/nodes/<service_id>/credentials.json}"
  echo "  agent room   : ${agent_room_id:-written to credentials.json}"
  echo "  dirextalk-connect   : package=${cc_pkg:-dirextalk-connect@latest} config=${cc_config:-not recorded} command=${cc_binary:-dirextalk-connect}"
  echo "  MCP          : transport=http endpoint=${mcp_endpoint:-https://$domain/mcp}"
  echo "  matrix user  : ${cc_user:-created during S6}"
  echo "  agent runtime: ${runtime:-unknown}"
  echo "  install mode : policy=${install_policy:-recommend} mode=${install_mode:-dirextalk-connect} agent=${cc_agent:-codex} status=${install_status:-recommend}"
  [ -n "$install_command" ] && echo "  install cmd  : $install_command"
  daemon_command=$(dirextalk_render_local_command "$(dirextalk_normalize_local_path "${cc_binary:-dirextalk-connect}")" daemon status --service-name "${agent_service_id:-dirextalk-connect}") || return 1
  echo "  daemon       : $daemon_command"
  echo "  AWS region   : $region"
  echo "  cloud        : ${cloud_provider:-ec2}"
  echo "  $cloud_label          : $iid ($pubip)"
  ssh_command=$(dirextalk_render_local_command ssh -i "$(dirextalk_normalize_local_path "$keyfile")" "ubuntu@$pubip") || return 1
  echo "  SSH          : $ssh_command"
  echo "  state.json   : $statejson"
  echo "  stop billing : ask the agent to destroy this node when finished"
  echo "  Note         : cloud instances, public IPv4/static IPs, storage, and Route53 resources can keep billing until destroy is run."
  echo "  security     : delete/disable temporary IAM keys after deployment; rotate/remove root keys if used."
  echo "  Product gate : S7 is green; final product completion still needs App initialization and agent/MCP runtime confirmation."
  if report_path=$(operation_report_write new_deploy automated_gates_complete_user_confirmation_pending "$STATE_JSON" 2>/dev/null); then
    echo "  report       : $report_path"
  else
    if [ "$(dirextalk_local_path_style)" = "windows" ]; then
      report_command=$(dirextalk_render_local_command '.\scripts\orchestrate.ps1' report new_deploy) || return 1
    else
      report_command=$(dirextalk_render_local_command bash "$0" report new_deploy) || return 1
    fi
    echo "  report       : not written; run $report_command"
  fi
}

record_region_recommendation() {
  local source=$1 region=$2 timezone=${3:-} offset=${4:-} reason=${5:-}
  state_set_object region_recommendation \
    "source=$source" \
    "region=$region" \
    "timezone=${timezone:-unknown}" \
    "utc_offset_hours=${offset:-unknown}" \
    "reason=$reason"
}

ensure_region_selected() {
  local region source timezone= offset= reason= row selected
  region=$(state_get region)
  if [ -z "$region" ]; then
    region=${AWS_DEFAULT_REGION:-${AWS_REGION:-}}
    if [ -n "$region" ]; then
      source=environment
      reason="region selected from AWS_DEFAULT_REGION or AWS_REGION"
    fi
    if [ -z "$region" ]; then
      region=$(aws_configured_region)
      if [ -n "$region" ]; then
        source=aws_profile
        reason="region selected from AWS CLI profile configuration"
      fi
    fi
    if [ -z "$region" ] && [ -n "${DIREXTALK_DEFAULT_REGION:-}" ]; then
      region=$DIREXTALK_DEFAULT_REGION
      source=env
      reason="region selected from DIREXTALK_DEFAULT_REGION"
    fi
    if [ -z "$region" ] && [ -t 0 ]; then
      row=$(dirextalk_recommend_region)
      IFS=$'\t' read -r region timezone offset reason <<EOF
$row
EOF
      warn "Choose an AWS region. Region affects latency, price, default VPC, and EC2 quota."
      warn "Recommended AWS region: $region ($reason)."
      printf "AWS region [%s]: " "$region" >&2
      read -r selected
      if [ -n "$selected" ]; then
        region=$selected
        source=prompt
        reason="operator selected region interactively"
      else
        source=timezone
      fi
    fi
    if [ -z "$region" ]; then
      row=$(dirextalk_recommend_region)
      IFS=$'\t' read -r region timezone offset reason <<EOF
$row
EOF
      source=timezone
      warn "No AWS region was configured; using recommended default $region ($reason)."
      warn "Override with AWS_DEFAULT_REGION, AWS_REGION, AWS profile region, or DIREXTALK_DEFAULT_REGION."
    fi
    state_set region "$region"
    record_region_recommendation "$source" "$region" "$timezone" "$offset" "$reason"
  fi
  export AWS_DEFAULT_REGION="$region"
  return 0
}

ensure_cost_estimate() {
  local output status total region instance_type cloud_provider bundle args
  cloud_provider=$(state_get cloud_provider)
  cloud_provider=${DIREXTALK_CLOUD_PROVIDER:-${DEPLOY_MODE:-${DIREXTALK_DEPLOY_PROVIDER:-$cloud_provider}}}
  cloud_provider=${cloud_provider:-lightsail}
  cloud_provider=$(printf '%s' "$cloud_provider" | tr '[:upper:]' '[:lower:]')
  state_set cloud_provider "$cloud_provider"
  args=(--state "$STATE_JSON" --write-state)
  args+=(--cloud-provider "$cloud_provider")
  if [ "$cloud_provider" = "ec2" ] && [ -n "${INSTANCE_TYPE:-}" ]; then
    args+=(--instance-type "$INSTANCE_TYPE")
  fi

  if output=$(bash "$HERE/pricing-estimate.sh" "${args[@]}" 2>/dev/null); then
    status=$(printf '%s\n' "$output" | json_stdin_get pricing_status "unknown" 2>/dev/null)
    total=$(printf '%s\n' "$output" | json_stdin_get total_monthly_usd "unknown" 2>/dev/null)
    region=$(printf '%s\n' "$output" | json_stdin_get region "unknown" 2>/dev/null)
    if [ "$cloud_provider" = "lightsail" ]; then
      bundle=$(printf '%s\n' "$output" | json_stdin_get components.lightsail_bundle.bundle_id "unknown" 2>/dev/null)
      log "Cost estimate recorded (status=${status:-unknown}, region=${region:-unknown}, provider=lightsail, bundle=${bundle:-unknown}, monthly_usd≈${total:-unknown})."
    else
      instance_type=$(printf '%s\n' "$output" | json_stdin_get components.ec2_instance.instance_type "unknown" 2>/dev/null)
      log "Cost estimate recorded (status=${status:-unknown}, region=${region:-unknown}, provider=ec2, instance=${instance_type:-unknown}, monthly_usd≈${total:-unknown})."
    fi
    if [ "$status" = "fallback" ]; then
      warn "AWS Pricing API was unavailable or incomplete; cost_estimate uses conservative fallback values."
    fi
  else
    warn "Could not write AWS cost estimate. Continue only after giving the user a manual billing estimate."
  fi
  ensure_free_tier_credit_notice
}

ensure_free_tier_credit_notice() {
  warn "AWS new customer accounts generally receive 100-200 USD in free credits."
  warn "Users who have not used Lightsail generally receive three months of free Lightsail usage."
  warn "Credits and bundle trials are account-specific. Destroy the node when finished; AWS official real-time policy prevails."
}

precheck_new_deploy_domain_env() {
  local domain
  domain=$(domain_normalize "${DOMAIN:-}")
  [ -f "$STATE_JSON" ] && return 0
  if [ "${DOMAIN_MODE:-}" = "ec2" ]; then
    warn "Deployment blocked: DOMAIN_MODE=ec2 temporary-domain mode has been removed."
    warn "Prepare a production domain and use DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1."
    return 2
  fi
  if [ -z "$domain" ]; then
    warn "Deployment blocked: DOMAIN is missing. Dirextalk requires a confirmed production Matrix server_name."
    warn "Use this skill to prepare domain/DNS, then rerun:"
    print_domain_onboarding_guide
    warn "  DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  if ! domain_is_formal_name "$domain"; then
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as __DOMAIN__. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
    print_domain_onboarding_guide
    return 2
  fi
  if [ "${CONFIRM_DOMAIN_BINDING:-0}" != "1" ]; then
    warn "Deployment blocked: Matrix server_name domain binding has not been confirmed."
    warn "Rerun after confirmation:"
    warn "  DOMAIN=$domain DOMAIN_MODE=${DOMAIN_MODE:-route53} CONFIRM_DOMAIN_BINDING=1 bash $0"
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
    warn "Prepare a production domain and use DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1."
    return 2
  fi
  if [ -z "$domain" ]; then
    warn "Deployment blocked: DOMAIN is missing. Dirextalk requires a confirmed production Matrix server_name."
    warn "Use this skill to prepare domain/DNS, then rerun:"
    print_domain_onboarding_guide
    warn "  DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  if ! domain_is_formal_name "$domain"; then
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as __DOMAIN__. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
    print_domain_onboarding_guide
    return 2
  fi
  if [ "$confirmed" != "true" ] && [ "${CONFIRM_DOMAIN_BINDING:-0}" != "1" ]; then
    warn "Deployment blocked: Matrix server_name domain binding has not been confirmed."
    warn "After $domain becomes server_name, changing the domain is effectively a new homeserver identity."
    warn "Rerun after confirmation:"
    warn "  DOMAIN=$domain DOMAIN_MODE=${mode:-route53} CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  return 0
}

print_domain_onboarding_guide() {
  warn "Provide the long-lived domain or subdomain to use as the Matrix server_name."
  warn "  The deployer automatically checks the current AWS account for a matching public Route53 hosted zone."
  warn "  When found, it creates the A record automatically. Otherwise it prints the fixed public IP later and asks you to add the A record at the external DNS provider."
  warn "  DOMAIN_MODE=user or DOMAIN_MODE=route53 remains available as an explicit automation override."
  warn "  The Matrix server_name is bound to DOMAIN. Changing it later is effectively a new homeserver, so choose the final domain before provisioning."
}

guard_existing_state() {
  [ -f "$STATE_JSON" ] || return 0
  local resources_count confirmed action
  resources_count=$(json_length "$STATE_JSON" resources)
  [ "$resources_count" -eq 0 ] && return 0
  if [ "$(json_get "$STATE_JSON" domain_mode)" = "ec2" ]; then
    warn "Found legacy temporary-domain deployment state (domain_mode=ec2). Production deployment no longer supports resuming this mode."
    warn "Destroy and rebuild, or use a new service directory:"
    warn "  DIREXTALK_EXISTING_STATE_ACTION=destroy bash $0"
    warn "  DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1 bash $0"
    return 2
  fi
  confirmed=$(json_get "$STATE_JSON" existing_state_confirmed false)
  [ "$confirmed" = "true" ] && return 0

  action=${DIREXTALK_EXISTING_STATE_ACTION:-}
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
      warn "Resume:  DIREXTALK_EXISTING_STATE_ACTION=continue bash $0"
      warn "Rebuild: DIREXTALK_EXISTING_STATE_ACTION=destroy bash $0"
      warn "New service: DOMAIN=__DOMAIN__ CONFIRM_DOMAIN_BINDING=1 bash $0"
      return 2 ;;
    *)
      warn "Unknown DIREXTALK_EXISTING_STATE_ACTION=$action (expected continue|destroy|abort)."
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
      print_delivery || return $?
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
  local gate=${1:-} evidence=${DIREXTALK_CONFIRM_EVIDENCE:-}
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
    warn "confirm $gate requires DIREXTALK_CONFIRM_EVIDENCE with a concrete user/runtime evidence note."
    return 1
  fi
  if [ "${#evidence}" -lt 12 ]; then
    warn "DIREXTALK_CONFIRM_EVIDENCE is too short; provide a concrete user/runtime evidence note."
    return 1
  fi
  runtime_summary_status=$(json_get "$STATE_JSON" runtime_checks.summary.status "not_run")
  runtime_probe_confirmed=false
  if [ "$gate" = "agent_mcp_runtime" ]; then
    if [ "$runtime_summary_status" != "passed" ]; then
      warn "agent_mcp_runtime confirmation requires runtime_checks.summary.status=passed. Run: DOMAIN=<DOMAIN> bash $0 verify runtime"
      return 1
    fi
    if [ "${DIREXTALK_CONFIRM_RUNTIME_PROBE:-0}" != "1" ]; then
      warn "agent_mcp_runtime confirmation requires DIREXTALK_CONFIRM_RUNTIME_PROBE=1 after the selected runtime/channel probe is actually confirmed."
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

  local endpoint token node_id out code payload protocol_version server_name tools_type tools_capable headers
  endpoint=$(_mcp_http_endpoint_from_state)
  token=$(json_get "$STATE_JSON" agent_token)
  node_id=$(json_get "$STATE_JSON" agent_node_id)
  if [ -z "$endpoint" ] || [ -z "$token" ]; then
    warn "mcp doctor check requires mcp_endpoint_url/as_url/domain and agent_token in state.json"
    return 1
  fi

  out=$(mktemp "$DIREXTALK_WORKDIR/.mcp-doctor.XXXXXX")
  headers=$(dirextalk_curl_secret_headers "$(dirname "$out")" "$token" "$node_id") || return 1
  payload=$(json_build mcp-jsonrpc-initialize)
  code=$(curl -sk -o "$out" -w '%{http_code}' \
    -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "@$headers" \
    -d "$payload" 2>/dev/null)
  rm -f "$headers"
  if [ "$code" != "200" ] || ! json_valid "$out" >/dev/null 2>&1; then
    state_set_object runtime_checks.mcp_doctor status=failed "ts=$(_now)" "endpoint=$endpoint" "evidence=HTTP MCP initialize returned HTTP $code or non-json output"
    rm -f "$out"
    return 1
  fi
  protocol_version=$(json_get "$out" result.protocolVersion)
  server_name=$(json_get "$out" result.serverInfo.name)
  tools_type=$(json_type "$out" result.capabilities.tools 2>/dev/null || true)
  [ "$tools_type" = "object" ] && tools_capable=true || tools_capable=false
  state_set_object runtime_checks.mcp_doctor \
    status=passed \
    "ts=$(_now)" \
    "endpoint=$endpoint" \
    "protocol_version=$protocol_version" \
    "server_name=$server_name" \
    "tools_capable=$tools_capable" \
    "evidence=HTTP MCP initialize succeeded"
  rm -f "$out"
  echo "verified runtime check: mcp_doctor"
}

cmd_verify_mcp_smoke() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local endpoint token room_id body code payload response_content_type is_error headers node_id
  endpoint=$(_mcp_http_endpoint_from_state)
  token=$(json_get "$STATE_JSON" agent_token)
  room_id=$(json_get "$STATE_JSON" agent_room_id)
  if [ -z "$endpoint" ] || [ -z "$token" ] || [ -z "$room_id" ]; then
    warn "mcp smoke check requires mcp_endpoint_url/as_url/domain, agent_token, and agent_room_id in state.json"
    return 1
  fi

  body=$(mktemp "$DIREXTALK_WORKDIR/.mcp-smoke.XXXXXX")
  node_id=$(json_get "$STATE_JSON" agent_node_id)
  headers=$(dirextalk_curl_secret_headers "$(dirname "$body")" "$token" "$node_id") || return 1
  payload=$(json_build mcp-jsonrpc-messages-list-call "$room_id")
  code=$(curl -sk -o "$body" -w '%{http_code}' \
    -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "@$headers" \
    -d "$payload" 2>/dev/null)
  rm -f "$headers"
  response_content_type=$(json_type "$body" result.content 2>/dev/null || true)
  is_error=$(json_get "$body" result.isError false)
  if [ "$code" != "200" ] || [ "$response_content_type" != "array" ] || [ "$is_error" = "true" ]; then
    state_set_object runtime_checks.mcp_smoke \
      status=failed \
      "ts=$(_now)" \
      action=tools/call \
      tool_name=dirextalk_messages_list \
      "endpoint=$endpoint" \
      "evidence=dirextalk_messages_list returned HTTP $code, isError=$is_error, or invalid response"
    rm -f "$body"
    return 1
  fi

  state_set_object runtime_checks.mcp_smoke \
    status=passed \
    "ts=$(_now)" \
    action=tools/call \
    tool_name=dirextalk_messages_list \
    "room_id=$room_id" \
    "endpoint=$endpoint" \
    "response_content_type=$response_content_type" \
    "evidence=read-only HTTP MCP tool call succeeded"
  rm -f "$body"
  echo "verified runtime check: mcp_smoke"
}

cmd_verify_mcp_tools() {
  [ -f "$STATE_JSON" ] || {
    warn "state.json not found: $STATE_JSON"
    return 1
  }

  local endpoint token node_id out code payload tools_type headers
  endpoint=$(_mcp_http_endpoint_from_state)
  token=$(json_get "$STATE_JSON" agent_token)
  node_id=$(json_get "$STATE_JSON" agent_node_id)
  if [ -z "$endpoint" ] || [ -z "$token" ]; then
    warn "mcp tools check requires mcp_endpoint_url/as_url/domain and agent_token in state.json"
    return 1
  fi

  out=$(mktemp "$DIREXTALK_WORKDIR/.mcp-tools.XXXXXX")
  headers=$(dirextalk_curl_secret_headers "$(dirname "$out")" "$token" "$node_id") || return 1
  payload=$(json_build mcp-jsonrpc-tools-list)
  code=$(curl -sk -o "$out" -w '%{http_code}' \
    -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "@$headers" \
    -d "$payload" 2>/dev/null)
  rm -f "$headers"
  tools_type=$(json_type "$out" result.tools 2>/dev/null || true)
  if [ "$code" != "200" ] || [ "$tools_type" != "array" ]; then
    state_set_object runtime_checks.mcp_tools status=failed "ts=$(_now)" "endpoint=$endpoint" "evidence=HTTP MCP tools/list returned HTTP $code or invalid output"
    rm -f "$out"
    return 1
  fi
  state_set_object runtime_checks.mcp_tools \
    status=passed \
    "ts=$(_now)" \
    "endpoint=$endpoint" \
    "evidence=HTTP MCP tools/list succeeded" \
    "tool_count=$(json_length "$out" result.tools 0)" \
    "tools=$(json_get "$out" result.tools "[]")"
  rm -f "$out"
  echo "verified runtime check: mcp_tools"
}

_mcp_http_endpoint_from_state() {
  local endpoint service_url domain
  endpoint=$(json_get "$STATE_JSON" mcp_endpoint_url)
  if [ -n "$endpoint" ]; then
    printf '%s\n' "$endpoint"
    return 0
  fi
  service_url=$(json_get "$STATE_JSON" as_url)
  if [ -z "$service_url" ]; then
    domain=$(json_get "$STATE_JSON" domain)
    [ -n "$domain" ] && service_url="https://$domain"
  fi
  [ -n "$service_url" ] || return 1
  printf '%s/mcp\n' "${service_url%/}"
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
  dirextalk_normalize_local_path "$1"
}

paths_match_for_check() {
  dirextalk_paths_equal "$1" "$2"
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
  binary=$(json_get "$STATE_JSON" connect_binary "dirextalk-connect")
  [ -n "$service_name" ] || service_name=dirextalk-connect
  [ -n "$binary" ] || binary=dirextalk-connect

  if [ -n "$config" ]; then
    target_work_dir=$(path_dirname "$config")
  elif [ -n "$runtime_dir" ]; then
    target_work_dir="$runtime_dir"
  elif [ -n "$service_dir" ]; then
    target_work_dir="$service_dir/dirextalk-connect"
  else
    warn "connect daemon check requires connect_config, connect_runtime_dir, or agent_service_dir in state.json"
    return 1
  fi

  case "$binary" in
    */*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *)
      command -v "$binary" >/dev/null 2>&1 || {
        state_set_object runtime_checks.connect_daemon status=failed "ts=$(_now)" "evidence=dirextalk-connect binary not found"
        warn "connect daemon check could not find binary: $binary"
        return 1
      }
      ;;
  esac

  status_out=$("$binary" daemon status --service-name "$service_name" 2>/dev/null) || {
    state_set_object runtime_checks.connect_daemon status=failed "ts=$(_now)" "service_name=$service_name" "evidence=dirextalk-connect daemon status failed"
    return 1
  }
  daemon_status=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*Status:[[:space:]]*//p' | head -n 1)
  work_dir=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*WorkDir:[[:space:]]*//p' | head -n 1)

  if [ "$daemon_status" != "Running" ]; then
    evidence="dirextalk-connect daemon is not Running"
  elif [ -z "$work_dir" ]; then
    evidence="dirextalk-connect daemon status has no WorkDir"
  elif ! paths_match_for_check "$target_work_dir" "$work_dir"; then
    evidence="dirextalk-connect daemon belongs to a different service"
  else
    agent_error=$(connect_daemon_agent_error_from_logs "$binary" "$service_name")
    if [ -n "$agent_error" ]; then
      state_set_object runtime_checks.connect_daemon \
        status=failed \
        "ts=$(_now)" \
        "evidence=dirextalk-connect daemon logs report local agent backend failure" \
        "service_name=$service_name" \
        "daemon_status=$daemon_status" \
        "work_dir=$(normalize_check_path "$work_dir")" \
        "expected_work_dir=$(normalize_check_path "$target_work_dir")" \
        "agent_error=$agent_error"
      warn "dirextalk-connect daemon logs report local agent backend failure"
      return 1
    fi
    state_set_object runtime_checks.connect_daemon \
      status=passed \
      "ts=$(_now)" \
      "evidence=dirextalk-connect daemon is running for this service" \
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
      "evidence=dirextalk-connect daemon install is an explicit operator action for policy=$install_status" \
      "service_name=${service_name:-dirextalk-connect}"
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

if [ "${DIREXTALK_ORCHESTRATE_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

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
