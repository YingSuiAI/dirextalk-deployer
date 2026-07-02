#!/usr/bin/env bash
# S3 PROVISION_EC2 - key pair, security group, cloud-init, EC2, EIP, DNS.
#
# Default instance type is x86/amd64 t3.small (2 vCPU / 2GB). Every resource is
# persisted immediately so deployment can resume and destroy.sh can clean up.

S3_PHASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
source "$S3_PHASE_DIR/lib/domain.sh"

DIREXIO_ROOT_VOLUME_GB=${DIREXIO_ROOT_VOLUME_GB:-50}
DIREXIO_ROOT_DEVICE_NAME=${DIREXIO_ROOT_DEVICE_NAME:-/dev/sda1}

run_phase() {
  aws_env_prep
  phase_set S3_PROVISION in_progress "provisioning EC2"

  local name region instance_type ami sg vpc
  name=$(state_get run_id)
  region=$(state_get region)
  instance_type=$(state_get instance_type)
  if [ -z "$instance_type" ]; then
    instance_type=${INSTANCE_TYPE:-}
    if [ -z "$instance_type" ]; then
      if [ "${DIREXIO_ASSUME_DEFAULTS:-0}" = "1" ]; then
        instance_type=t3.small
      elif [ -t 0 ]; then
        warn "Default EC2 instance type is t3.small (2 vCPU / 2GB). Do you need a larger instance?"
        printf "Use a larger instance? [y/N] " >&2
        local ans chosen
        read -r ans
        if is_yes "$ans"; then
          printf "Enter EC2 instance type [t3.medium]: " >&2
          read -r chosen
          instance_type=${chosen:-t3.medium}
        else
          instance_type=t3.small
        fi
      else
        phase_set S3_PROVISION waiting_user "waiting for EC2 instance type confirmation"
        warn "EC2 instance type must be confirmed. Default t3.small = 2 vCPU / 2GB."
        warn "  Use default: INSTANCE_TYPE=t3.small bash scripts/orchestrate.sh"
        warn "  Use larger:  INSTANCE_TYPE=t3.medium bash scripts/orchestrate.sh"
        warn "  Larger instances require matching vCPU quota. If run-instances returns VcpuLimitExceeded, return to S1 and request quota."
        return 2
      fi
    fi
    state_set instance_type "$instance_type"
  fi
  if declare -F ensure_cost_estimate >/dev/null 2>&1; then
    ensure_cost_estimate
  fi
  ami=$(res_get ami_id)
  vpc=$(res_get vpc_id)
  local message_server_image
  message_server_image=${MESSAGE_SERVER_IMAGE:-direxio/message-server:latest}
  local scripts_dir=${DIREXIO_INSTALL_SCRIPTS_DIR:-${HERE:-$S3_PHASE_DIR}}

  # 1) Key pair (idempotent).
  local keyfile="$DIREXIO_WORKDIR/${name}.pem"
  if [ -z "$(res_get key_name)" ]; then
    log "Creating key pair $name ..."
    aws ec2 create-key-pair --key-name "$name" --query KeyMaterial --output text > "$keyfile"
    restrict_private_file "$keyfile"
    res_set key_name "$name"; res_set key_file "$keyfile"
  else
    log "Key pair already exists; skipping."; keyfile=$(res_get key_file)
  fi

  # 2) Security group (idempotent): 22/80/443 + TURN relay ports.
  if [ -z "$(res_get sg_id)" ]; then
    log "Creating security group (22/80/443 + TURN 3478/49160-49200)..."
    warn "Security group opens 22/80/443, TURN 3478 tcp/udp, and 49160-49200/udp to 0.0.0.0/0."
    warn "Keep the SSH private key, AWS credentials, and password secure."
    sg=$(aws ec2 create-security-group --group-name "$name" \
         --description "direxio $name" --vpc-id "$vpc" --query GroupId --output text)
    res_set sg_id "$sg"
    local p
    for p in 22 80 443; do
      aws ec2 authorize-security-group-ingress --group-id "$sg" \
        --protocol tcp --port "$p" --cidr 0.0.0.0/0 >/dev/null
    done
    # TURN main port 3478 (udp+tcp); first version does not expose turns:5349.
    aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 3478 --cidr 0.0.0.0/0 >/dev/null
    aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol udp --port 3478 --cidr 0.0.0.0/0 >/dev/null
    # Narrow TURN UDP relay range to 49160-49200.
    aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol udp --port 49160-49200 --cidr 0.0.0.0/0 >/dev/null
  else
    log "Security group already exists; skipping."; sg=$(res_get sg_id)
  fi

  # 3) Render cloud-init with compose/Caddyfile/init-tokens embedded.
  local domain_mode domain
  domain_mode=$(state_get domain_mode)
  domain=$(state_get domain)
  domain=$(domain_normalize "$domain")
  if [ -z "$domain" ]; then
    phase_set S3_PROVISION waiting_user "production domain missing"
    warn "S3 requires a production DOMAIN. Complete S2_DOMAIN first."
    return 2
  fi
  local userdata="$DIREXIO_WORKDIR/user-data.yaml"
  log "Rendering cloud-init (domain_mode=$domain_mode)..."
  bash "$scripts_dir/render/render-userdata.sh" \
    --domain "$domain" \
    --acme "${ACME_EMAIL:-}" \
    --message-server-image "$message_server_image" \
    > "$userdata"
  local userdata_aws="$userdata"
  if command -v cygpath >/dev/null 2>&1; then
    userdata_aws=$(cygpath -w "$userdata")
  fi

  # 4) Launch EC2 (idempotent: reuse running/pending instance).
  local iid
  iid=$(res_get instance_id)
  if [ -n "$iid" ] && aws ec2 describe-instances --instance-ids "$iid" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null \
        | grep -qE 'running|pending'; then
    log "Instance $iid already exists; skipping creation."
  else
    log "Launching EC2 instance (x86 $instance_type, $ami)..."
    res_set root_volume_gb "$DIREXIO_ROOT_VOLUME_GB"
    iid=$(aws ec2 run-instances --image-id "$ami" --instance-type "$instance_type" \
      --key-name "$name" --security-group-ids "$sg" \
      --user-data "file://$userdata_aws" \
      --block-device-mappings "$(_root_block_device_mappings)" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
      --query 'Instances[0].InstanceId' --output text) || {
        phase_set S3_PROVISION failed "run-instances failed (possibly VcpuLimitExceeded)"
        warn "run-instances failed. If the error is VcpuLimitExceeded, return to S1 and request quota."
        return 1
      }
    res_set instance_id "$iid"
    log "Waiting for instance to become running ..."
    aws ec2 wait instance-running --instance-ids "$iid" || {
      phase_set S3_PROVISION failed "instance did not become running before timeout"
      warn "Timed out waiting for instance running. Check status with aws ec2 describe-instances --instance-ids $iid, then rerun to resume."
      return 1
    }
  fi
  _record_root_volume_id "$iid"

  # 5) Public address. Production-domain deployments require EIP for stable DNS.
  local pubip
  if [ -z "$(res_get eip_id)" ]; then
    log "Allocating and associating Elastic IP ..."
    local eip
    eip=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text) || {
      phase_set S3_PROVISION failed "failed to allocate EIP"
      warn "Failed to allocate Elastic IP. Check EIP quota, region, and AWS permissions."
      return 1
    }
    [ -n "$eip" ] && [ "$eip" != "None" ] || {
      phase_set S3_PROVISION failed "EIP allocation returned no AllocationId"
      warn "Elastic IP allocation returned no AllocationId. Check AWS response and rerun."
      return 1
    }
    res_set eip_id "$eip"
    aws ec2 associate-address --instance-id "$iid" --allocation-id "$eip" >/dev/null || {
      phase_set S3_PROVISION failed "failed to associate EIP"
      warn "Failed to associate Elastic IP with the instance. Check instance status, EIP quota, and AWS permissions."
      return 1
    }
  fi
  pubip=$(aws ec2 describe-addresses --allocation-ids "$(res_get eip_id)" \
            --query 'Addresses[0].PublicIp' --output text) || {
              phase_set S3_PROVISION failed "failed to read EIP public IP"
              warn "Failed to read Elastic IP address. Check AllocationId=$(res_get eip_id)."
              return 1
            }
  [ -n "$pubip" ] && [ "$pubip" != "None" ] || {
    phase_set S3_PROVISION failed "EIP returned no public IP"
    warn "Elastic IP returned no public IP. Check AWS address allocation status."
    return 1
  }
  res_set public_ip "$pubip"
  log "Public IP = $pubip; domain = $(state_get domain)"

  if [ "$domain_mode" = "route53" ]; then
    local route53_rc=0
    _upsert_route53_record "$domain" "$pubip" || route53_rc=$?
    [ "$route53_rc" -eq 0 ] || return "$route53_rc"
  fi

  if [ "$domain_mode" = "user" ] || [ "$domain_mode" = "route53" ]; then
    _require_user_dns_ready "$domain_mode" "$domain" "$pubip" "$instance_type" || return 2
  fi

  phase_set S3_PROVISION done "instance=$iid ip=$pubip domain=$(state_get domain)"
  return 0
}

