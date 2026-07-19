#!/usr/bin/env bash
# destroy.sh - remove AWS resources recorded by deployment state.
#
# Source:
#   1. $DIREXTALK_WORKDIR/state.json written by orchestrate.sh; by default
#      DOMAIN=__DOMAIN__ maps to ~/.dirextalk/nodes/<service_id>/state.json.
#   2. explicit argument: bash destroy.sh /path/to/state.json
#
# Order: terminate instance -> release EIP -> delete security group -> delete key pair
# -> remove the corresponding local service directory.
# Each cloud step is tolerant of already-removed resources.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/paths.sh"
# shellcheck disable=SC1090
source "$HERE/lib/git-bash.sh"
# shellcheck disable=SC1090
source "$HERE/lib/aws.sh"
# shellcheck disable=SC1090
source "$HERE/lib/operation_report.sh"
# shellcheck disable=SC1090
source "$HERE/lib/local-paths.sh"
# shellcheck disable=SC1090
source "$HERE/lib/agent-secret-delivery.sh"
# shellcheck disable=SC1090
source "$HERE/lib/agent-ecr-pull.sh"
source "$HERE/lib/agent-worker-control.sh"
# shellcheck disable=SC1090
source "$HERE/lib/connect-agent-adapters.sh"
# shellcheck disable=SC1090
source "$HERE/lib/mcp-client-adapters.sh"
DIREXTALK_WORKDIR=$(dirextalk_default_workdir)
dirextalk_require_git_bash_on_windows || exit 1

log() { echo -e "\033[33m[destroy]\033[0m $*"; }

destroy_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

destroy_evidence_set() {
  local key=$1 status=$2 detail=${3:-}
  if ! json_mutate "$SRC" destroy-evidence "$key" "$status" "$detail" "$(destroy_now)"; then
    log "  (failed to record destroy evidence for $key)"
  fi
}

route53_a_record_present() {
  local zone_id=$1 domain=$2 public_ip=$3 rrsets present
  rrsets=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null) || return 2
  present=$(printf '%s\n' "$rrsets" | json_stdin_route53_a_present "$domain." "$public_ip" 2>/dev/null) || return 2
  [ "$present" = "true" ]
}

verify_route53_a_record_deleted() {
  local zone_id=$1 domain=$2 public_ip=$3 rc
  if [ -z "$zone_id" ] || [ -z "$domain" ] || [ -z "$public_ip" ]; then
    destroy_evidence_set route53_a_record skipped "missing hosted zone, domain, or public IP"
    return 0
  fi
  route53_a_record_present "$zone_id" "$domain" "$public_ip"
  rc=$?
  case "$rc" in
    0) destroy_evidence_set route53_a_record still_present "$domain still resolves to recorded IP $public_ip in hosted zone $zone_id" ;;
    1) destroy_evidence_set route53_a_record deleted "$domain A $public_ip is absent from hosted zone $zone_id" ;;
    *) destroy_evidence_set route53_a_record unknown "could not verify hosted zone $zone_id record state" ;;
  esac
}

verify_route53_hosted_zone_deleted() {
  local zone_id=$1 out
  if [ -z "$zone_id" ]; then
    destroy_evidence_set route53_hosted_zone skipped "missing hosted zone id"
    return 0
  fi
  if out=$(aws route53 get-hosted-zone --id "$zone_id" --output json 2>/dev/null); then
    if [ -n "$out" ]; then
      destroy_evidence_set route53_hosted_zone still_present "hosted zone $zone_id still exists"
    else
      destroy_evidence_set route53_hosted_zone unknown "empty get-hosted-zone response for $zone_id"
    fi
  else
    destroy_evidence_set route53_hosted_zone deleted "hosted zone $zone_id is absent"
  fi
}

verify_ec2_instance_terminated() {
  local instance_id=$1 state
  if [ -z "$instance_id" ]; then
    destroy_evidence_set ec2_instance skipped "missing instance id"
    return 0
  fi
  if state=$(aws ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null); then
    case "$state" in
      terminated) destroy_evidence_set ec2_instance terminated "instance $instance_id state is terminated" ;;
      ""|"None") destroy_evidence_set ec2_instance unknown "instance $instance_id returned no state" ;;
      *) destroy_evidence_set ec2_instance "$state" "instance $instance_id state is $state" ;;
    esac
  else
    destroy_evidence_set ec2_instance not_found "instance $instance_id was not returned by EC2"
  fi
}

