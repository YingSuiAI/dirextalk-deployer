#!/usr/bin/env bash
# S1 PREFLIGHT - cloud provider choice and provider checks.
#
# New deployments default to Lightsail's fixed $12/month Linux bundle. EC2
# remains available through DIREXTALK_CLOUD_PROVIDER=ec2 or DEPLOY_MODE=ec2.

DEFAULT_LIGHTSAIL_MONTHLY_USD=${DEFAULT_LIGHTSAIL_MONTHLY_USD:-12}
DEFAULT_LIGHTSAIL_RAM_GB=${DEFAULT_LIGHTSAIL_RAM_GB:-2}
DEFAULT_LIGHTSAIL_DISK_GB=${DEFAULT_LIGHTSAIL_DISK_GB:-60}
DEFAULT_LIGHTSAIL_ZONE_SUFFIX=${DEFAULT_LIGHTSAIL_ZONE_SUFFIX:-a}
DEFAULT_EC2_INSTANCE_TYPE=${DEFAULT_EC2_INSTANCE_TYPE:-t3.small}
S1_PHASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
source "$S1_PHASE_DIR/lib/server-release.sh"

run_phase() {
  aws_env_prep
  phase_set S1_PREFLIGHT in_progress "running preflight checks"
  if ! server_release_validate_override; then
    phase_set S1_PREFLIGHT failed "mutable server image override requires explicit debug/legacy confirmation"
    return 1
  fi
  local cloud_provider
  cloud_provider=$(_resolve_cloud_provider)
  state_set cloud_provider "$cloud_provider"

  if [ "$cloud_provider" = "lightsail" ]; then
    if _preflight_lightsail; then
      _record_cloud_recommendation lightsail
      phase_set S1_PREFLIGHT done "cloud_provider=lightsail bundle=$(_state_or_default resources.lightsail_bundle_id unknown) zone=$(_state_or_default resources.lightsail_availability_zone unknown)"
      return 0
    else
      local lightsail_rc=$?
      if [ "$lightsail_rc" -eq 3 ]; then
        _wait_for_lightsail_or_ec2_choice
        return $?
      fi
      return 1
    fi
  fi

  _record_cloud_recommendation "$cloud_provider"
  _preflight_ec2
}

_preflight_ec2() {
  phase_set S1_PREFLIGHT in_progress "running EC2 preflight checks"

  # 1) Default VPC.
  local vpc
  vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
  if [ "$vpc" = "None" ] || [ -z "$vpc" ]; then
    phase_set S1_PREFLIGHT failed "no default VPC in this region"
    fail "This region has no default VPC. In the AWS console, go to VPC -> Create default VPC, or choose another region."
  fi
  res_set vpc_id "$vpc"
  log "Default VPC = $vpc"

  # 2) vCPU quota. t3.small requires 2 vCPU. Unknown quota is warned but not blocked.
  local quota
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code "$EC2_STD_QUOTA_CODE" \
          --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
  quota=${quota:-unknown}
  log "On-Demand Standard instance vCPU quota = $quota (need 2)"
  if _is_unknown_quota "$quota"; then
    warn "Could not read quota; continuing. If run-instances returns VcpuLimitExceeded, quota is insufficient."
  elif ! _num_ge "$quota" 2; then
    phase_set S1_PREFLIGHT waiting_user "vCPU quota=$quota (<2), waiting for quota increase"
    warn "EC2 vCPU quota is $quota (<2), which is common on new AWS accounts."
    warn "Open Service Quotas -> Amazon EC2 ->"
    warn "  'Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances' and request quota >= 2."
    warn "After submitting the request, you can leave this running; it checks every ${QUOTA_POLL_INTERVAL:-300}s."
    poll_until "vCPU quota >= 2" "${QUOTA_POLL_INTERVAL:-300}" 0 _quota_ge_2 \
      || { phase_set S1_PREFLIGHT failed "quota polling interrupted"; return 1; }
  fi

  # 3) Elastic IP quota and current regional usage. Unknown quota is warned but not blocked.
  _check_eip_capacity || return $?

  # 4) AMI (amd64/x86).
  local ami
  ami=$(aws_lookup_ubuntu_ami)
  if [ "$ami" = "None" ] || [ -z "$ami" ]; then
    phase_set S1_PREFLIGHT failed "failed to resolve Ubuntu AMI"
    fail "Could not resolve Ubuntu 24.04 amd64 AMI (SSM parameter unavailable)."
  fi
  res_set ami_id "$ami"
  log "AMI = $ami (Ubuntu 24.04 amd64/x86_64, user=ubuntu)"

  phase_set S1_PREFLIGHT done "cloud_provider=ec2 vpc=$vpc quota=$quota ami=$ami"
  return 0
}