_root_block_device_mappings() {
  printf '[{"DeviceName":"%s","Ebs":{"VolumeSize":%s,"VolumeType":"gp3","DeleteOnTermination":true}}]\n' \
    "$DIREXIO_ROOT_DEVICE_NAME" \
    "$DIREXIO_ROOT_VOLUME_GB"
}

_record_root_volume_id() {
  local iid=$1 volume_id
  [ -n "$iid" ] || return 0
  volume_id=$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?Ebs.VolumeId!=`null`].Ebs.VolumeId | [0]' \
    --output text 2>/dev/null) || return 0
  [ -n "$volume_id" ] && [ "$volume_id" != "None" ] || return 0
  res_set root_volume_id "$volume_id"
}

_upsert_route53_record() {
  local domain=$1 pubip=$2 zone zone_id zone_name change_file change_id
  zone=$(_find_or_create_route53_zone "$domain") || {
    phase_set S3_PROVISION failed "Route53 hosted zone unavailable"
    warn "DOMAIN_MODE=route53 requires Route53 permission to list or create the hosted zone for $domain."
    return 1
  }
  zone_id=$(printf '%s' "$zone" | cut -f1)
  zone_name=$(printf '%s' "$zone" | cut -f2)
  if [ -z "$zone_id" ]; then
    phase_set S3_PROVISION failed "Route53 hosted zone not found"
    warn "DOMAIN_MODE=route53 requires the parent domain of $domain to exist in a Route53 hosted zone."
    return 1
  fi
  _guard_route53_a_overwrite "$zone_id" "$domain" "$pubip" || return $?

  log "Route53 upsert: $domain A $pubip (zone=$zone_name)"
  change_file=$(mktemp)
  cat > "$change_file" <<EOF
{
  "Comment": "Direxio deployment",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$domain.",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{ "Value": "$pubip" }]
      }
    }
  ]
}
EOF
  local change_file_aws="$change_file"
  if command -v cygpath >/dev/null 2>&1; then
    change_file_aws=$(cygpath -w "$change_file")
  fi
  change_id=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "file://$change_file_aws" \
    --query 'ChangeInfo.Id' --output text) || {
      rm -f "$change_file"
      phase_set S3_PROVISION failed "Route53 upsert failed"
      return 1
    }
  rm -f "$change_file"
  aws route53 wait resource-record-sets-changed --id "$change_id" || {
    phase_set S3_PROVISION failed "Route53 change did not complete"
    return 1
  }
  return 0
}

