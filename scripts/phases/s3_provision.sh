#!/usr/bin/env bash
# S3 PROVISION - Lightsail by default, EC2 when explicitly selected.
#
# Every resource is persisted immediately so deployment can resume and
# destroy.sh can clean up.

S3_PHASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
source "$S3_PHASE_DIR/lib/domain.sh"
source "$S3_PHASE_DIR/lib/server-release.sh"
source "$S3_PHASE_DIR/lib/updater-release.sh"

DIREXTALK_ROOT_VOLUME_GB=${DIREXTALK_ROOT_VOLUME_GB:-50}
DIREXTALK_ROOT_DEVICE_NAME=${DIREXTALK_ROOT_DEVICE_NAME:-/dev/sda1}
DEFAULT_LIGHTSAIL_MONTHLY_USD=${DEFAULT_LIGHTSAIL_MONTHLY_USD:-12}
DEFAULT_LIGHTSAIL_BLUEPRINT_ID=${DEFAULT_LIGHTSAIL_BLUEPRINT_ID:-ubuntu_24_04}
DEFAULT_LIGHTSAIL_RAM_GB=${DEFAULT_LIGHTSAIL_RAM_GB:-2}
DEFAULT_LIGHTSAIL_DISK_GB=${DEFAULT_LIGHTSAIL_DISK_GB:-60}
DEFAULT_LIGHTSAIL_ZONE_SUFFIX=${DEFAULT_LIGHTSAIL_ZONE_SUFFIX:-a}

run_phase() {
  aws_env_prep
  if ! updater_release_validate_pin; then
    phase_set S3_PROVISION failed "pinned updater release metadata is invalid"
    return 1
  fi
  if ! server_release_prepare_state; then
    phase_set S3_PROVISION failed "formal server release resolution failed"
    return 1
  fi
  local cloud_provider
  cloud_provider=$(_resolve_cloud_provider)
  state_set cloud_provider "$cloud_provider"
  case "$cloud_provider" in
    lightsail) _run_phase_lightsail ;;
    ec2) _run_phase_ec2 ;;
    *)
      phase_set S3_PROVISION waiting_user "unknown cloud provider"
      warn "Unknown cloud provider: $cloud_provider. Expected lightsail or ec2."
      return 2
      ;;
  esac
}

_run_phase_ec2() {
  phase_set S3_PROVISION in_progress "provisioning EC2"

  local name region instance_type ami sg vpc
  name=$(state_get run_id)
  region=$(state_get region)
  instance_type=$(state_get instance_type)
  if [ -z "$instance_type" ]; then
    instance_type=${INSTANCE_TYPE:-}
    if [ -z "$instance_type" ]; then
      if [ "${DIREXTALK_ASSUME_DEFAULTS:-0}" = "1" ]; then
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
  message_server_image=$(state_get server_release.image_ref)
  local scripts_dir=${DIREXTALK_INSTALL_SCRIPTS_DIR:-${HERE:-$S3_PHASE_DIR}}

  # 1) Key pair (idempotent).
  local keyfile="$DIREXTALK_WORKDIR/${name}.pem"
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
         --description "dirextalk $name" --vpc-id "$vpc" --query GroupId --output text)
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
  local userdata="$DIREXTALK_WORKDIR/user-data.yaml"
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
    res_set root_volume_gb "$DIREXTALK_ROOT_VOLUME_GB"
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
  local pubip eip
  eip=$(res_get eip_id)
  if [ -z "$eip" ]; then
    log "Allocating and associating Elastic IP ..."
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
  fi
  pubip=$(_ensure_ec2_eip_attachment "$iid" "$eip") || {
    phase_set S3_PROVISION failed "failed to reconcile EIP attachment"
    warn "Failed to prove and reconcile Elastic IP $eip with instance $iid."
    return 1
  }
  res_set public_ip "$pubip"
  if ! _resume_host_bootstrap "$pubip" "$keyfile"; then
    phase_set S3_PROVISION failed "failed to resume host bootstrap on EC2"
    return 1
  fi
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