_resolve_cloud_provider() {
  local provider
  provider=$(state_get cloud_provider)
  provider=${DIREXTALK_CLOUD_PROVIDER:-${DEPLOY_MODE:-${DIREXTALK_DEPLOY_PROVIDER:-$provider}}}
  provider=${provider:-lightsail}
  provider=$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')
  case "$provider" in
    lightsail|ec2) printf '%s\n' "$provider" ;;
    *)
      phase_set S1_PREFLIGHT waiting_user "unknown cloud provider"
      warn "Unknown cloud provider: $provider. Expected lightsail or ec2."
      warn "Use DIREXTALK_CLOUD_PROVIDER=lightsail for the default $12 Lightsail bundle, or DIREXTALK_CLOUD_PROVIDER=ec2 for the EC2 path."
      return 2
      ;;
  esac
}

_record_cloud_recommendation() {
  local selected=$1 cause=${2:-} recommended=lightsail reason
  if [ "$cause" = "lightsail_unavailable" ]; then
    reason="Lightsail has no usable $DEFAULT_LIGHTSAIL_MONTHLY_USD USD bundle or availability zone in this region; choose another Lightsail-capable region or explicitly select EC2 after reviewing the EC2 estimate"
  elif [ "$selected" = "ec2" ]; then
    reason="operator selected EC2; default recommendation remains Lightsail unless EC2-specific controls are required"
  else
    reason="Lightsail $12 Linux bundle gives fixed 2GB/2vCPU/60GB capacity and avoids EC2/EIP setup for the default path"
  fi
  state_set_object cloud_recommendation \
    default_provider=lightsail \
    "selected_provider=$selected" \
    "recommended_provider=$recommended" \
    choices=lightsail,ec2 \
    "lightsail_monthly_usd=$DEFAULT_LIGHTSAIL_MONTHLY_USD" \
    "lightsail_ram_gb=$DEFAULT_LIGHTSAIL_RAM_GB" \
    "lightsail_disk_gb=$DEFAULT_LIGHTSAIL_DISK_GB" \
    "lightsail_default_availability_zone=$(state_get region)$DEFAULT_LIGHTSAIL_ZONE_SUFFIX" \
    "lightsail_selected_availability_zone=$(_state_or_default resources.lightsail_availability_zone "")" \
    "lightsail_availability_status=$(_state_or_default resources.lightsail_availability_status unknown)" \
    "ec2_instance_type=$DEFAULT_EC2_INSTANCE_TYPE" \
    "reason=$reason"
}

_wait_for_lightsail_or_ec2_choice() {
  local region domain_mode estimate
  region=$(state_get region)
  domain_mode=$(state_get domain_mode)
  domain_mode=${domain_mode:-route53}
  state_set cloud_provider lightsail
  _record_cloud_recommendation lightsail "lightsail_unavailable"
  if estimate=$(bash "$S1_PHASE_DIR/pricing-estimate.sh" \
      --region "$region" \
      --cloud-provider ec2 \
      --instance-type "$DEFAULT_EC2_INSTANCE_TYPE" \
      --disk-gb "${DIREXTALK_ROOT_VOLUME_GB:-50}" \
      --domain-mode "$domain_mode" 2>/dev/null); then
    state_set_raw cloud_recommendation.ec2_cost_estimate "$estimate"
  else
    warn "Could not record EC2 cost estimate automatically. Run scripts/pricing-estimate.sh manually before choosing EC2."
  fi
  phase_set S1_PREFLIGHT waiting_user "Lightsail unavailable in $region; waiting for region or explicit EC2 choice"
  warn "Lightsail is unavailable in AWS region $region for this deployment."
  warn "Choose another Lightsail-capable region, or explicitly choose EC2 after reviewing the EC2 estimate."
  warn "Lightsail region option: AWS_DEFAULT_REGION=<region> bash scripts/orchestrate.sh"
  warn "EC2 option: DIREXTALK_CLOUD_PROVIDER=ec2 INSTANCE_TYPE=$DEFAULT_EC2_INSTANCE_TYPE bash scripts/orchestrate.sh"
  return 2
}

_preflight_lightsail() {
  local bundle zone region
  region=$(state_get region)
  bundle=$(res_get lightsail_bundle_id)
  if [ -z "$bundle" ]; then
    bundle=$(_select_lightsail_bundle) || {
      phase_set S1_PREFLIGHT failed "Lightsail $12 bundle unavailable"
      warn "Could not find a Lightsail Linux/Unix bundle near $12/month in this account/region."
      warn "Set DIREXTALK_LIGHTSAIL_BUNDLE_ID to override, or use DIREXTALK_CLOUD_PROVIDER=ec2."
      return 3
    }
  fi
  zone=$(res_get lightsail_availability_zone)
  zone=${DIREXTALK_LIGHTSAIL_AVAILABILITY_ZONE:-${zone:-}}
  if [ -z "$zone" ]; then
    zone=$(_select_lightsail_availability_zone "$region") || {
      phase_set S1_PREFLIGHT failed "Lightsail availability zone unavailable"
      warn "No Lightsail availability zone is available in region $region."
      warn "Use another AWS region, or choose EC2 with DIREXTALK_CLOUD_PROVIDER=ec2."
      return 3
    }
  fi
  res_set lightsail_availability_zone "$zone"
  log "Cloud provider = Lightsail; selected bundle = $bundle"
  log "Lightsail availability zone = $zone"
  warn "Default deployment uses Lightsail $DEFAULT_LIGHTSAIL_MONTHLY_USD/month Linux bundle. Use DIREXTALK_CLOUD_PROVIDER=ec2 to choose the EC2 path."
  return 0
}