verify_ebs_root_volume_deleted() {
  local volume_id=$1 state
  if [ -z "$volume_id" ]; then
    destroy_evidence_set ebs_root_volume skipped "missing root volume id"
    return 0
  fi
  if state=$(aws ec2 describe-volumes --volume-ids "$volume_id" \
      --query 'Volumes[0].State' --output text 2>/dev/null); then
    case "$state" in
      ""|"None") destroy_evidence_set ebs_root_volume deleted "root volume $volume_id is absent" ;;
      deleted) destroy_evidence_set ebs_root_volume deleted "root volume $volume_id state is deleted" ;;
      *) destroy_evidence_set ebs_root_volume "$state" "root volume $volume_id state is $state" ;;
    esac
  else
    destroy_evidence_set ebs_root_volume deleted "root volume $volume_id is absent"
  fi
}

verify_elastic_ip_released() {
  local allocation_id=$1 out
  if [ -z "$allocation_id" ]; then
    destroy_evidence_set elastic_ip skipped "missing allocation id"
    return 0
  fi
  if out=$(aws ec2 describe-addresses --allocation-ids "$allocation_id" \
      --query 'Addresses[0].AllocationId' --output text 2>/dev/null); then
    case "$out" in
      ""|"None") destroy_evidence_set elastic_ip released "allocation $allocation_id is absent" ;;
      *) destroy_evidence_set elastic_ip still_allocated "allocation $allocation_id still exists" ;;
    esac
  else
    destroy_evidence_set elastic_ip released "allocation $allocation_id is absent"
  fi
}

verify_security_group_deleted() {
  local group_id=$1 out
  if [ -z "$group_id" ]; then
    destroy_evidence_set security_group skipped "missing security group id"
    return 0
  fi
  if out=$(aws ec2 describe-security-groups --group-ids "$group_id" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null); then
    case "$out" in
      ""|"None") destroy_evidence_set security_group deleted "security group $group_id is absent" ;;
      *) destroy_evidence_set security_group still_present "security group $group_id still exists" ;;
    esac
  else
    destroy_evidence_set security_group deleted "security group $group_id is absent"
  fi
}

verify_key_pair_deleted() {
  local key_name=$1 out
  if [ -z "$key_name" ]; then
    destroy_evidence_set key_pair skipped "missing key pair name"
    return 0
  fi
  if out=$(aws ec2 describe-key-pairs --key-names "$key_name" \
      --query 'KeyPairs[0].KeyName' --output text 2>/dev/null); then
    case "$out" in
      ""|"None") destroy_evidence_set key_pair deleted "key pair $key_name is absent" ;;
      *) destroy_evidence_set key_pair still_present "key pair $key_name still exists" ;;
    esac
  else
    destroy_evidence_set key_pair deleted "key pair $key_name is absent"
  fi
}

verify_lightsail_instance_deleted() {
  local instance_name=$1 out
  if [ -z "$instance_name" ]; then
    destroy_evidence_set lightsail_instance skipped "missing Lightsail instance name"
    return 0
  fi
  if out=$(aws lightsail get-instance --instance-name "$instance_name" --query 'instance.name' --output text 2>/dev/null); then
    case "$out" in
      ""|"None") destroy_evidence_set lightsail_instance deleted "Lightsail instance $instance_name is absent" ;;
      *) destroy_evidence_set lightsail_instance still_present "Lightsail instance $instance_name still exists" ;;
    esac
  else
    destroy_evidence_set lightsail_instance deleted "Lightsail instance $instance_name is absent"
  fi
}

verify_lightsail_static_ip_released() {
  local static_ip_name=$1 out
  if [ -z "$static_ip_name" ]; then
    destroy_evidence_set lightsail_static_ip skipped "missing Lightsail static IP name"
    return 0
  fi
  if out=$(aws lightsail get-static-ip --static-ip-name "$static_ip_name" --query 'staticIp.name' --output text 2>/dev/null); then
    case "$out" in
      ""|"None") destroy_evidence_set lightsail_static_ip released "Lightsail static IP $static_ip_name is absent" ;;
      *) destroy_evidence_set lightsail_static_ip still_allocated "Lightsail static IP $static_ip_name still exists" ;;
    esac
  else
    destroy_evidence_set lightsail_static_ip released "Lightsail static IP $static_ip_name is absent"
  fi
}

verify_lightsail_key_pair_deleted() {
  local key_name=$1 out
  if [ -z "$key_name" ]; then
    destroy_evidence_set key_pair skipped "missing key pair name"
    return 0
  fi
  if out=$(aws lightsail get-key-pair --key-pair-name "$key_name" --query 'keyPair.name' --output text 2>/dev/null); then
    case "$out" in
      ""|"None") destroy_evidence_set key_pair deleted "Lightsail key pair $key_name is absent" ;;
      *) destroy_evidence_set key_pair still_present "Lightsail key pair $key_name still exists" ;;
    esac
  else
    destroy_evidence_set key_pair deleted "Lightsail key pair $key_name is absent"
  fi
}