_run_phase_lightsail() {
  phase_set S3_PROVISION in_progress "provisioning Lightsail"

  local name region bundle blueprint zone keyfile domain_mode domain message_server_image scripts_dir userdata userdata_aws
  local instance_name static_ip_name pubip
  name=$(state_get run_id)
  region=$(state_get region)
  bundle=$(res_get lightsail_bundle_id)
  if [ -z "$bundle" ]; then
    bundle=$(_select_lightsail_bundle) || {
      phase_set S3_PROVISION failed "Lightsail $DEFAULT_LIGHTSAIL_MONTHLY_USD bundle unavailable"
      warn "Could not select a Lightsail Linux/Unix bundle near $DEFAULT_LIGHTSAIL_MONTHLY_USD USD/month."
      warn "Set DIREXTALK_LIGHTSAIL_BUNDLE_ID to override, or DIREXTALK_CLOUD_PROVIDER=ec2 to use EC2."
      return 1
    }
  fi
  blueprint=$(res_get lightsail_blueprint_id)
  blueprint=${DIREXTALK_LIGHTSAIL_BLUEPRINT_ID:-${blueprint:-$DEFAULT_LIGHTSAIL_BLUEPRINT_ID}}
  res_set lightsail_blueprint_id "$blueprint"
  zone=$(res_get lightsail_availability_zone)
  zone=${DIREXTALK_LIGHTSAIL_AVAILABILITY_ZONE:-${zone:-}}
  if [ -z "$zone" ]; then
    zone=$(_lightsail_default_zone "$region") || {
      phase_set S3_PROVISION failed "no available Lightsail availability zone"
      warn "No Lightsail availability zone is available in region $region. Rerun S1 preflight to select EC2, or choose another region."
      return 1
    }
  fi
  res_set lightsail_availability_zone "$zone"
  instance_name=$(res_get lightsail_instance_name)
  instance_name=${instance_name:-$(_aws_resource_name dirextalk "$(state_get domain)")}
  static_ip_name=$(res_get lightsail_static_ip_name)
  static_ip_name=${static_ip_name:-$(_aws_resource_name dirextalk-ip "$(state_get domain)")}
  res_set lightsail_instance_name "$instance_name"
  res_set lightsail_static_ip_name "$static_ip_name"

  domain_mode=$(state_get domain_mode)
  domain=$(state_get domain)
  domain=$(domain_normalize "$domain")
  if [ -z "$domain" ]; then
    phase_set S3_PROVISION waiting_user "production domain missing"
    warn "S3 requires a production DOMAIN. Complete S2_DOMAIN first."
    return 2
  fi
  message_server_image=$(state_get server_release.image_ref)
  scripts_dir=${DIREXTALK_INSTALL_SCRIPTS_DIR:-${HERE:-$S3_PHASE_DIR}}

  keyfile="$DIREXTALK_WORKDIR/${name}.pem"
  if [ -z "$(res_get key_name)" ]; then
    log "Creating Lightsail key pair $name ..."
    if ! aws lightsail create-key-pair --key-pair-name "$name" --query privateKeyBase64 --output text \
      | _decode_lightsail_private_key > "$keyfile"; then
      rm -f "$keyfile"
      phase_set S3_PROVISION failed "failed to write Lightsail private key"
      warn "Lightsail private key was not PEM text or base64-encoded PEM text. Delete the partial key pair or rerun after checking AWS CLI output."
      return 1
    fi
    restrict_private_file "$keyfile"
    res_set key_name "$name"; res_set key_file "$keyfile"
  else
    log "Lightsail key pair already exists; skipping."; keyfile=$(res_get key_file)
  fi

  userdata="$DIREXTALK_WORKDIR/user-data.sh"
  log "Rendering Lightsail launch script (domain_mode=$domain_mode, provider=lightsail)..."
  bash "$scripts_dir/render/render-userdata.sh" \
    --format shell \
    --domain "$domain" \
    --acme "${ACME_EMAIL:-}" \
    --message-server-image "$message_server_image" \
    > "$userdata"
  userdata_aws="$userdata"
  if command -v cygpath >/dev/null 2>&1; then
    userdata_aws=$(cygpath -w "$userdata")
  fi
  res_set user_data "$userdata"

  if [ -n "$(res_get instance_id)" ] && aws lightsail get-instance --instance-name "$instance_name" >/dev/null 2>&1; then
    log "Lightsail instance $instance_name already exists; skipping creation."
  else
    log "Launching Lightsail instance ($bundle, $blueprint, $zone)..."
    aws lightsail create-instances \
      --instance-names "$instance_name" \
      --availability-zone "$zone" \
      --blueprint-id "$blueprint" \
      --bundle-id "$bundle" \
      --key-pair-name "$name" \
      --user-data "file://$userdata_aws" \
      --tags "key=Name,value=$name" >/dev/null || {
        phase_set S3_PROVISION failed "Lightsail create-instances failed"
        warn "Lightsail instance creation failed. Check Lightsail availability, bundle support, and AWS permissions."
        return 1
    }
    res_set instance_id "$instance_name"
    res_set lightsail_instance_created "true"
  fi
  _wait_lightsail_instance_running "$instance_name" || return $?
  if [ "$(res_get lightsail_ports_configured)" != "true" ]; then
    _open_lightsail_ports "$instance_name" || return $?
    res_set lightsail_ports_configured "true"
  fi

  if ! aws lightsail get-static-ip --static-ip-name "$static_ip_name" --query 'staticIp.name' --output text >/dev/null 2>&1; then
    log "Allocating Lightsail static IP $static_ip_name ..."
    local allocate_rc=0
    _allocate_lightsail_static_ip "$static_ip_name" || allocate_rc=$?
    if [ "$allocate_rc" -eq 2 ]; then
      return 2
    fi
    [ "$allocate_rc" -eq 0 ] || {
      phase_set S3_PROVISION failed "failed to allocate Lightsail static IP"
      warn "Failed to allocate Lightsail static IP. Check regional Lightsail quota and AWS permissions."
      return 1
    }
  fi
  pubip=$(_ensure_lightsail_static_ip_attachment "$instance_name" "$static_ip_name") || {
    phase_set S3_PROVISION failed "failed to reconcile Lightsail static IP attachment"
    warn "Failed to prove and reconcile static IP $static_ip_name with instance $instance_name."
    return 1
  }
  res_set public_ip "$pubip"
  res_set static_ip_name "$static_ip_name"
  if ! _resume_host_bootstrap "$pubip" "$keyfile"; then
    phase_set S3_PROVISION failed "failed to resume host bootstrap on Lightsail"
    return 1
  fi
  log "Public IP = $pubip; domain = $(state_get domain)"

  if [ "$domain_mode" = "route53" ]; then
    local route53_rc=0
    _upsert_route53_record "$domain" "$pubip" || route53_rc=$?
    [ "$route53_rc" -eq 0 ] || return "$route53_rc"
  fi

  if [ "$domain_mode" = "user" ] || [ "$domain_mode" = "route53" ]; then
    _require_user_dns_ready "$domain_mode" "$domain" "$pubip" "DIREXTALK_CLOUD_PROVIDER=lightsail" || return 2
  fi

  _record_lightsail_cost_estimate "$bundle"
  phase_set S3_PROVISION done "lightsail_instance=$instance_name ip=$pubip domain=$(state_get domain)"
  return 0
}