_select_lightsail_availability_zone() {
  local region=$1 tmp line rc zone default_zone available unavailable reason status
  tmp=$(mktemp)
  if ! aws lightsail get-regions --include-availability-zones --output json > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    res_set lightsail_availability_status unknown
    res_set lightsail_default_availability_zone "${region}${DEFAULT_LIGHTSAIL_ZONE_SUFFIX}"
    return 1
  fi
  rc=0
  line=$(json_lightsail_availability_zone "$tmp" "$region" "$DEFAULT_LIGHTSAIL_ZONE_SUFFIX") || rc=$?
  rm -f "$tmp"
  IFS='|' read -r zone default_zone available unavailable reason <<EOF
$line
EOF
  status=available
  [ "$rc" -eq 0 ] || status=unavailable
  res_set lightsail_availability_status "$status"
  res_set lightsail_default_availability_zone "$default_zone"
  res_set lightsail_available_zones "$available"
  res_set lightsail_unavailable_zones "$unavailable"
  res_set lightsail_availability_reason "$reason"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$zone"
}

_select_lightsail_bundle() {
  local override tmp selected price ram disk transfer cpu
  override=${DIREXTALK_LIGHTSAIL_BUNDLE_ID:-}
  if [ -n "$override" ]; then
    res_set lightsail_bundle_id "$override"
    res_set lightsail_bundle_price_usd "$DEFAULT_LIGHTSAIL_MONTHLY_USD"
    res_set lightsail_bundle_ram_gb "$DEFAULT_LIGHTSAIL_RAM_GB"
    res_set lightsail_bundle_disk_gb "$DEFAULT_LIGHTSAIL_DISK_GB"
    printf '%s\n' "$override"
    return 0
  fi
  tmp=$(mktemp)
  aws lightsail get-bundles --output json > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  selected=$(json_lightsail_bundle_select "$tmp" "$DEFAULT_LIGHTSAIL_MONTHLY_USD" "$DEFAULT_LIGHTSAIL_RAM_GB" "$DEFAULT_LIGHTSAIL_DISK_GB") || {
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"
  IFS=$'\t' read -r selected price ram disk transfer cpu <<EOF
$selected
EOF
  res_set lightsail_bundle_id "$selected"
  res_set lightsail_bundle_price_usd "$price"
  res_set lightsail_bundle_ram_gb "$ram"
  res_set lightsail_bundle_disk_gb "$disk"
  res_set lightsail_bundle_transfer_gb "$transfer"
  res_set lightsail_bundle_cpu_count "$cpu"
  printf '%s\n' "$selected"
}

_state_or_default() {
  local path=$1 fallback=${2:-}
  json_get "$STATE_JSON" "$path" "$fallback"
}

# Values used when quota cannot be read. These warn but do not block.
_is_unknown_quota() {
  case "$1" in ""|unknown|None|null) return 0;; *) return 1;; esac
}

# Numeric comparison $1 >= $2. Use -v to avoid awk syntax errors on empty/non-numeric input.
_num_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{ if (a+0 >= b+0) exit 0; else exit 1 }'
}

# Quota >= 2 check for poll_until. Empty/None counts as not ready.
_quota_ge_2() {
  local q
  q=$(aws service-quotas get-service-quota --service-code ec2 --quota-code "$EC2_STD_QUOTA_CODE" \
      --query 'Quota.Value' --output text 2>/dev/null || echo "0")
  q=${q:-0}
  _is_unknown_quota "$q" && return 1
  _num_ge "$q" 2
}

_check_eip_capacity() {
  local quota allocated available
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code "$EC2_VPC_EIP_QUOTA_CODE" \
          --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
  quota=${quota:-unknown}
  allocated=$(aws ec2 describe-addresses \
              --query 'length(Addresses[?Domain==`vpc`])' --output text 2>/dev/null || echo "unknown")
  allocated=${allocated:-unknown}

  res_set eip_quota "$quota"
  res_set eip_allocated "$allocated"

  if _is_unknown_quota "$quota" || _is_unknown_quota "$allocated"; then
    warn "Could not read Elastic IP quota or current allocation; continuing. If allocate-address fails, check regional EIP quota."
    return 0
  fi

  available=$(awk -v q="$quota" -v a="$allocated" 'BEGIN { v=int(q+0)-int(a+0); if (v < 0) v=0; print v }')
  res_set eip_available "$available"
  log "Elastic IP quota = $quota, allocated = $allocated, available = $available (need 1)"

  if ! _num_ge "$available" 1; then
    phase_set S1_PREFLIGHT waiting_user "Elastic IP quota exhausted: allocated=$allocated quota=$quota"
    warn "This region has no available Elastic IP quota: allocated=$allocated quota=$quota."
    warn "Release an unused Elastic IP, request a higher EC2-VPC Elastic IP quota, or choose another AWS region, then rerun."
    return 2
  fi
  return 0
}
