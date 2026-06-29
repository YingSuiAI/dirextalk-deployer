#!/usr/bin/env bash
# destroy.sh - remove AWS resources recorded by deployment state.
#
# Source:
#   1. $P2P_WORKDIR/state.json written by orchestrate.sh; by default
#      DOMAIN=__DOMAIN__ maps to ~/.direxio/nodes/<service_id>/state.json.
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
source "$HERE/lib/aws.sh"
# shellcheck disable=SC1090
source "$HERE/lib/operation_report.sh"
P2P_WORKDIR=$(direxio_default_workdir)

log() { echo -e "\033[33m[destroy]\033[0m $*"; }

destroy_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

destroy_evidence_set() {
  local key=$1 status=$2 detail=${3:-} tmp
  tmp="$SRC.tmp.destroy.$$"
  if jq --arg key "$key" \
        --arg status "$status" \
        --arg detail "$detail" \
        --arg checked_at "$(destroy_now)" \
        '.destroy_evidence[$key] = {
          status: $status,
          detail: $detail,
          checked_at: $checked_at
        }' "$SRC" > "$tmp"; then
    mv "$tmp" "$SRC"
  else
    rm -f "$tmp"
    log "  (failed to record destroy evidence for $key)"
  fi
}

route53_a_record_present() {
  local zone_id=$1 domain=$2 public_ip=$3 rrsets present
  rrsets=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null) || return 2
  present=$(printf '%s\n' "$rrsets" | jq -r --arg name "$domain." --arg ip "$public_ip" '
    any(.ResourceRecordSets[]?;
      .Name == $name
      and .Type == "A"
      and any(.ResourceRecords[]?; .Value == $ip)
    )
  ' 2>/dev/null) || return 2
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

# Resolve source and load INSTANCE_ID/EIP_ID/SG_ID/KEY_NAME/KEY_FILE/REGION.
SRC=${1:-}
if [ -z "$SRC" ]; then
  if   [ -f "$P2P_WORKDIR/state.json" ]; then SRC="$P2P_WORKDIR/state.json"
  else echo "state.json not found; set DOMAIN=<service domain> or P2P_WORKDIR=<service dir> to destroy a specific deployment."; exit 1
  fi
fi
[ -f "$SRC" ] || { echo "$SRC not found."; exit 1; }
P2P_ROOT=$(cd "${DIREXIO_HOME:-$HOME/.direxio}" 2>/dev/null && pwd -P || printf '%s' "${DIREXIO_HOME:-$HOME/.direxio}")

command -v jq >/dev/null 2>&1 || { echo "jq is required to parse state.json."; exit 1; }
REGION=$(jq -r '.region // empty' "$SRC")
INSTANCE_ID=$(jq -r '.resources.instance_id // empty' "$SRC")
ROOT_VOLUME_ID=$(jq -r '.resources.root_volume_id // empty' "$SRC")
EIP_ID=$(jq -r '.resources.eip_id // empty' "$SRC")
SG_ID=$(jq -r '.resources.sg_id // empty' "$SRC")
KEY_NAME=$(jq -r '.resources.key_name // empty' "$SRC")
KEY_FILE=$(jq -r '.resources.key_file // empty' "$SRC")
DOMAIN_MODE=$(jq -r '.domain_mode // empty' "$SRC")
DOMAIN=$(jq -r '.domain // empty' "$SRC")
AS_URL=$(jq -r '.as_url // empty' "$SRC")
PUBLIC_IP=$(jq -r '.resources.public_ip // empty' "$SRC")
ROUTE53_ZONE_ID=$(jq -r '.resources.route53_zone_id // empty' "$SRC")
ROUTE53_ZONE_NAME=$(jq -r '.resources.route53_zone_name // empty' "$SRC")
ROUTE53_ZONE_CREATED_BY_DEPLOYER=$(jq -r '.resources.route53_zone_created_by_deployer // empty' "$SRC")
CC_CONNECT_CONFIG=$(jq -r '.cc_connect_config // empty' "$SRC")
CC_CONNECT_BINARY=$(jq -r '.cc_connect_binary // empty' "$SRC")
CC_CONNECT_RUNTIME_DIR=$(jq -r '.cc_connect_runtime_dir // empty' "$SRC")
AGENT_SERVICE_DIR=$(jq -r '.agent_service_dir // empty' "$SRC")
AGENT_SERVICE_ID=$(jq -r '.agent_service_id // empty' "$SRC")

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
if aws_arn_is_root "$AWS_IDENTITY_ARN"; then
  echo "Root AWS access keys are not allowed for destroy. Use a temporary non-root DirexioDeployer IAM user/profile, then rerun."
  exit 2
fi

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
  done < <(aws route53 list-hosted-zones --output json 2>/dev/null | jq -r '.HostedZones[] | [.Id, .Name] | @tsv')
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
  "Comment": "p2p-matrix destroy",
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
  local change_file_aws="$change_file"
  if command -v cygpath >/dev/null 2>&1; then
    change_file_aws=$(cygpath -w "$change_file")
  fi
  change_json=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "file://$change_file_aws" \
    --output json 2>/dev/null) \
    || log "  (Route53 A record may already be absent or changed; check DNS manually)"
  rm -f "$change_file"
  if [ -n "${change_json:-}" ]; then
    change_id=$(printf '%s\n' "$change_json" | jq -r '.ChangeInfo.Id // empty' 2>/dev/null)
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
  local path=$1 drive rest
  path=$(printf '%s' "$path" | sed 's#\\#/#g')
  case "$path" in
    /mnt/[A-Za-z]/*)
      drive=${path#/mnt/}
      drive=${drive%%/*}
      rest=${path#/mnt/$drive/}
      printf '%s:/%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$rest"
      return 0
      ;;
    /cygdrive/[A-Za-z]/*)
      drive=${path#/cygdrive/}
      drive=${drive%%/*}
      rest=${path#/cygdrive/$drive/}
      printf '%s:/%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$rest"
      return 0
      ;;
    /[A-Za-z]/*)
      drive=${path#/}
      drive=${drive%%/*}
      rest=${path#/$drive/}
      printf '%s:/%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$rest"
      return 0
      ;;
  esac
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    case "$path" in [A-Za-z]:/) break ;; esac
    path=${path%/}
  done
  printf '%s\n' "$path"
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
  local left right
  left=$(normalize_local_path "$1")
  right=$(normalize_local_path "$2")
  case "$left:$right" in
    [A-Za-z]:/*:[A-Za-z]:/*)
      [ "$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')" ]
      ;;
    *)
      [ "$left" = "$right" ]
      ;;
  esac
}

current_service_dir() {
  local recorded=$1 asurl=$2 domain=$3 config=${4:-}
  if [ -n "$recorded" ]; then
    printf '%s\n' "$recorded"
    return 0
  fi
  if [ -n "$asurl" ] || [ -n "$domain" ]; then
    direxio_service_dir "${asurl:-$domain}"
    return 0
  fi
  if [ -n "$config" ]; then
    local_dirname "$(local_dirname "$config")"
  fi
}

cc_connect_stop_binary() {
  local binary=$1 runtime_dir=$2 candidate
  if [ -n "$runtime_dir" ]; then
    candidate="$runtime_dir/bin/direxio-connect"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$runtime_dir/bin/direxio-connect.exe"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  if [ -n "$binary" ]; then
    printf '%s\n' "$binary"
    return 0
  fi
  printf 'direxio-connect\n'
}

cc_connect_target_work_dir() {
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
    normalize_local_path "$service_dir/cc-connect"
  fi
}

cc_connect_service_name() {
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
    direxio_service_id "${asurl:-$domain}"
    return 0
  fi
  printf 'cc-connect\n'
}

cc_connect_status_work_dir() {
  local binary=$1 service_name=$2 out
  out=$("$binary" daemon status --service-name "$service_name" 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*WorkDir:[[:space:]]*//p' | head -n 1
}

