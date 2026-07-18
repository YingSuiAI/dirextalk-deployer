#!/usr/bin/env bash
# S3 PROVISION - Lightsail by default, EC2 when explicitly selected.
#
# Every resource is persisted immediately so deployment can resume and
# destroy.sh can clean up.

S3_PHASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
source "$S3_PHASE_DIR/lib/domain.sh"
source "$S3_PHASE_DIR/lib/server-release.sh"
source "$S3_PHASE_DIR/lib/agent-release.sh"
source "$S3_PHASE_DIR/lib/agent-ecr-pull.sh"
source "$S3_PHASE_DIR/lib/agent-secret-delivery.sh"
source "$S3_PHASE_DIR/lib/updater-release.sh"

DIREXTALK_ROOT_VOLUME_GB=${DIREXTALK_ROOT_VOLUME_GB:-50}
DIREXTALK_ROOT_DEVICE_NAME=${DIREXTALK_ROOT_DEVICE_NAME:-/dev/sda1}
DEFAULT_LIGHTSAIL_MONTHLY_USD=${DEFAULT_LIGHTSAIL_MONTHLY_USD:-12}
DEFAULT_LIGHTSAIL_BLUEPRINT_ID=${DEFAULT_LIGHTSAIL_BLUEPRINT_ID:-ubuntu_24_04}
DEFAULT_LIGHTSAIL_RAM_GB=${DEFAULT_LIGHTSAIL_RAM_GB:-2}
DEFAULT_LIGHTSAIL_DISK_GB=${DEFAULT_LIGHTSAIL_DISK_GB:-60}
DEFAULT_LIGHTSAIL_ZONE_SUFFIX=${DEFAULT_LIGHTSAIL_ZONE_SUFFIX:-a}
# Lightsail receives only a deliberately small launcher. The rendered bootstrap
# is streamed through authenticated SSH after the stable IP is attached.
LIGHTSAIL_LAUNCH_USER_DATA_MAX_BYTES=16000