# Resolve source and load INSTANCE_ID/EIP_ID/SG_ID/KEY_NAME/KEY_FILE/REGION.
SRC=${1:-}
if [ -z "$SRC" ]; then
  if   [ -f "$DIREXTALK_WORKDIR/state.json" ]; then SRC="$DIREXTALK_WORKDIR/state.json"
  else echo "state.json not found; set DOMAIN=<service domain> or DIREXTALK_WORKDIR=<service dir> to destroy a specific deployment."; exit 1
  fi
fi
SRC=$(dirextalk_execution_path "$SRC")
[ -f "$SRC" ] || { echo "$SRC not found."; exit 1; }
DIREXTALK_ROOT=$(cd "$(dirextalk_home)" 2>/dev/null && pwd -P || dirextalk_home)

REGION=$(json_get "$SRC" region)
CLOUD_PROVIDER=$(json_get "$SRC" cloud_provider)
CLOUD_PROVIDER=${CLOUD_PROVIDER:-ec2}
INSTANCE_ID=$(json_get "$SRC" resources.instance_id)
LIGHTSAIL_INSTANCE_NAME=$(json_get "$SRC" resources.lightsail_instance_name)
LIGHTSAIL_STATIC_IP_NAME=$(json_get "$SRC" resources.lightsail_static_ip_name)
STATIC_IP_NAME=$(json_get "$SRC" resources.static_ip_name)
ROOT_VOLUME_ID=$(json_get "$SRC" resources.root_volume_id)
EIP_ID=$(json_get "$SRC" resources.eip_id)
SG_ID=$(json_get "$SRC" resources.sg_id)
KEY_NAME=$(json_get "$SRC" resources.key_name)
KEY_FILE=$(json_get "$SRC" resources.key_file)
LIGHTSAIL_SSH_KNOWN_HOSTS=$(json_get "$SRC" resources.lightsail_ssh_known_hosts)
EC2_SSH_KNOWN_HOSTS=$(json_get "$SRC" resources.ec2_ssh_known_hosts)
AGENT_RUNTIME_ENABLED=$(json_get "$SRC" agent_release.enabled)
AGENT_REGISTRY_SOURCE=$(json_get "$SRC" agent_registry.source)
AGENT_REGISTRY_HOST=$(json_get "$SRC" agent_registry.registry)
DOMAIN_MODE=$(json_get "$SRC" domain_mode)
DOMAIN=$(json_get "$SRC" domain)
AS_URL=$(json_get "$SRC" as_url)
PUBLIC_IP=$(json_get "$SRC" resources.public_ip)
ROUTE53_ZONE_ID=$(json_get "$SRC" resources.route53_zone_id)
ROUTE53_ZONE_NAME=$(json_get "$SRC" resources.route53_zone_name)
ROUTE53_ZONE_CREATED_BY_DEPLOYER=$(json_get "$SRC" resources.route53_zone_created_by_deployer)
CONNECT_CONFIG=$(json_get "$SRC" connect_config)
CONNECT_BINARY=$(json_get "$SRC" connect_binary)
CONNECT_RUNTIME_DIR=$(json_get "$SRC" connect_runtime_dir)
AGENT_SERVICE_DIR=$(json_get "$SRC" agent_service_dir)
AGENT_SERVICE_ID=$(json_get "$SRC" agent_service_id)
MCP_HOST_REGISTRY_OWNER=$(json_get "$SRC" mcp_host_registry_owner)
MCP_HOST_REGISTRY_SERVER=$(json_get "$SRC" mcp_host_registry_server)
MCP_HOST_TOKEN_ENV_KEY=$(json_get "$SRC" mcp_host_token_env_key)
MCP_OPENCLAW_PROFILE=$(json_get "$SRC" mcp_openclaw_profile)
MCP_OPENCLAW_CONFIG_PATH=$(json_get "$SRC" mcp_openclaw_config_path)
MCP_HERMES_HOME=$(json_get "$SRC" mcp_hermes_home)
MCP_HERMES_PROFILE=$(json_get "$SRC" mcp_hermes_profile)
MCP_HERMES_PROFILE_OWNED=$(json_get "$SRC" mcp_hermes_profile_owned)