_ensure_ec2_eip_attachment() {
  local instance_id=$1 allocation_id=$2 attached_to public_ip attempt
  local attempts=${DIREXTALK_STABLE_IP_RECONCILE_ATTEMPTS:-12}
  local delay=${DIREXTALK_STABLE_IP_RECONCILE_DELAY:-2}
  attached_to=$(aws ec2 describe-addresses --allocation-ids "$allocation_id" \
    --query 'Addresses[0].InstanceId' --output text) || return 1
  if [ "$attached_to" != "$instance_id" ]; then
    log "Associating Elastic IP $allocation_id with current instance $instance_id ..." >&2
    aws ec2 associate-address --instance-id "$instance_id" --allocation-id "$allocation_id" --allow-reassociation >/dev/null || return 1
    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
      attached_to=$(aws ec2 describe-addresses --allocation-ids "$allocation_id" \
        --query 'Addresses[0].InstanceId' --output text) || return 1
      [ "$attached_to" = "$instance_id" ] && break
      [ "$attempt" -lt "$attempts" ] && sleep "$delay"
      attempt=$((attempt + 1))
    done
    [ "$attached_to" = "$instance_id" ] || return 1
  fi
  public_ip=$(aws ec2 describe-addresses --allocation-ids "$allocation_id" \
    --query 'Addresses[0].PublicIp' --output text) || return 1
  _is_canonical_ipv4 "$public_ip" || return 1
  printf '%s\n' "$public_ip"
}