stop_current_cc_connect_daemon() {
  local config=$1 binary=$2 runtime_dir=$3 service_dir=$4 service_name=$5 target_work_dir running_work_dir stop_binary
  target_work_dir=$(cc_connect_target_work_dir "$config" "$runtime_dir" "$service_dir")
  if [ -z "$target_work_dir" ]; then
    log "cc-connect service directory not recorded; skipping local daemon stop"
    return 0
  fi

  stop_binary=$(cc_connect_stop_binary "$binary" "$runtime_dir")
  case "$stop_binary" in
    */*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *)
      if ! command -v "$stop_binary" >/dev/null 2>&1; then
        log "cc-connect binary not found on PATH; skipping local daemon stop"
        return 0
      fi
      ;;
  esac

  running_work_dir=$(cc_connect_status_work_dir "$stop_binary" "$service_name")
  if [ -z "$running_work_dir" ]; then
    log "cc-connect daemon status has no WorkDir; skipping local daemon stop"
    return 0
  fi

  if ! paths_equal "$target_work_dir" "$running_work_dir"; then
    log "cc-connect daemon belongs to another service; leaving daemon running"
    return 0
  fi

  log "stopping cc-connect daemon for current service ..."
  if "$stop_binary" daemon stop --service-name "$service_name" >/dev/null 2>&1; then
    log "cc-connect daemon stopped"
  else
    log "cc-connect daemon stop failed or service was not installed; continuing destroy"
  fi
}

cleanup_local_service_dir() {
  local service_dir=$1 root=$2 nodes_root src_real nodes_real src_norm nodes_norm name

  if [ "${P2P_KEEP_WORKDIR:-0}" = "1" ]; then
    log "keeping local service dir because P2P_KEEP_WORKDIR=1: $service_dir"
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
    ""|"."|".."|"nodes"|"cc-connect")
      log "refusing to remove unexpected local service dir: $service_dir"
      return 0
      ;;
  esac

  log "removing local service dir $src_real ..."
  rm -rf -- "$src_real"
}

# 0. Remove DNS record if ops created it through Route53 mode.
CURRENT_SERVICE_DIR=$(current_service_dir "$AGENT_SERVICE_DIR" "$AS_URL" "$DOMAIN" "$CC_CONNECT_CONFIG")
CURRENT_SERVICE_NAME=$(cc_connect_service_name "$AGENT_SERVICE_ID" "$CURRENT_SERVICE_DIR" "$AS_URL" "$DOMAIN")
stop_current_cc_connect_daemon "$CC_CONNECT_CONFIG" "$CC_CONNECT_BINARY" "$CC_CONNECT_RUNTIME_DIR" "$CURRENT_SERVICE_DIR" "$CURRENT_SERVICE_NAME"

if [ "${DOMAIN_MODE:-}" = "route53" ]; then
  delete_route53_record "$DOMAIN" "$PUBLIC_IP"
  delete_route53_hosted_zone_if_owned
fi

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

log "Done. Processed resources recorded in $SRC."
log "User-managed DNS and domain purchases are outside automatic destroy scope; handle them manually if needed."
if REPORT_PATH=$(operation_report_write destroy destroy_processed "$SRC" 2>/dev/null); then
  log "operation report written: $REPORT_PATH"
else
  log "operation report was not written; keep destroy logs for audit"
fi
cleanup_local_service_dir "$CURRENT_SERVICE_DIR" "$P2P_ROOT"