export NO_PROXY="*"; export no_proxy="*"
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy 2>/dev/null || true
[ -n "${REGION:-${AWS_DEFAULT_REGION:-}}" ] || {
  echo "Region is missing. Add .region to state.json or set AWS_DEFAULT_REGION, then retry."
  exit 1
}
export AWS_DEFAULT_REGION=${REGION:-${AWS_DEFAULT_REGION:-}}

log "source = $SRC (region=$AWS_DEFAULT_REGION)"

AWS_IDENTITY_ARN=$(aws_identity_arn)
if [ -z "$AWS_IDENTITY_ARN" ] || [ "$AWS_IDENTITY_ARN" = "None" ]; then
  echo "AWS credentials are required before destroy can remove cloud resources or local state."
  exit 1
fi

# destroy.sh deliberately does not load the orchestrator state library. Adapt
# its already-open source file to the same narrow state seam used by the
# retained producer, so cleanup writes remain atomic and local to this state.
state_get() { json_get "$SRC" "$1"; }
state_set_raw() { json_mutate "$SRC" set-json "$1" "$2"; }
state_set_object() {
  local path=$1 object_json
  shift
  object_json=$(json_build object "$@") || return 1
  state_set_raw "$path" "$object_json"
}
res_get() { json_get "$SRC" "resources.$1"; }

# The retained producer is independent of the parent host. Never terminate the
# host while active Worker endpoint consumers would make cleanup unsafe.
agent_worker_control_destroy || {
  echo "worker-control PrivateLink cleanup is incomplete or has active Workers; parent destroy is blocked."
  exit 1
}

find_route53_zone() {
  local domain=$1 best_id="" best_name="" best_len=0 id name clean len
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
  done < <(aws route53 list-hosted-zones --output json 2>/dev/null | json_stdin_tsv HostedZones Id Name)
  [ -n "$best_id" ] && printf '%s\t%s\n' "$best_id" "$best_name"
}

delete_route53_record() {
  local domain=$1 public_ip=$2 zone zone_id zone_name change_file change_json change_id
  [ -n "$domain" ] && [ -n "$public_ip" ] || return 0
  zone_id=${ROUTE53_ZONE_ID:-}
  zone_name=${ROUTE53_ZONE_NAME:-}
  if [ -z "$zone_id" ]; then
    zone=$(find_route53_zone "$domain")
    zone_id=$(printf '%s' "$zone" | cut -f1)
    zone_name=$(printf '%s' "$zone" | cut -f2)
  fi
  if [ -z "$zone_id" ]; then
    log "Route53 hosted zone not found for $domain; leaving DNS record untouched"
    destroy_evidence_set route53_a_record skipped "hosted zone not found for $domain"
    return 0
  fi

  log "deleting Route53 A record $domain -> $public_ip (zone=$zone_name) ..."
  change_file=$(mktemp)
  cat > "$change_file" <<EOF
{
  "Comment": "Dirextalk destroy",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$domain.",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{ "Value": "$public_ip" }]
      }
    }
  ]
}
EOF
  local change_file_aws
  change_file_aws=$(dirextalk_native_tool_path "$change_file") || { rm -f "$change_file"; return 1; }
  change_json=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "file://$change_file_aws" \
    --output json 2>/dev/null) \
    || log "  (Route53 A record may already be absent or changed; check DNS manually)"
  rm -f "$change_file"
  if [ -n "${change_json:-}" ]; then
    change_id=$(printf '%s\n' "$change_json" | json_stdin_get ChangeInfo.Id 2>/dev/null)
    [ -n "$change_id" ] && aws route53 wait resource-record-sets-changed --id "$change_id" 2>/dev/null || true
  fi
  verify_route53_a_record_deleted "$zone_id" "$domain" "$public_ip"
}

delete_route53_hosted_zone_if_owned() {
  local zone_id=${ROUTE53_ZONE_ID:-}
  [ -n "$zone_id" ] || return 0
  if [ "${ROUTE53_ZONE_CREATED_BY_DEPLOYER:-}" != "true" ]; then
    log "Route53 hosted zone $zone_id was not created by this deployer run; leaving it in place"
    destroy_evidence_set route53_hosted_zone retained "hosted zone $zone_id was not created by this deployer run"
    return 0
  fi
  log "deleting deployer-created Route53 hosted zone $zone_id ..."
  aws route53 delete-hosted-zone --id "$zone_id" >/dev/null 2>&1 \
    || log "  (hosted zone was not deleted; it may contain records, be already absent, or require manual review)"
  verify_route53_hosted_zone_deleted "$zone_id"
}

normalize_local_path() {
  dirextalk_normalize_local_path "$1"
}