_ensure_lightsail_static_ip_attachment() {
  local instance_name=$1 static_ip_name=$2 attached_to public_ip attempt
  local attempts=${DIREXTALK_STABLE_IP_RECONCILE_ATTEMPTS:-12}
  local delay=${DIREXTALK_STABLE_IP_RECONCILE_DELAY:-2}
  attached_to=$(aws lightsail get-static-ip --static-ip-name "$static_ip_name" \
    --query 'staticIp.attachedTo' --output text) || return 1
  if [ "$attached_to" != "$instance_name" ]; then
    log "Attaching Lightsail static IP $static_ip_name to current instance $instance_name ..." >&2
    aws lightsail attach-static-ip --static-ip-name "$static_ip_name" --instance-name "$instance_name" >/dev/null || return 1
    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
      attached_to=$(aws lightsail get-static-ip --static-ip-name "$static_ip_name" \
        --query 'staticIp.attachedTo' --output text) || return 1
      [ "$attached_to" = "$instance_name" ] && break
      [ "$attempt" -lt "$attempts" ] && sleep "$delay"
      attempt=$((attempt + 1))
    done
    [ "$attached_to" = "$instance_name" ] || return 1
  fi
  public_ip=$(aws lightsail get-static-ip --static-ip-name "$static_ip_name" \
    --query 'staticIp.ipAddress' --output text) || return 1
  _is_canonical_ipv4 "$public_ip" || return 1
  printf '%s\n' "$public_ip"
}

_is_canonical_ipv4() {
  local ip=${1:-} part
  local -a parts
  case "$ip" in *$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;; esac
  printf '%s\n' "$ip" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [ "$part" -le 255 ] || return 1
  done
}

_resume_host_bootstrap() {
  local public_ip=$1 keyfile=$2
  local known_hosts="$DIREXTALK_WORKDIR/known_hosts" attempt result identity integration_bundle remote_command
  local attempts=${DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS:-60}
  local delay=${DIREXTALK_BOOTSTRAP_SSH_DELAY:-5}
  _is_canonical_ipv4 "$public_ip" || {
    warn "Host bootstrap resume rejected a non-canonical public IPv4 address."
    return 1
  }
  [ -n "$public_ip" ] && [ -f "$keyfile" ] || {
    warn "Host bootstrap resume requires a stable public IP and the recorded SSH key."
    return 1
  }
  integration_bundle=$(mktemp "$DIREXTALK_WORKDIR/.updater-integration.XXXXXX.tar.gz") || return 1
  if ! tar -C "$S3_PHASE_DIR" -cf - \
      updater/bootstrap-host.sh \
      updater/install.sh \
      updater/reconcile-host.sh \
      updater/set-desired-state.sh \
      updater/release.env \
      updater/config.json \
      updater/dirextalk-updater.service \
      updater/dirextalk-updater-discovery.service \
      updater/dirextalk-updater-discovery.timer \
      | gzip -n > "$integration_bundle"; then
    rm -f "$integration_bundle"
    warn "Failed to build the updater integration bundle."
    return 1
  fi
  remote_command="stage=\$(mktemp -d /tmp/dirextalk-updater-integration.XXXXXX) && trap 'rm -rf \"\$stage\"' EXIT && tar -xzf - -C \"\$stage\" && sudo bash \"\$stage/updater/reconcile-host.sh\" \"\$stage/updater\" /var/dirextalk-message-server '$public_ip'"
  identity=$(printf '%s\t%s\t%s' "$UPDATER_PIN_VERSION" "$UPDATER_PIN_COMMIT" "$UPDATER_PIN_SHA256")
  log "Synchronizing the pinned updater integration and resuming bootstrap through the stable public IP before DNS gating..."
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if result=$(ssh -T -i "$keyfile" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$known_hosts" \
        "ubuntu@$public_ip" \
        "$remote_command" < "$integration_bundle"); then
      if [ "$(printf '%s\n' "$result" | tail -n 1)" = "$identity" ]; then
        rm -f "$integration_bundle"
        updater_release_record_state
        return $?
      fi
      warn "Remote updater identity did not match the deployer pin (attempt $attempt/$attempts)."
    fi
    warn "SSH/updater integration bootstrap is not ready (attempt $attempt/$attempts); retrying in ${delay}s."
    attempt=$((attempt + 1))
    [ "$attempt" -le "$attempts" ] && sleep "$delay"
  done
  rm -f "$integration_bundle"
  warn "Timed out resuming host bootstrap through $public_ip. Rerun S3 to retry the idempotent bootstrap."
  return 1
}

_resolve_cloud_provider() {
  local provider
  provider=$(state_get cloud_provider)
  provider=${DIREXTALK_CLOUD_PROVIDER:-${DEPLOY_MODE:-${DIREXTALK_DEPLOY_PROVIDER:-$provider}}}
  provider=${provider:-lightsail}
  provider=$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')
  case "$provider" in
    lightsail|ec2) printf '%s\n' "$provider" ;;
    *) printf '%s\n' "$provider" ;;
  esac
}