run_phase() {
  if ! updater_release_validate_pin; then
    phase_set S3_PROVISION failed "pinned updater release metadata is invalid"
    return 1
  fi
  if ! server_release_prepare_state; then
    phase_set S3_PROVISION failed "message-server image selection failed"
    return 1
  fi
  if ! agent_release_prepare_state; then
    phase_set S3_PROVISION failed "Agent image selection failed"
    return 1
  fi
  if ! agent_aws_control_prepare_state; then
    phase_set S3_PROVISION failed "Agent AWS control selection failed"
    return 1
  fi
  if ! server_release_require_agent_compatible; then
    phase_set S3_PROVISION failed "Agent requires an immutable Message Server release"
    return 1
  fi
  if ! agent_release_require_render_inputs; then
    phase_set S3_PROVISION failed "Agent model-profile catalog is unavailable"
    return 1
  fi
  if ! agent_aws_control_require_render_inputs; then
    phase_set S3_PROVISION failed "Agent Worker AMI publication is unavailable"
    return 1
  fi
  if ! agent_mounted_secret_delivery_inputs_validate; then
    phase_set S3_PROVISION failed "Agent mounted-secret delivery input is invalid"
    return 1
  fi
  local cloud_provider
  cloud_provider=$(_resolve_cloud_provider)
  aws_env_prep
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

  local name region instance_type ami sg vpc domain_mode domain scripts_dir
  local message_server_image agent_image agent_instance_id agent_enabled agent_aws_control_enabled
  local agent_aws_reaper_image_uri agent_worker_control_endpoint agent_managed_preparation_aws
  local agent_worker_ami_publication_snapshot_file agent_worker_ami_publication_sha256
  local bootstrap_script bootstrap_sha256 bootstrap_nonce_file bootstrap_nonce launch_userdata launch_userdata_aws bootstrap_tmp known_hosts
  local iid instance_state keyfile pubip eip defer_start=0 client_token frozen_artifacts
  local -a agent_render_args=() render_args=()
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
  domain_mode=$(state_get domain_mode)
  domain=$(domain_normalize "$(state_get domain)")
  if [ -z "$domain" ]; then
    phase_set S3_PROVISION waiting_user "production domain missing"
    warn "S3 requires a production DOMAIN. Complete S2_DOMAIN first."
    return 2
  fi
  message_server_image=$(state_get server_release.image_ref)
  agent_image=$(state_get agent_release.image_ref)
  agent_instance_id=$(state_get agent_release.instance_id)
  agent_enabled=$(state_get agent_release.enabled)
  agent_aws_control_enabled=$(state_get agent_aws_control.enabled)
  agent_aws_reaper_image_uri=$(state_get agent_aws_control.aws_reaper_image_uri)
  agent_worker_control_endpoint=$(state_get agent_aws_control.worker_control_endpoint)
  agent_managed_preparation_aws=$(state_get agent_aws_control.managed_preparation_aws)
  agent_worker_ami_publication_snapshot_file=$(state_get agent_aws_control.worker_ami_publication_snapshot_file)
  agent_worker_ami_publication_sha256=$(state_get agent_aws_control.worker_ami_publication_sha256)
  if [ -n "$agent_image" ]; then
    agent_ecr_prepare_state "$agent_image" || {
      phase_set S3_PROVISION failed "private Agent ECR selection failed"
      return 1
    }
    agent_render_args=(
      --agent-image "$agent_image"
      --agent-instance-id "$agent_instance_id"
      --agent-model-profiles-file "$AGENT_MODEL_PROFILES_FILE"
    )
    if [ "$agent_aws_control_enabled" = true ]; then
      agent_render_args+=(
        --agent-enable-aws-control true
        --agent-aws-reaper-image-uri "$agent_aws_reaper_image_uri"
        --agent-worker-control-endpoint "$agent_worker_control_endpoint"
        --agent-enable-managed-preparation-aws "$agent_managed_preparation_aws"
        --agent-worker-ami-publication-file "$agent_worker_ami_publication_snapshot_file"
        --agent-worker-ami-publication-sha256 "$agent_worker_ami_publication_sha256"
      )
    fi
    defer_start=1
  fi
  scripts_dir=${DIREXTALK_INSTALL_SCRIPTS_DIR:-${HERE:-$S3_PHASE_DIR}}

  # Freeze the full root bootstrap before any AWS mutation. EC2 receives only
  # the same 64-hex identity nonce launcher used by the verified SSH model.
  iid=$(res_get instance_id)
  bootstrap_script=$(res_get ec2_bootstrap_script)
  bootstrap_sha256=$(res_get ec2_bootstrap_sha256)
  bootstrap_nonce_file=$(res_get ec2_bootstrap_nonce_file)
  launch_userdata=$(res_get user_data)
  known_hosts=$(res_get ec2_ssh_known_hosts)
  known_hosts=${known_hosts:-"$DIREXTALK_WORKDIR/ec2-known-hosts"}
  client_token=$(res_get ec2_client_token)
  if [ -n "$client_token" ] && ! printf '%s\n' "$client_token" | grep -Eq '^[0-9a-f]{64}$'; then
    phase_set S3_PROVISION failed "EC2 idempotency token is invalid"
    return 1
  fi
  if [ -n "$iid" ]; then
    instance_state=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null) || {
      phase_set S3_PROVISION failed "could not determine whether EC2 instance exists"
      warn "Could not prove the recorded EC2 instance state. Refusing to replace bootstrap artifacts or create a duplicate instance."
      return 1
    }
    printf '%s\n' "$instance_state" | grep -Eq '^(running|pending)$' || {
      phase_set S3_PROVISION failed "recorded EC2 instance is not resumable"
      warn "Recorded EC2 instance $iid is $instance_state; refusing to create a replacement under the frozen identity."
      return 1
    }
  fi
  frozen_artifacts=$bootstrap_script$bootstrap_sha256$bootstrap_nonce_file$launch_userdata$client_token
  if [ -n "$frozen_artifacts" ]; then
    [ -n "$bootstrap_script" ] && [ -n "$bootstrap_sha256" ] \
      && [ -n "$bootstrap_nonce_file" ] && [ -n "$launch_userdata" ] \
      && [ -f "$bootstrap_script" ] && [ -f "$bootstrap_nonce_file" ] && [ -f "$launch_userdata" ] || {
        phase_set S3_PROVISION failed "EC2 bootstrap artifact is unavailable"
        warn "EC2 provisioning state has no complete locally frozen bootstrap artifact."
        return 1
      }
    [ "$(_s3_file_sha256 "$bootstrap_script")" = "$bootstrap_sha256" ] || {
      phase_set S3_PROVISION failed "EC2 bootstrap artifact changed"
      return 1
    }
    bootstrap_nonce=$(_bootstrap_nonce_read "$bootstrap_nonce_file") || return 1
    bash -n "$launch_userdata" || return 1
    if [ -z "$iid" ] && ! printf '%s\n' "$client_token" | grep -Eq '^[0-9a-f]{64}$'; then
      phase_set S3_PROVISION failed "EC2 idempotency token is unavailable"
      warn "Partial EC2 provisioning has frozen artifacts but no safe client token; refusing a duplicate run-instances request."
      return 1
    fi
  elif [ -n "$iid" ]; then
    phase_set S3_PROVISION failed "EC2 bootstrap artifact is unavailable"
    warn "Existing EC2 infrastructure has no complete locally frozen bootstrap artifact."
    return 1
  else
    bootstrap_script="$DIREXTALK_WORKDIR/ec2-bootstrap.sh"
    launch_userdata="$DIREXTALK_WORKDIR/ec2-launch.sh"
    bootstrap_nonce_file="$DIREXTALK_WORKDIR/ec2-bootstrap.nonce"
    rm -f "$known_hosts"
    bootstrap_tmp=$(mktemp "$DIREXTALK_WORKDIR/.ec2-bootstrap.XXXXXX") || return 1
    render_args=(
      --format shell
      --domain "$domain"
      --acme "${ACME_EMAIL:-}"
      --message-server-image "$message_server_image"
      "${agent_render_args[@]}"
    )
    [ "$defer_start" = 1 ] && render_args+=(--defer-compose-start)
    if ! bash "$scripts_dir/render/render-userdata.sh" "${render_args[@]}" > "$bootstrap_tmp"; then
      rm -f "$bootstrap_tmp"
      phase_set S3_PROVISION failed "EC2 bootstrap script could not be rendered"
      return 1
    fi
    [ -s "$bootstrap_tmp" ] && bash -n "$bootstrap_tmp" || {
      rm -f "$bootstrap_tmp"
      phase_set S3_PROVISION failed "EC2 bootstrap script is invalid"
      return 1
    }
    mv -f "$bootstrap_tmp" "$bootstrap_script"
    restrict_private_file "$bootstrap_script"
    bootstrap_sha256=$(_s3_file_sha256 "$bootstrap_script") || return 1
    bootstrap_nonce=$(_bootstrap_nonce_ensure "$bootstrap_nonce_file") || return 1
    _render_nonce_launch_userdata "$launch_userdata" "$bootstrap_nonce" || return 1
    client_token=$(printf '%s\0%s\0%s' "$name" "$domain" "$region" | sha256sum | awk '{print $1}') || return 1
    printf '%s\n' "$client_token" | grep -Eq '^[0-9a-f]{64}$' || return 1
    res_set user_data "$launch_userdata" || return 1
    res_set ec2_bootstrap_script "$bootstrap_script" || return 1
    res_set ec2_bootstrap_sha256 "$bootstrap_sha256" || return 1
    res_set ec2_bootstrap_nonce_file "$bootstrap_nonce_file" || return 1
    res_set ec2_ssh_known_hosts "$known_hosts" || return 1
    res_set ec2_client_token "$client_token" || return 1
  fi
  [ "$(wc -c < "$launch_userdata" | tr -d '[:space:]')" -lt 512 ] || {
    phase_set S3_PROVISION failed "EC2 launch user-data is not minimal"
    return 1
  }
  launch_userdata_aws=$(dirextalk_native_tool_path "$launch_userdata") || return 1

  # 1) Key pair (idempotent).
  keyfile="$DIREXTALK_WORKDIR/${name}.pem"
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

  # 3) Launch EC2 with nonce-only user-data (idempotent).
  if [ -n "$iid" ]; then
    log "Instance $iid already exists; skipping creation."
  else
    log "Launching EC2 instance (x86 $instance_type, $ami)..."
    res_set root_volume_gb "$DIREXTALK_ROOT_VOLUME_GB"
    iid=$(aws ec2 run-instances --image-id "$ami" --instance-type "$instance_type" \
      --key-name "$name" --security-group-ids "$sg" \
      --client-token "$client_token" \
      --user-data "file://$launch_userdata_aws" \
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
  if ! _bootstrap_ec2_host "$pubip" "$keyfile" "$bootstrap_script" "$bootstrap_nonce"; then
    phase_set S3_PROVISION failed "failed to bootstrap EC2 host over verified SSH"
    return 1
  fi
  if ! _resume_host_bootstrap "$pubip" "$keyfile" "" "$defer_start"; then
    phase_set S3_PROVISION failed "failed to resume host bootstrap on EC2"
    return 1
  fi
  if [ "$agent_enabled" = true ]; then
    if ! _resume_private_agent_with_ecr "$pubip" "$keyfile" "$known_hosts"; then
      phase_set S3_PROVISION failed "private Agent ECR pull/start failed"
      return 1
    fi
  fi
  if agent_mounted_secret_delivery_is_configured; then
    if ! agent_mounted_secret_deliver_pinned "$pubip" "$keyfile" "$known_hosts"; then
      phase_set S3_PROVISION failed "failed to deliver mounted Agent secret over verified SSH"
      return 1
    fi
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

  local name region bundle blueprint zone keyfile domain_mode domain message_server_image agent_image agent_instance_id scripts_dir
  local agent_aws_control_enabled agent_aws_reaper_image_uri agent_worker_control_endpoint agent_managed_preparation_aws
  local agent_worker_ami_publication_snapshot_file agent_worker_ami_publication_sha256
  local bootstrap_script bootstrap_sha256 bootstrap_nonce_file bootstrap_nonce launch_userdata launch_userdata_bytes launch_userdata_aws bootstrap_tmp
  local known_hosts instance_exists instance_lookup instance_lookup_rc
  local -a agent_render_args=()
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
  agent_image=$(state_get agent_release.image_ref)
  agent_instance_id=$(state_get agent_release.instance_id)
  agent_aws_control_enabled=$(state_get agent_aws_control.enabled)
  agent_aws_reaper_image_uri=$(state_get agent_aws_control.aws_reaper_image_uri)
  agent_worker_control_endpoint=$(state_get agent_aws_control.worker_control_endpoint)
  agent_managed_preparation_aws=$(state_get agent_aws_control.managed_preparation_aws)
  agent_worker_ami_publication_snapshot_file=$(state_get agent_aws_control.worker_ami_publication_snapshot_file)
  agent_worker_ami_publication_sha256=$(state_get agent_aws_control.worker_ami_publication_sha256)
  if [ -n "$agent_image" ]; then
    agent_render_args=(
      --agent-image "$agent_image"
      --agent-instance-id "$agent_instance_id"
      --agent-model-profiles-file "$AGENT_MODEL_PROFILES_FILE"
    )
    if [ "$agent_aws_control_enabled" = true ]; then
      agent_render_args+=(
        --agent-enable-aws-control true
        --agent-aws-reaper-image-uri "$agent_aws_reaper_image_uri"
        --agent-worker-control-endpoint "$agent_worker_control_endpoint"
        --agent-enable-managed-preparation-aws "$agent_managed_preparation_aws"
        --agent-worker-ami-publication-file "$agent_worker_ami_publication_snapshot_file"
        --agent-worker-ami-publication-sha256 "$agent_worker_ami_publication_sha256"
      )
    fi
  fi
  scripts_dir=${DIREXTALK_INSTALL_SCRIPTS_DIR:-${HERE:-$S3_PHASE_DIR}}

  # Persist the exact full bootstrap before creating remote state. A resumed
  # deployment with an existing instance must reuse this artifact verbatim so a
  # lost SSH response cannot replace already-generated service secrets.
  instance_exists=0
  instance_lookup=$(mktemp "$DIREXTALK_WORKDIR/.lightsail-instance-lookup.XXXXXX") || return 1
  if aws lightsail get-instance --instance-name "$instance_name" >"$instance_lookup" 2>&1; then
    instance_exists=1
    res_set instance_id "$instance_name"
  else
    instance_lookup_rc=$?
    if grep -Eq '\((NotFoundException|ResourceNotFoundException)\)' "$instance_lookup"; then
      instance_exists=0
    else
      rm -f "$instance_lookup"
      phase_set S3_PROVISION failed "could not determine whether Lightsail instance exists"
      warn "Could not determine whether Lightsail instance $instance_name exists (AWS CLI rc=$instance_lookup_rc). Refusing to alter bootstrap artifacts or create a duplicate instance; check AWS reachability and permissions, then rerun."
      return 1
    fi
  fi
  rm -f "$instance_lookup"
  known_hosts="$DIREXTALK_WORKDIR/known_hosts"
  if [ "$instance_exists" = 1 ]; then
    bootstrap_script=$(res_get lightsail_bootstrap_script)
    bootstrap_sha256=$(res_get lightsail_bootstrap_sha256)
    bootstrap_nonce_file=$(res_get lightsail_bootstrap_nonce_file)
    launch_userdata=$(res_get user_data)
    known_hosts=$(res_get lightsail_ssh_known_hosts)
    known_hosts=${known_hosts:-"$DIREXTALK_WORKDIR/known_hosts"}
    [ -n "$bootstrap_script$bootstrap_sha256$bootstrap_nonce_file$launch_userdata" ] \
      && [ -f "$bootstrap_script" ] && [ -f "$bootstrap_nonce_file" ] && [ -f "$launch_userdata" ] || {
      phase_set S3_PROVISION failed "Lightsail bootstrap artifact is unavailable"
      warn "The existing Lightsail instance has no complete local bootstrap artifact. Refusing to stream a replacement payload."
      return 1
    }
    [ "$(_s3_file_sha256 "$bootstrap_script")" = "$bootstrap_sha256" ] || {
      phase_set S3_PROVISION failed "Lightsail bootstrap artifact changed"
      warn "The stored Lightsail bootstrap checksum no longer matches. Refusing to stream changed root code."
      return 1
    }
    bootstrap_nonce=$(_bootstrap_nonce_read "$bootstrap_nonce_file") || {
      phase_set S3_PROVISION failed "Lightsail bootstrap identity nonce is invalid"
      warn "The stored Lightsail bootstrap identity nonce is unavailable."
      return 1
    }
    launch_userdata_bytes=$(wc -c < "$launch_userdata" | tr -d '[:space:]')
    [ "$launch_userdata_bytes" -le "$LIGHTSAIL_LAUNCH_USER_DATA_MAX_BYTES" ] && bash -n "$launch_userdata" || {
      phase_set S3_PROVISION failed "Lightsail launch user-data artifact is invalid"
      warn "The stored Lightsail launch user-data artifact is invalid."
      return 1
    }
  else
    bootstrap_script="$DIREXTALK_WORKDIR/lightsail-bootstrap.sh"
    launch_userdata="$DIREXTALK_WORKDIR/lightsail-launch.sh"
    bootstrap_nonce_file="$DIREXTALK_WORKDIR/lightsail-bootstrap.nonce"
    rm -f "$known_hosts"
    bootstrap_tmp=$(mktemp "$DIREXTALK_WORKDIR/.lightsail-bootstrap.XXXXXX") || return 1
    log "Rendering Lightsail bootstrap script (domain_mode=$domain_mode, provider=lightsail)..."
    if ! bash "$scripts_dir/render/render-userdata.sh" \
      --format shell \
      --domain "$domain" \
      --acme "${ACME_EMAIL:-}" \
      --message-server-image "$message_server_image" \
      "${agent_render_args[@]}" \
      > "$bootstrap_tmp"; then
      rm -f "$bootstrap_tmp"
      phase_set S3_PROVISION failed "Lightsail bootstrap script could not be rendered"
      return 1
    fi
    if [ ! -s "$bootstrap_tmp" ] || ! bash -n "$bootstrap_tmp"; then
      rm -f "$bootstrap_tmp"
      phase_set S3_PROVISION failed "Lightsail bootstrap script is invalid"
      warn "Rendered Lightsail bootstrap script is empty or invalid. Skipping remote key-pair creation."
      return 1
    fi
    mv -f "$bootstrap_tmp" "$bootstrap_script"
    restrict_private_file "$bootstrap_script"
    bootstrap_sha256=$(_s3_file_sha256 "$bootstrap_script") || {
      phase_set S3_PROVISION failed "Lightsail bootstrap checksum could not be computed"
      return 1
    }
    bootstrap_nonce=$(_bootstrap_nonce_ensure "$bootstrap_nonce_file") || {
      phase_set S3_PROVISION failed "Lightsail bootstrap identity nonce could not be prepared"
      return 1
    }
    if ! _render_nonce_launch_userdata "$launch_userdata" "$bootstrap_nonce"; then
      phase_set S3_PROVISION failed "Lightsail launch user-data could not be prepared"
      return 1
    fi
    launch_userdata_bytes=$(wc -c < "$launch_userdata" | tr -d '[:space:]')
    if [ "$launch_userdata_bytes" -gt "$LIGHTSAIL_LAUNCH_USER_DATA_MAX_BYTES" ]; then
      phase_set S3_PROVISION failed "Lightsail launch user-data exceeds ${LIGHTSAIL_LAUNCH_USER_DATA_MAX_BYTES}-byte provider ceiling"
      warn "Generated Lightsail launch user-data is unexpectedly oversized. Skipping remote key-pair creation."
      return 1
    fi
    res_set user_data "$launch_userdata"
    res_set lightsail_bootstrap_script "$bootstrap_script"
    res_set lightsail_bootstrap_sha256 "$bootstrap_sha256"
    res_set lightsail_bootstrap_nonce_file "$bootstrap_nonce_file"
    res_set lightsail_ssh_known_hosts "$known_hosts"
  fi
  launch_userdata_aws=$(dirextalk_native_tool_path "$launch_userdata") || return 1

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

  if [ "$instance_exists" = 1 ]; then
    log "Lightsail instance $instance_name already exists; skipping creation."
  else
    log "Launching Lightsail instance ($bundle, $blueprint, $zone)..."
    aws lightsail create-instances \
      --instance-names "$instance_name" \
      --availability-zone "$zone" \
      --blueprint-id "$blueprint" \
      --bundle-id "$bundle" \
      --key-pair-name "$name" \
      --user-data "file://$launch_userdata_aws" \
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
  if ! _bootstrap_lightsail_host "$pubip" "$keyfile" "$bootstrap_script" "$bootstrap_nonce"; then
    phase_set S3_PROVISION failed "failed to bootstrap Lightsail host over SSH"
    return 1
  fi
  if ! _resume_host_bootstrap "$pubip" "$keyfile"; then
    phase_set S3_PROVISION failed "failed to resume host bootstrap on Lightsail"
    return 1
  fi
  if agent_mounted_secret_delivery_is_configured; then
    if ! agent_mounted_secret_deliver_lightsail "$pubip" "$keyfile" "$known_hosts"; then
      phase_set S3_PROVISION failed "failed to deliver mounted Agent secret over verified SSH"
      return 1
    fi
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

_s3_file_sha256() {
  local path=${1:-} output digest
  [ -f "$path" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$path") || return 1
  else
    output=$(shasum -a 256 "$path") || return 1
  fi
  # GNU coreutils prefixes output with `\` when it escapes a Windows path.
  case "$output" in
    \\*) output=${output#?} ;;
  esac
  digest=${output%%[[:space:]]*}
  printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$digest"
}

_bootstrap_nonce_read() {
  local path=${1:-} nonce
  [ -f "$path" ] || return 1
  nonce=$(tr -d '\r\n' < "$path") || return 1
  printf '%s' "$nonce" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$nonce"
}

_bootstrap_nonce_ensure() {
  local path=${1:-} nonce tmp
  if nonce=$(_bootstrap_nonce_read "$path"); then
    printf '%s\n' "$nonce"
    return 0
  fi
  nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]') || return 1
  printf '%s' "$nonce" | grep -Eq '^[0-9a-f]{64}$' || return 1
  tmp=$(mktemp "$DIREXTALK_WORKDIR/.lightsail-bootstrap-nonce.XXXXXX") || return 1
  if ! (umask 077 && printf '%s\n' "$nonce" > "$tmp"); then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
  restrict_private_file "$path"
  printf '%s\n' "$nonce"
}

_render_nonce_launch_userdata() {
  local path=${1:-} nonce=${2:-} tmp
  printf '%s' "$nonce" | grep -Eq '^[0-9a-f]{64}$' || return 1
  tmp=$(mktemp "$DIREXTALK_WORKDIR/.lightsail-launch.XXXXXX") || return 1
  cat > "$tmp" <<EOF
#!/bin/bash
set -eu
install -d -m 0700 /var/lib/dirextalk-bootstrap
nonce_tmp=\$(mktemp /var/lib/dirextalk-bootstrap/.nonce.XXXXXX)
printf '%s\\n' '$nonce' > "\$nonce_tmp"
chmod 0600 "\$nonce_tmp"
mv -f "\$nonce_tmp" /var/lib/dirextalk-bootstrap/nonce
EOF
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
  restrict_private_file "$path"
}

_bootstrap_lightsail_host() {
  _bootstrap_verified_host Lightsail lightsail_ssh_known_hosts lightsail-bootstrap-ssh.log "$@"
}

_bootstrap_ec2_host() {
  _bootstrap_verified_host EC2 ec2_ssh_known_hosts ec2-bootstrap-ssh.log "$@"
}

_bootstrap_verified_host() {
  local provider_label=$1 known_hosts_state_key=$2 diagnostic_name=$3
  local public_ip=$4 keyfile=$5 bootstrap_script=$6 expected_nonce=$7
  local known_hosts candidate_known_hosts diagnostic_log remote_nonce attempt
  local ssh_user=${DIREXTALK_BOOTSTRAP_SSH_USER:-ubuntu}
  local attempts=${DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS:-60}
  local delay=${DIREXTALK_BOOTSTRAP_SSH_DELAY:-5}
  _is_canonical_ipv4 "$public_ip" || {
    warn "$provider_label bootstrap rejected a non-canonical public IPv4 address."
    return 1
  }
  [ -f "$keyfile" ] && [ -s "$bootstrap_script" ] || {
    warn "$provider_label bootstrap requires the recorded SSH key and rendered bootstrap script."
    return 1
  }
  bash -n "$bootstrap_script" || {
    warn "$provider_label bootstrap script is invalid."
    return 1
  }
  printf '%s' "$expected_nonce" | grep -Eq '^[0-9a-f]{64}$' || {
    warn "$provider_label bootstrap identity nonce is invalid."
    return 1
  }
  [ "$ssh_user" = ubuntu ] || {
    warn "$provider_label bootstrap requires the ubuntu SSH user."
    return 1
  }
  known_hosts=$(res_get "$known_hosts_state_key")
  known_hosts=${known_hosts:-"$DIREXTALK_WORKDIR/${provider_label,,}-known-hosts"}
  diagnostic_log="$DIREXTALK_WORKDIR/$diagnostic_name"
  : > "$diagnostic_log"
  restrict_private_file "$diagnostic_log"
  candidate_known_hosts=
  if [ -s "$known_hosts" ]; then
    remote_nonce=$(ssh -T -i "$keyfile" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=$known_hosts" \
      "$ssh_user@$public_ip" \
      'sudo -n -- /bin/cat /var/lib/dirextalk-bootstrap/nonce' 2>>"$diagnostic_log") || {
      warn "Could not authenticate the pinned $provider_label SSH host."
      return 1
    }
  else
    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
      candidate_known_hosts=$(mktemp "$DIREXTALK_WORKDIR/.verified-known-hosts.XXXXXX") || return 1
      if remote_nonce=$(ssh -T -i "$keyfile" \
          -o BatchMode=yes \
          -o IdentitiesOnly=yes \
          -o PreferredAuthentications=publickey \
          -o PasswordAuthentication=no \
          -o KbdInteractiveAuthentication=no \
          -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=accept-new \
          -o "UserKnownHostsFile=$candidate_known_hosts" \
          "$ssh_user@$public_ip" \
          'sudo -n -- /bin/cat /var/lib/dirextalk-bootstrap/nonce' 2>>"$diagnostic_log"); then
        if [ -n "$remote_nonce" ]; then
          break
        fi
      fi
      rm -f "$candidate_known_hosts"
      candidate_known_hosts=
      warn "$provider_label SSH identity nonce is not ready (attempt $attempt/$attempts); retrying in ${delay}s."
      attempt=$((attempt + 1))
      [ "$attempt" -le "$attempts" ] && sleep "$delay"
    done
    [ "$attempt" -le "$attempts" ] || {
      warn "Timed out waiting for the $provider_label SSH identity nonce. Rerun S3 to retry the frozen bootstrap."
      return 1
    }
  fi
  if [ "$remote_nonce" != "$expected_nonce" ]; then
    [ -n "$candidate_known_hosts" ] && rm -f "$candidate_known_hosts"
    warn "$provider_label SSH identity nonce did not match. Refusing to stream root bootstrap code."
    return 1
  fi
  if [ -n "$candidate_known_hosts" ]; then
    [ -s "$candidate_known_hosts" ] || {
      rm -f "$candidate_known_hosts"
      warn "$provider_label SSH host key was not recorded during identity enrollment."
      return 1
    }
    mv -f "$candidate_known_hosts" "$known_hosts"
    restrict_private_file "$known_hosts"
    res_set "$known_hosts_state_key" "$known_hosts"
  fi
  log "Streaming frozen $provider_label bootstrap through the verified stable public IP before DNS gating..."
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if ssh -T -i "$keyfile" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o PasswordAuthentication=no \
        -o KbdInteractiveAuthentication=no \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$known_hosts" \
        "$ssh_user@$public_ip" \
        "sudo -n -- /bin/bash -s -- '$public_ip'" < "$bootstrap_script" >>"$diagnostic_log" 2>&1; then
      return 0
    fi
    warn "$provider_label SSH bootstrap is not ready (attempt $attempt/$attempts); retrying in ${delay}s."
    attempt=$((attempt + 1))
    [ "$attempt" -le "$attempts" ] && sleep "$delay"
  done
  warn "Timed out bootstrapping $provider_label through $public_ip. Rerun S3 to retry the frozen bootstrap."
  return 1
}

_resume_host_bootstrap() {
  local public_ip=$1 keyfile=$2 legacy_source=${3:-} defer_start=${4:-0}
  local known_hosts attempt result identity integration_bundle remote_command provider
  local ssh_user=${DIREXTALK_BOOTSTRAP_SSH_USER:-ubuntu}
  local attempts=${DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS:-60}
  local delay=${DIREXTALK_BOOTSTRAP_SSH_DELAY:-5}
  provider=$(_resolve_cloud_provider)
  case "$provider" in
    lightsail) known_hosts=$(res_get lightsail_ssh_known_hosts) ;;
    ec2) known_hosts=$(res_get ec2_ssh_known_hosts) ;;
    *) return 1 ;;
  esac
  _is_canonical_ipv4 "$public_ip" || {
    warn "Host bootstrap resume rejected a non-canonical public IPv4 address."
    return 1
  }
  [ -n "$public_ip" ] && [ -f "$keyfile" ] || {
    warn "Host bootstrap resume requires a stable public IP and the recorded SSH key."
    return 1
  }
  if [ "$ssh_user" = ubuntu ] && [ ! -s "$known_hosts" ]; then
    warn "Host bootstrap resume requires a nonce-verified pinned SSH host key."
    return 1
  fi
  integration_bundle=$(mktemp "$DIREXTALK_WORKDIR/.updater-integration.XXXXXX.tar.gz") || return 1
  if ! tar -C "$S3_PHASE_DIR" -cf - \
      cloud-init/init-tokens.sh \
      updater/bootstrap-host.sh \
      updater/install.sh \
      updater/reconcile-host.sh \
      updater/adopt-legacy-host.sh \
      updater/legacy-d1-compose.p2p.yml \
      updater/legacy-adopt-compose.yml \
      updater/set-desired-state.sh \
      updater/release.env \
      updater/config.json \
      updater/config.legacy-compose-caddy.json \
      updater/config.legacy-systemd-caddy.json \
      updater/dirextalk-updater.service \
      | gzip -n > "$integration_bundle"; then
    rm -f "$integration_bundle"
    warn "Failed to build the updater integration bundle."
    return 1
  fi
  case "$ssh_user:$legacy_source" in
    ubuntu:)
      if [ "$defer_start" = 1 ]; then
        remote_command="stage=\$(mktemp -d /tmp/dirextalk-updater-integration.XXXXXX) && trap 'rm -rf \"\$stage\"' EXIT && tar -xzf - -C \"\$stage\" && sudo -n -- /usr/bin/env DIREXTALK_BOOTSTRAP_DEFER_START=1 /bin/bash \"\$stage/updater/reconcile-host.sh\" \"\$stage/updater\" /var/dirextalk-message-server '$public_ip'"
      else
        remote_command="stage=\$(mktemp -d /tmp/dirextalk-updater-integration.XXXXXX) && trap 'rm -rf \"\$stage\"' EXIT && tar -xzf - -C \"\$stage\" && sudo -n -- /bin/bash \"\$stage/updater/reconcile-host.sh\" \"\$stage/updater\" /var/dirextalk-message-server '$public_ip'"
      fi
      ;;
    root:/root/dirextalk/dirextalk-message-server) remote_command="stage=\$(mktemp -d /tmp/dirextalk-updater-integration.XXXXXX) && trap 'rm -rf \"\$stage\"' EXIT && tar -xzf - -C \"\$stage\" && bash \"\$stage/updater/reconcile-host.sh\" \"\$stage/updater\" /var/dirextalk-message-server '$public_ip' '$legacy_source'" ;;
    *) rm -f "$integration_bundle"; warn "Host bootstrap rejected an unsupported SSH user or legacy source."; return 1 ;;
  esac
  identity=$(printf '%s\t%s\t%s' "$UPDATER_PIN_VERSION" "$UPDATER_PIN_COMMIT" "$UPDATER_PIN_SHA256")
  log "Synchronizing the pinned updater integration and resuming bootstrap through the stable public IP before DNS gating..."
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if result=$(ssh -T -i "$keyfile" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o PasswordAuthentication=no \
        -o KbdInteractiveAuthentication=no \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$known_hosts" \
        "$ssh_user@$public_ip" \
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

_resume_private_agent_with_ecr() {
  local public_ip=$1 keyfile=$2 known_hosts=$3 registry repository_arn auth_mode pull_role_arn
  local remote_script remote_payload remote_command diagnostic_log result expected attempt
  local attempts=${DIREXTALK_ECR_AUTH_ATTEMPTS:-3}
  local delay=${DIREXTALK_ECR_AUTH_DELAY_SECONDS:-2}
  local ssh_user=${DIREXTALK_BOOTSTRAP_SSH_USER:-ubuntu}
  _is_canonical_ipv4 "$public_ip" || return 1
  [ "$ssh_user" = ubuntu ] && [ -f "$keyfile" ] && [ -s "$known_hosts" ] || return 1
  registry=$(state_get agent_registry.registry)
  repository_arn=$(state_get agent_registry.repository_arn)
  auth_mode=$(state_get agent_registry.auth_mode)
  pull_role_arn=$(state_get agent_registry.pull_role_arn)
  agent_ecr_state_is_enabled \
    "$(state_get agent_registry.source)" \
    "$(state_get agent_registry.account_id)" \
    "$(state_get agent_registry.region)" \
    "$registry" \
    "$(state_get agent_registry.repository)" \
    "$repository_arn" \
    "$auth_mode" \
    "$pull_role_arn" || return 1
  remote_script=$(cat <<'EOF'
set -euo pipefail
registry=$1
stable_ip=$2
auth_dir=/run/dirextalk-ecr-auth
cleanup_registry_auth() {
  docker --config "$auth_dir" logout "$registry" >/dev/null 2>&1 || true
  rm -rf -- "$auth_dir"
  [ ! -e "$auth_dir" ]
}
trap cleanup_registry_auth EXIT HUP INT TERM
# Lost-response resume always removes any prior auth directory before obtaining
# and consuming the newly streamed password.
rm -rf -- "$auth_dir"
install -d -m 0700 -o root -g root "$auth_dir"
docker --config "$auth_dir" login --username AWS --password-stdin "$registry" >/dev/null
DOCKER_CONFIG="$auth_dir" /bin/bash /var/dirextalk-message-server/updater/bootstrap-host.sh "$stable_ip"
cleanup_registry_auth
trap - EXIT HUP INT TERM
[ ! -e "$auth_dir" ]
# shellcheck disable=SC1091
source /var/dirextalk-message-server/updater/release.env
identity=$(/usr/local/bin/dirextalk-updater version)
version=$(printf '%s\n' "$identity" | awk -F'"' '$2 == "version" { print $4; exit }')
commit=$(printf '%s\n' "$identity" | awk -F'"' '$2 == "commit" { print $4; exit }')
sha256=$(sha256sum /usr/local/bin/dirextalk-updater | awk '{print $1}')
[ "$version" = "$UPDATER_PIN_VERSION" ] && [ "$commit" = "$UPDATER_PIN_COMMIT" ] && [ "$sha256" = "$UPDATER_PIN_SHA256" ]
printf '%s\t%s\t%s\tecr-auth-clean=true\n' "$version" "$commit" "$sha256"
EOF
)
  remote_payload=$(printf '%s' "$remote_script" | base64 | tr -d '\r\n') || return 1
  remote_command="stage=\$(mktemp /tmp/dirextalk-ecr-pull.XXXXXX) && trap 'rm -f \"\$stage\"' EXIT && printf '%s' '$remote_payload' | base64 --decode > \"\$stage\" && chmod 0700 \"\$stage\" && sudo -n -- /bin/bash \"\$stage\" '$registry' '$public_ip'"
  diagnostic_log="$DIREXTALK_WORKDIR/agent-ecr-pull-ssh.log"
  : > "$diagnostic_log"
  restrict_private_file "$diagnostic_log"
  expected=$(printf '%s\t%s\t%s\tecr-auth-clean=true' "$UPDATER_PIN_VERSION" "$UPDATER_PIN_COMMIT" "$UPDATER_PIN_SHA256")
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if result=$(set -o pipefail; agent_ecr_stream_login_password | ssh -T -i "$keyfile" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o PasswordAuthentication=no \
        -o KbdInteractiveAuthentication=no \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$known_hosts" \
        "$ssh_user@$public_ip" "$remote_command" 2>>"$diagnostic_log"); then
      if [ "$(printf '%s\n' "$result" | tail -n 1)" = "$expected" ]; then
        res_set agent_registry_auth_cleanup_verified true
        updater_release_record_state
        return $?
      fi
    fi
    warn "Private Agent ECR pull/start did not complete (attempt $attempt/$attempts); the next retry will pre-clean and obtain fresh auth."
    attempt=$((attempt + 1))
    [ "$attempt" -le "$attempts" ] && sleep "$delay"
  done
  res_set agent_registry_auth_cleanup_verified false
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
  local change_file_aws
  change_file_aws=$(dirextalk_native_tool_path "$change_file") || { rm -f "$change_file"; return 1; }
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