local_dirname() {
  local path
  path=$(normalize_local_path "$1")
  case "$path" in
    */*) printf '%s\n' "${path%/*}" ;;
    *) printf '.\n' ;;
  esac
}

paths_equal() {
  dirextalk_paths_equal "$1" "$2"
}

current_service_dir() {
  local recorded=$1 asurl=$2 domain=$3 config=${4:-}
  if [ -n "$recorded" ]; then
    printf '%s\n' "$recorded"
    return 0
  fi
  if [ -n "$asurl" ] || [ -n "$domain" ]; then
    dirextalk_service_dir "${asurl:-$domain}"
    return 0
  fi
  if [ -n "$config" ]; then
    local_dirname "$(local_dirname "$config")"
  fi
}

connect_stop_binary() {
  local binary=$1 runtime_dir=$2 candidate
  if [ -n "$runtime_dir" ]; then
    candidate="$runtime_dir/bin/dirextalk-connect"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$runtime_dir/bin/dirextalk-connect.exe"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  if [ -n "$binary" ]; then
    printf '%s\n' "$binary"
    return 0
  fi
  printf 'dirextalk-connect\n'
}

connect_target_work_dir() {
  local config=$1 runtime_dir=$2 service_dir=$3
  if [ -n "$config" ]; then
    local_dirname "$config"
    return 0
  fi
  if [ -n "$runtime_dir" ]; then
    normalize_local_path "$runtime_dir"
    return 0
  fi
  if [ -n "$service_dir" ]; then
    normalize_local_path "$service_dir/dirextalk-connect"
  fi
}

connect_service_name() {
  local service_id=$1 service_dir=$2 asurl=$3 domain=$4
  if [ -n "$service_id" ]; then
    printf '%s\n' "$service_id"
    return 0
  fi
  if [ -n "$service_dir" ]; then
    basename "$service_dir"
    return 0
  fi
  if [ -n "$asurl" ] || [ -n "$domain" ]; then
    dirextalk_service_id "${asurl:-$domain}"
    return 0
  fi
  printf 'dirextalk-connect\n'
}

connect_status_work_dir() {
  local binary=$1 service_name=$2 out
  out=$("$binary" daemon status --service-name "$service_name" 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*WorkDir:[[:space:]]*//p' | head -n 1
}