_aws_resource_name() {
  local prefix=$1 value=$2 suffix
  suffix=$(printf '%s' "$value" | sed -E 's#^https?://##; s#[^A-Za-z0-9-]+#-#g; s#^-+##; s#-+$##' | tr '[:upper:]' '[:lower:]')
  printf '%s-%s\n' "$prefix" "$suffix" | cut -c1-255
}

_decode_lightsail_private_key() {
  "$(json_node)" -e '
let input = "";
process.stdin.on("data", (d) => input += d);
process.stdin.on("end", () => {
  const raw = input.replace(/\r\n/g, "\n").trim();
  const pemRe = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/;
  const writePem = (value) => {
    const pem = value.replace(/\r\n/g, "\n").trim();
    process.stdout.write(pem.endsWith("\n") ? pem : `${pem}\n`);
  };
  if (pemRe.test(raw)) {
    writePem(raw);
    return;
  }
  const decoded = Buffer.from(raw.replace(/\s+/g, ""), "base64").toString("utf8");
  if (pemRe.test(decoded)) {
    writePem(decoded);
    return;
  }
  console.error("Lightsail private key was neither PEM text nor base64-encoded PEM text.");
  process.exit(1);
});'
}

_wait_lightsail_instance_running() {
  local instance_name=$1 attempts=${DIREXTALK_LIGHTSAIL_READY_ATTEMPTS:-60} interval=${DIREXTALK_LIGHTSAIL_READY_INTERVAL_SECONDS:-5}
  local i state
  log "Waiting for Lightsail instance $instance_name to become running ..."
  for ((i=1; i<=attempts; i++)); do
    state=$(aws lightsail get-instance --instance-name "$instance_name" --query 'instance.state.name' --output text 2>/dev/null | tr -d '\r' || true)
    case "$state" in
      running)
        res_set lightsail_instance_state running
        return 0
        ;;
      pending|starting|stopping|stopped|"")
        ;;
      *)
        warn "Lightsail instance $instance_name state is $state; waiting before network operations."
        ;;
    esac
    [ "$i" -lt "$attempts" ] && sleep "$interval"
  done
  phase_set S3_PROVISION failed "Lightsail instance did not become running before timeout"
  warn "Timed out waiting for Lightsail instance $instance_name to become running. Check AWS Lightsail instance state, then rerun to resume."
  return 1
}

_allocate_lightsail_static_ip() {
  local static_ip_name=$1 out rc
  out=$(aws lightsail allocate-static-ip --static-ip-name "$static_ip_name" 2>&1) && return 0
  rc=$?
  if printf '%s\n' "$out" | grep -Eiq 'maximum number of static IP|static ip.*quota|quota.*static ip|limitexceeded'; then
    res_set lightsail_static_ip_allocation_status quota_exceeded
    res_set lightsail_static_ip_quota_action "Run aws lightsail get-static-ips --region $(state_get region), detach and release an unused static IP or request a quota increase, then rerun the deployer."
    phase_set S3_PROVISION waiting_user "Lightsail static IP quota exhausted"
    [ -z "$out" ] || warn "$out"
    warn "Lightsail static IP quota is exhausted in region $(state_get region)."
    warn "List existing static IPs:"
    warn "  aws lightsail get-static-ips --region $(state_get region) --output table"
    warn "Detach and release an unused static IP, or request a Lightsail static IP quota increase, then rerun to resume."
    return 2
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  return "$rc"
}