_route53_existing_a_value() {
  local zone_id=$1 domain=$2 records name
  name="${domain}."
  records=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null) || return 0
  printf '%s\n' "$records" | json_stdin_route53_a_values "$name" | sed -n '1p'
}

_guard_route53_a_overwrite() {
  local zone_id=$1 domain=$2 pubip=$3 existing confirmed
  existing=$(_route53_existing_a_value "$zone_id" "$domain")
  [ -n "$existing" ] || return 0
  [ "$existing" = "$pubip" ] && return 0

  res_set route53_existing_a_value "$existing"
  res_set route53_pending_a_value "$pubip"
  confirmed=${DIREXIO_CONFIRM_DNS_OVERWRITE:-${CONFIRM_DNS_OVERWRITE:-0}}
  if [ "$confirmed" = "1" ]; then
    res_set route53_overwrite_confirmed "true"
    warn "Route53 A record overwrite confirmed: $domain $existing -> $pubip."
    return 0
  fi

  phase_set S3_PROVISION waiting_user "Route53 A record overwrite requires confirmation"
  warn "Route53 A record overwrite requires confirmation for $domain."
  warn "Current A record: $existing"
  warn "New deployment IP: $pubip"
  warn "If this is intentional, rerun with DIREXIO_CONFIRM_DNS_OVERWRITE=1."
  return 2
}

_route53_zone_from_state() {
  local zone_id zone_name
  zone_id=$(res_get route53_zone_id)
  zone_name=$(res_get route53_zone_name)
  [ -n "$zone_id" ] && [ -n "$zone_name" ] || return 1
  printf '%s\t%s\n' "$zone_id" "$zone_name"
}

_record_route53_zone() {
  local zone_id=$1 zone_name=$2 created=${3:-false} name_servers=${4:-}
  res_set route53_zone_id "$zone_id"
  res_set route53_zone_name "${zone_name%.}"
  if [ -z "$(res_get route53_zone_created_by_deployer)" ] || [ "$created" = "true" ]; then
    res_set route53_zone_created_by_deployer "$created"
  fi
  [ -n "$name_servers" ] && res_set route53_name_servers "$name_servers"
}

_find_or_create_route53_zone() {
  local domain=$1 zone zone_id zone_name find_rc
  if zone=$(_route53_zone_from_state); then
    printf '%s\n' "$zone"
    return 0
  fi

  if zone=$(_find_route53_zone "$domain"); then
    zone_id=$(printf '%s' "$zone" | cut -f1)
    zone_name=$(printf '%s' "$zone" | cut -f2)
    _record_route53_zone "$zone_id" "$zone_name" false
    printf '%s\n' "$zone"
    return 0
  else
    find_rc=$?
  fi

  case "$find_rc" in
    1) _create_route53_zone "$domain" ;;
    *) return 1 ;;
  esac
}