stop_current_connect_daemon() {
  local config=$1 binary=$2 runtime_dir=$3 service_dir=$4 service_name=$5 target_work_dir running_work_dir stop_binary
  target_work_dir=$(connect_target_work_dir "$config" "$runtime_dir" "$service_dir")
  if [ -z "$target_work_dir" ]; then
    log "dirextalk-connect service directory not recorded; skipping local daemon stop"
    return 0
  fi

  stop_binary=$(connect_stop_binary "$binary" "$runtime_dir")
  case "$stop_binary" in
    */*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *)
      if ! command -v "$stop_binary" >/dev/null 2>&1; then
        log "dirextalk-connect binary not found on PATH; skipping local daemon stop"
        return 0
      fi
      ;;
  esac

  running_work_dir=$(connect_status_work_dir "$stop_binary" "$service_name")
  if [ -z "$running_work_dir" ]; then
    log "dirextalk-connect daemon status has no WorkDir; skipping local daemon stop"
    return 0
  fi

  if ! paths_equal "$target_work_dir" "$running_work_dir"; then
    log "dirextalk-connect daemon belongs to another service; leaving daemon running"
    return 0
  fi

  log "stopping dirextalk-connect daemon for current service ..."
  if "$stop_binary" daemon stop --service-name "$service_name" >/dev/null 2>&1; then
    log "dirextalk-connect daemon stopped"
  else
    log "dirextalk-connect daemon stop failed or service was not installed; continuing destroy"
  fi
  log "uninstalling dirextalk-connect daemon for current service ..."
  if "$stop_binary" daemon uninstall --service-name "$service_name" >/dev/null 2>&1; then
    log "dirextalk-connect daemon uninstalled"
  else
    log "dirextalk-connect daemon uninstall failed or service was not installed; continuing destroy"
  fi
}

mark_remote_deprovisioned() {
  local key_file=$1 public_ip=$2 known_hosts=${3:-} helper_payload remote remote_q
  [ -n "$key_file" ] && [ -f "$key_file" ] && [ -n "$public_ip" ] || return 0
  helper_payload=$(base64 < "$HERE/updater/set-desired-state.sh" | tr -d '\r\n')
  remote=$(cat <<'EOF'
set -eu
desired_helper_tmp=$(mktemp /tmp/dirextalk-updater-desired-state.XXXXXX)
cleanup_desired_helper() { rm -f "$desired_helper_tmp"; }
trap cleanup_desired_helper EXIT
printf '%s' '__DIREXTALK_DESIRED_HELPER__' | base64 --decode > "$desired_helper_tmp"
sudo install -d -m 0755 /var/dirextalk-message-server/updater
sudo install -m 0755 "$desired_helper_tmp" /var/dirextalk-message-server/updater/set-desired-state.sh
rm -f "$desired_helper_tmp"
trap - EXIT
sudo /var/dirextalk-message-server/updater/set-desired-state.sh deprovisioned
EOF
)
  remote=${remote/__DIREXTALK_DESIRED_HELPER__/$helper_payload}
  printf -v remote_q '%q' "$remote"
  local -a host_key_args=(-o StrictHostKeyChecking=accept-new)
  if [ -s "$known_hosts" ]; then
    host_key_args=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
  elif [ "$AGENT_RUNTIME_ENABLED" = true ]; then
    log "pinned SSH host data is unavailable; skipping remote root desired-state mutation"
    return 0
  fi
  if ssh -T -i "$key_file" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      "${host_key_args[@]}" -o ConnectTimeout=5 \
      ubuntu@"$public_ip" "sudo bash -lc $remote_q" >/dev/null 2>&1; then
    log "remote updater desired-state reconciliation completed before termination"
  else
    log "remote updater was unreachable or rejected deprovisioned state; cloud termination will continue"
  fi
}

cleanup_remote_agent_mounted_secrets() {
  local cleanup_rc known_hosts
  if [ "$AGENT_RUNTIME_ENABLED" != true ]; then
    destroy_evidence_set agent_mounted_secrets skipped "optional Agent runtime is not enabled"
    return 0
  fi
  case "$CLOUD_PROVIDER" in
    lightsail) known_hosts=$LIGHTSAIL_SSH_KNOWN_HOSTS ;;
    ec2) known_hosts=$EC2_SSH_KNOWN_HOSTS ;;
    *) known_hosts= ;;
  esac
  agent_mounted_secret_cleanup_pinned "$PUBLIC_IP" "$KEY_FILE" "$known_hosts"
  cleanup_rc=$?
  case "$cleanup_rc" in
    0)
      log "cleared private mounted Agent secrets through the pinned SSH host"
      destroy_evidence_set agent_mounted_secrets cleared "private mounted Agent secrets cleared before cloud deletion"
      ;;
    2)
      log "pinned SSH host data is unavailable; skipping remote mounted-secret cleanup before cloud deletion"
      destroy_evidence_set agent_mounted_secrets skipped "pinned SSH host data unavailable; instance deletion remains the final wipe"
      ;;
    *)
      log "private mounted Agent secret cleanup failed; cloud deletion will still wipe the volume"
      destroy_evidence_set agent_mounted_secrets cleanup_failed "remote cleanup failed; instance deletion remains the final wipe"
      ;;
  esac
}

cleanup_remote_agent_registry_auth() {
  local cleanup_rc known_hosts
  if [ "$AGENT_REGISTRY_SOURCE" != private_ecr ]; then
    destroy_evidence_set agent_registry_auth skipped "private Agent registry auth was not configured"
    return 0
  fi
  case "$CLOUD_PROVIDER" in
    lightsail) known_hosts=$LIGHTSAIL_SSH_KNOWN_HOSTS ;;
    ec2) known_hosts=$EC2_SSH_KNOWN_HOSTS ;;
    *) known_hosts= ;;
  esac
  agent_ecr_auth_cleanup_pinned "$PUBLIC_IP" "$KEY_FILE" "$known_hosts" "$AGENT_REGISTRY_HOST"
  cleanup_rc=$?
  case "$cleanup_rc" in
    0) destroy_evidence_set agent_registry_auth cleared "temporary Docker registry auth directory proved absent before cloud deletion" ;;
    2) destroy_evidence_set agent_registry_auth skipped "pinned SSH host data unavailable; instance deletion remains the final wipe" ;;
    *) destroy_evidence_set agent_registry_auth cleanup_failed "registry auth cleanup failed; instance deletion remains the final wipe" ;;
  esac
}

cleanup_local_service_dir() {
  local service_dir=$1 root=$2 nodes_root src_real nodes_real src_norm nodes_norm name

  if [ "${DIREXTALK_KEEP_WORKDIR:-0}" = "1" ]; then
    log "keeping local service dir because DIREXTALK_KEEP_WORKDIR=1: $service_dir"
    return 0
  fi

  [ -n "$service_dir" ] && [ -d "$service_dir" ] || return 0
  [ -n "$root" ] || return 0

  nodes_root="$root/nodes"
  [ -d "$nodes_root" ] || {
    log "local service root not found; leaving $service_dir untouched"
    return 0
  }
  src_real=$(cd "$service_dir" 2>/dev/null && pwd -P) || return 0
  nodes_real=$(cd "$nodes_root" 2>/dev/null && pwd -P) || return 0
  src_norm=$(normalize_local_path "$src_real")
  nodes_norm=$(normalize_local_path "$nodes_real")
  case "$src_norm" in
    "$nodes_norm"/*) ;;
    *)
      log "refusing to remove local service dir outside $nodes_norm: $service_dir"
      return 0
      ;;
  esac

  name=$(basename "$src_norm")
  case "$name" in
    ""|"."|".."|"nodes"|"dirextalk-connect")
      log "refusing to remove unexpected local service dir: $service_dir"
      return 0
      ;;
  esac

  log "removing local service dir $src_real ..."
  rm -rf -- "$src_real"
}

cleanup_host_mcp_registry() {
  local owner=${MCP_HOST_REGISTRY_OWNER:-} server=${MCP_HOST_REGISTRY_SERVER:-} token_env=${MCP_HOST_TOKEN_ENV_KEY:-}
  local command
  case "$owner" in
    openclaw)
      if _openclaw_mcp_remove "$server" "$token_env" "${MCP_OPENCLAW_PROFILE:-}" "${MCP_OPENCLAW_CONFIG_PATH:-}"; then
        log "removed managed OpenClaw MCP server entry"
        destroy_evidence_set host_mcp_registry removed "managed OpenClaw MCP entry removed"
      else
        log "managed OpenClaw MCP entry could not be removed; inspect the selected OpenClaw config"
        destroy_evidence_set host_mcp_registry cleanup_failed "managed OpenClaw MCP entry needs review"
      fi
      ;;
    hermes)
      if [ "${MCP_HERMES_PROFILE_OWNED:-false}" = "true" ]; then
        command=$(_hermes_command 2>/dev/null || true)
        if [ -n "$command" ] && [ -n "${MCP_HERMES_HOME:-}" ] && [ -n "${MCP_HERMES_PROFILE:-}" ] &&
          HERMES_HOME="$MCP_HERMES_HOME" "$command" profile delete -y "$MCP_HERMES_PROFILE" >/dev/null 2>&1; then
          log "removed managed Hermes service profile"
          destroy_evidence_set host_mcp_registry removed "managed Hermes service profile removed"
        else
          log "managed Hermes service profile could not be removed; inspect the recorded native Hermes home"
          destroy_evidence_set host_mcp_registry cleanup_failed "managed Hermes service profile needs review"
        fi
      elif _hermes_mcp_remove "$MCP_HERMES_HOME" "$MCP_HERMES_PROFILE" "$server" "$token_env"; then
        log "removed managed Hermes MCP server entry"
        destroy_evidence_set host_mcp_registry removed "managed Hermes MCP entry removed"
      else
        log "managed Hermes MCP entry could not be removed; inspect the selected Hermes profile"
        destroy_evidence_set host_mcp_registry cleanup_failed "managed Hermes MCP entry needs review"
      fi
      ;;
    *)
      ;;
  esac
}

# 0. Remove DNS record if ops created it through Route53 mode.
CURRENT_SERVICE_DIR=$(current_service_dir "$AGENT_SERVICE_DIR" "$AS_URL" "$DOMAIN" "$CONNECT_CONFIG")
CURRENT_SERVICE_NAME=$(connect_service_name "$AGENT_SERVICE_ID" "$CURRENT_SERVICE_DIR" "$AS_URL" "$DOMAIN")
cleanup_remote_agent_registry_auth
cleanup_remote_agent_mounted_secrets
case "$CLOUD_PROVIDER" in
  lightsail) HOST_SSH_KNOWN_HOSTS=$LIGHTSAIL_SSH_KNOWN_HOSTS ;;
  ec2) HOST_SSH_KNOWN_HOSTS=$EC2_SSH_KNOWN_HOSTS ;;
  *) HOST_SSH_KNOWN_HOSTS= ;;
esac
mark_remote_deprovisioned "$KEY_FILE" "$PUBLIC_IP" "$HOST_SSH_KNOWN_HOSTS"
stop_current_connect_daemon "$CONNECT_CONFIG" "$CONNECT_BINARY" "$CONNECT_RUNTIME_DIR" "$CURRENT_SERVICE_DIR" "$CURRENT_SERVICE_NAME"

if [ "${DOMAIN_MODE:-}" = "route53" ]; then
  delete_route53_record "$DOMAIN" "$PUBLIC_IP"
  delete_route53_hosted_zone_if_owned
fi

if [ "$CLOUD_PROVIDER" = "lightsail" ]; then
  LIGHTSAIL_INSTANCE_NAME=${LIGHTSAIL_INSTANCE_NAME:-$INSTANCE_ID}
  LIGHTSAIL_STATIC_IP_NAME=${LIGHTSAIL_STATIC_IP_NAME:-$STATIC_IP_NAME}

  if [ -n "${LIGHTSAIL_STATIC_IP_NAME:-}" ]; then
    log "detaching and releasing Lightsail static IP $LIGHTSAIL_STATIC_IP_NAME ..."
    aws lightsail detach-static-ip --static-ip-name "$LIGHTSAIL_STATIC_IP_NAME" >/dev/null 2>&1 || true
    aws lightsail release-static-ip --static-ip-name "$LIGHTSAIL_STATIC_IP_NAME" >/dev/null 2>&1 || log "  (Lightsail static IP may already be released)"
    verify_lightsail_static_ip_released "$LIGHTSAIL_STATIC_IP_NAME"
  else
    verify_lightsail_static_ip_released ""
  fi

  if [ -n "${LIGHTSAIL_INSTANCE_NAME:-}" ]; then
    log "deleting Lightsail instance $LIGHTSAIL_INSTANCE_NAME ..."
    aws lightsail delete-instance --instance-name "$LIGHTSAIL_INSTANCE_NAME" >/dev/null 2>&1 || log "  (Lightsail instance may already be gone)"
    verify_lightsail_instance_deleted "$LIGHTSAIL_INSTANCE_NAME"
  else
    verify_lightsail_instance_deleted ""
  fi

  if [ -n "${KEY_NAME:-}" ]; then
    log "deleting Lightsail key pair $KEY_NAME ..."
    aws lightsail delete-key-pair --key-pair-name "$KEY_NAME" 2>/dev/null || true
    [ -n "${KEY_FILE:-}" ] && [ -f "$KEY_FILE" ] && rm -f "$KEY_FILE"
    verify_lightsail_key_pair_deleted "$KEY_NAME"
  else
    verify_lightsail_key_pair_deleted ""
  fi
else
  # 1. Terminate instance.
  if [ -n "${INSTANCE_ID:-}" ]; then
    log "terminating instance $INSTANCE_ID ..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || log "  (instance may already be gone)"
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || true
    verify_ec2_instance_terminated "$INSTANCE_ID"
  else
    verify_ec2_instance_terminated ""
  fi
  verify_ebs_root_volume_deleted "${ROOT_VOLUME_ID:-}"

  # 2. Release Elastic IP.
  if [ -n "${EIP_ID:-}" ]; then
    log "releasing Elastic IP $EIP_ID ..."
    aws ec2 release-address --allocation-id "$EIP_ID" 2>/dev/null || log "  (EIP may already be released)"
    verify_elastic_ip_released "$EIP_ID"
  else
    verify_elastic_ip_released ""
  fi

  # 3. Delete security group after instance/network interfaces detach.
  if [ -n "${SG_ID:-}" ]; then
    log "deleting security group $SG_ID ..."
    for i in 1 2 3 4 5; do
      if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then break; fi
      sleep 6
      [ "$i" = 5 ] && log "  (security group delete failed; an ENI may still be attached, delete it manually later)"
    done
    verify_security_group_deleted "$SG_ID"
  else
    verify_security_group_deleted ""
  fi

  # 4. Delete key pair and local private key.
  if [ -n "${KEY_NAME:-}" ]; then
    log "deleting key pair $KEY_NAME ..."
    aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
    [ -n "${KEY_FILE:-}" ] && [ -f "$KEY_FILE" ] && rm -f "$KEY_FILE"
    verify_key_pair_deleted "$KEY_NAME"
  else
    verify_key_pair_deleted ""
  fi
fi

cleanup_host_mcp_registry
log "Done. Processed resources recorded in $SRC."
log "User-managed DNS and domain purchases are outside automatic destroy scope; handle them manually if needed."
if REPORT_PATH=$(operation_report_write destroy destroy_processed "$SRC" 2>/dev/null); then
  log "operation report written: $REPORT_PATH"
else
  log "operation report was not written; keep destroy logs for audit"
fi
cleanup_local_service_dir "$CURRENT_SERVICE_DIR" "$DIREXTALK_ROOT"