_lightsail_default_zone() {
  local region=$1 tmp line rc zone default_zone available unavailable reason status
  tmp=$(mktemp)
  if ! aws lightsail get-regions --include-availability-zones --output json > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    res_set lightsail_availability_status unknown
    res_set lightsail_default_availability_zone "${region}${DEFAULT_LIGHTSAIL_ZONE_SUFFIX}"
    return 1
  fi
  rc=0
  line=$("$(json_node)" - "$tmp" "$region" "$DEFAULT_LIGHTSAIL_ZONE_SUFFIX" <<'NODE'
const fs = require("fs");
const [file, regionName, suffix] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const defaultZone = `${regionName}${suffix || "a"}`;
const region = (Array.isArray(data.regions) ? data.regions : []).find((item) => item.name === regionName);
if (!region) {
  process.stdout.write(["", defaultZone, "", "", `Lightsail region ${regionName} was not returned by get-regions`].join("\t"));
  process.exit(2);
}
const zones = Array.isArray(region.availabilityZones) ? region.availabilityZones : [];
const available = zones.filter((item) => String(item.zoneName || "") && String(item.state || "").toLowerCase() !== "unavailable").map((item) => String(item.zoneName));
const unavailable = zones.filter((item) => String(item.zoneName || "") && String(item.state || "").toLowerCase() === "unavailable").map((item) => String(item.zoneName));
const selected = available.includes(defaultZone) ? defaultZone : (available[0] || "");
const reason = selected
  ? (selected === defaultZone ? "" : `default Lightsail zone ${defaultZone} is unavailable; selected ${selected}`)
  : `no available Lightsail availability zone found for region ${regionName}`;
process.stdout.write([selected, defaultZone, available.join(","), unavailable.join(","), reason].join("|"));
if (!selected) process.exit(2);
NODE
  ) || rc=$?
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
  selected=$("$(json_node)" - "$tmp" "$DEFAULT_LIGHTSAIL_MONTHLY_USD" "$DEFAULT_LIGHTSAIL_RAM_GB" "$DEFAULT_LIGHTSAIL_DISK_GB" <<'NODE'
const fs = require("fs");
const [file, targetPrice, targetRam, targetDisk] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const num = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;
const platformOk = (bundle) => {
  const text = String(bundle.supportedPlatforms || bundle.supportedPlatform || bundle.platform || "").toLowerCase();
  return !text || text.includes("linux") || text.includes("unix");
};
const candidates = (Array.isArray(data.bundles) ? data.bundles : [])
  .filter(platformOk)
  .map((bundle) => ({
    id: String(bundle.bundleId || ""),
    price: num(bundle.price),
    ram: num(bundle.ramSizeInGb),
    disk: num(bundle.diskSizeInGb),
    transfer: num(bundle.transferPerMonthInGb),
    cpu: num(bundle.cpuCount)
  }))
  .filter((bundle) => bundle.id && bundle.price > 0);
const exact = candidates.filter((bundle) => Math.abs(bundle.price - Number(targetPrice)) < 0.01 && bundle.ram >= Number(targetRam) && bundle.disk >= Number(targetDisk));
const fallback = candidates.filter((bundle) => bundle.price >= Number(targetPrice) && bundle.ram >= Number(targetRam));
const selected = (exact.length ? exact : fallback).sort((a, b) => a.price - b.price || a.ram - b.ram || a.disk - b.disk)[0];
if (!selected) process.exit(1);
process.stdout.write([selected.id, selected.price, selected.ram, selected.disk, selected.transfer, selected.cpu].join("\t"));
NODE
  ) || {
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

_open_lightsail_ports() {
  local instance_name=$1 rule protocol from to
  for rule in tcp:22:22 tcp:80:80 tcp:443:443 tcp:3478:3478 udp:3478:3478 udp:49160:49200; do
    IFS=: read -r protocol from to <<EOF
$rule
EOF
    aws lightsail open-instance-public-ports \
      --instance-name "$instance_name" \
      --port-info "fromPort=$from,toPort=$to,protocol=$protocol" >/dev/null || {
        phase_set S3_PROVISION failed "failed to open Lightsail public ports"
        warn "Failed to open Lightsail port $protocol $from-$to. Check AWS permissions and rerun."
        return 1
      }
  done
}

_record_lightsail_cost_estimate() {
  local bundle=$1 price ram disk transfer cpu route53_monthly total estimate
  price=$(res_get lightsail_bundle_price_usd)
  ram=$(res_get lightsail_bundle_ram_gb)
  disk=$(res_get lightsail_bundle_disk_gb)
  transfer=$(res_get lightsail_bundle_transfer_gb)
  cpu=$(res_get lightsail_bundle_cpu_count)
  route53_monthly=0
  [ "$(state_get domain_mode)" = "route53" ] && route53_monthly=${DIREXTALK_ROUTE53_HOSTED_ZONE_MONTHLY_USD:-0.50}
  total=$(awk -v p="${price:-$DEFAULT_LIGHTSAIL_MONTHLY_USD}" -v r="$route53_monthly" 'BEGIN { printf "%.2f", p + r }')
  estimate=$(json_build object \
    provider=lightsail \
    pricing_status=bundle_price_recorded \
    "total_monthly_usd=$total" \
    "components={\"lightsail_bundle\":{\"bundle_id\":\"$bundle\",\"monthly_usd\":${price:-$DEFAULT_LIGHTSAIL_MONTHLY_USD},\"ram_gb\":${ram:-$DEFAULT_LIGHTSAIL_RAM_GB},\"disk_gb\":${disk:-$DEFAULT_LIGHTSAIL_DISK_GB},\"transfer_gb\":${transfer:-0},\"cpu_count\":${cpu:-0}},\"route53_hosted_zone\":{\"monthly_usd\":$route53_monthly,\"included\":$( [ "$(state_get domain_mode)" = "route53" ] && printf true || printf false )}}" \
    'notes=["Estimate excludes data transfer beyond the Lightsail bundle, TURN relay traffic, domain registration, taxes, and AWS credit eligibility."]' \
    'recommendations=["Set an AWS Budget or billing alert before leaving the node running.","Review AWS Billing Console after deployment and after destroy to confirm actual charges."]')
  state_set_raw cost_estimate "$estimate"
}

_root_block_device_mappings() {
  printf '[{"DeviceName":"%s","Ebs":{"VolumeSize":%s,"VolumeType":"gp3","DeleteOnTermination":true}}]\n' \
    "$DIREXTALK_ROOT_DEVICE_NAME" \
    "$DIREXTALK_ROOT_VOLUME_GB"
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
  zone=$(_find_required_route53_zone "$domain") || {
    phase_set S3_PROVISION failed "Route53 hosted zone unavailable"
    warn "DOMAIN_MODE=route53 requires an existing public Route53 hosted zone for $domain and permission to list it."
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
  "Comment": "Dirextalk deployment",
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
  confirmed=${DIREXTALK_CONFIRM_DNS_OVERWRITE:-${CONFIRM_DNS_OVERWRITE:-0}}
  if [ "$confirmed" = "1" ]; then
    res_set route53_overwrite_confirmed "true"
    warn "Route53 A record overwrite confirmed: $domain $existing -> $pubip."
    return 0
  fi

  phase_set S3_PROVISION waiting_user "Route53 A record overwrite requires confirmation"
  warn "Route53 A record overwrite requires confirmation for $domain."
  warn "Current A record: $existing"
  warn "New deployment IP: $pubip"
  warn "If this is intentional, rerun with DIREXTALK_CONFIRM_DNS_OVERWRITE=1."
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

_find_required_route53_zone() {
  local domain=$1 zone zone_id zone_name find_rc
  if zone=$(_route53_zone_from_state); then
    printf '%s\n' "$zone"
    return 0
  fi

  if zone=$(route53_find_public_hosted_zone "$domain"); then
    zone_id=$(printf '%s' "$zone" | cut -f1)
    zone_name=$(printf '%s' "$zone" | cut -f2)
    _record_route53_zone "$zone_id" "$zone_name" false
    printf '%s\n' "$zone"
    return 0
  else
    find_rc=$?
  fi

  [ "$find_rc" -eq 1 ] && warn "No matching public Route53 hosted zone exists for $domain."
  return 1
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
    warn "Update DNS so $domain has an A record pointing to this public IP:"
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
  if [ "$instance_type" = "DIREXTALK_CLOUD_PROVIDER=lightsail" ]; then
    warn "  DOMAIN=$domain DOMAIN_MODE=$domain_mode CONFIRM_DOMAIN_BINDING=1 DIREXTALK_CLOUD_PROVIDER=lightsail bash scripts/orchestrate.sh"
  else
    warn "  DOMAIN=$domain DOMAIN_MODE=$domain_mode CONFIRM_DOMAIN_BINDING=1 DIREXTALK_CLOUD_PROVIDER=ec2 INSTANCE_TYPE=$instance_type bash scripts/orchestrate.sh"
  fi
  return 2
}