_find_route53_zone() {
  local domain=$1 best_id="" best_name="" best_len=0 id name clean len zones_json
  zones_json=$(aws route53 list-hosted-zones --output json) || return 2
  while IFS=$'\t' read -r id name; do
    id=${id%$'\r'}
    name=${name%$'\r'}
    clean=${name%.}
    case "$domain" in
      "$clean"|*."$clean")
        len=${#clean}
        if [ "$len" -gt "$best_len" ]; then
          best_id=${id#/hostedzone/}
          best_name=$clean
          best_len=$len
        fi
        ;;
    esac
  done < <(printf '%s\n' "$zones_json" | json_stdin_tsv HostedZones Id Name)
  [ -n "$best_id" ] || return 1
  printf '%s\t%s\n' "$best_id" "$best_name"
}

_create_route53_zone() {
  local domain=$1 zone_name caller created zone_id returned_name name_servers
  zone_name=${DIREXIO_ROUTE53_ZONE_NAME:-$domain}
  caller="direxio-$(state_get run_id)-$(date -u +%Y%m%d%H%M%S)"
  created=$(aws route53 create-hosted-zone \
    --name "$zone_name" \
    --caller-reference "$caller" \
    --output json) || return 1
  zone_id=$(printf '%s\n' "$created" | json_stdin_get HostedZone.Id | sed 's#^/hostedzone/##')
  returned_name=$(printf '%s\n' "$created" | json_stdin_get HostedZone.Name)
  name_servers=$(printf '%s\n' "$created" | json_stdin_join DelegationSet.NameServers ",")
  [ -n "$zone_id" ] && [ -n "$returned_name" ] || return 1

  _record_route53_zone "$zone_id" "${returned_name%.}" true "$name_servers"
  warn "Created Route53 hosted zone ${returned_name%.} (id=$zone_id). This hosted zone is billable until deleted."
  if [ -n "$name_servers" ]; then
    warn "Route53 nameservers: $name_servers"
    warn "If the domain is registered outside Route53, delegate NS at the registrar before DNS can resolve."
  fi
  printf '%s\t%s\n' "$zone_id" "${returned_name%.}"
}

_require_user_dns_ready() {
  local domain_mode=$1 domain=$2 pubip=$3 instance_type=$4
  if [ "$(state_get dns_ready)" = "true" ]; then
    domain_resolves_to_ip "$domain" "$pubip" && return 0
    warn "state has dns_ready=true, but current DNS does not point to $pubip. Continuing to wait to avoid early certificate issuance."
    state_set_raw dns_ready 'false'
  fi
  if domain_resolves_to_ip "$domain" "$pubip"; then
    ok "DNS resolves to $pubip: $domain"
    state_set_raw dns_ready 'true'
    return 0
  fi
  if [ "${DNS_READY:-0}" = "1" ] || [ "${CONFIRM_DNS_READY:-0}" = "1" ]; then
    if domain_resolves_to_ip "$domain" "$pubip"; then
      state_set_raw dns_ready 'true'
      return 0
    fi
    warn "DNS_READY is set, but $domain does not resolve to ${pubip} yet. Waiting to avoid Caddy/Let's Encrypt racing DNS."
  fi

  if [ "$domain_mode" = "route53" ]; then
    warn "Route53 A record was submitted, but $domain does not resolve to ${pubip} yet."
    warn "This is usually DNS propagation delay; rerun later to continue."
  else
    warn "Update DNS so $domain has an A record pointing to this EC2 public IP:"
    warn "  $domain  A  $pubip"
    warn "Use a subdomain such as __DOMAIN__. If DNS is on Cloudflare, set it to DNS only; do not enable proxying."
  fi
  warn "Use this command to confirm DNS now points at the new IP:"
  warn "  dig +short $domain"
  warn "Continue to S4 only after DNS is active, otherwise Caddy cannot issue the Let's Encrypt certificate."

  if [ "$domain_mode" = "user" ] && [ -t 0 ]; then
    printf "Have you updated the DNS A record and waited for propagation? [y/N] " >&2
    local ans
    read -r ans
    if is_yes "$ans"; then
      if domain_resolves_to_ip "$domain" "$pubip"; then
        state_set_raw dns_ready 'true'
        return 0
      fi
      warn "$domain still does not resolve to $pubip; confirmation alone is not enough to continue."
    fi
  fi

  phase_set S3_PROVISION waiting_user "waiting for DNS A record $domain -> $pubip"
  warn "After DNS is ready, rerun:"
  warn "  DOMAIN=$domain DOMAIN_MODE=$domain_mode CONFIRM_DOMAIN_BINDING=1 INSTANCE_TYPE=$instance_type bash scripts/orchestrate.sh"
  return 2
}
