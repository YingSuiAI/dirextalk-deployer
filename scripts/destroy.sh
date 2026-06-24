#!/usr/bin/env bash
# destroy.sh - remove AWS resources recorded by deployment state.
#
# Source:
#   1. $P2P_WORKDIR/state.json written by orchestrate.sh; default ~/.direxio/deploy/
#   2. explicit argument: bash destroy.sh /path/to/state.json
#
# Order: terminate instance -> release EIP -> delete security group -> delete key pair
# -> remove the corresponding local deploy workdir.
# Each cloud step is tolerant of already-removed resources.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
P2P_WORKDIR=${P2P_WORKDIR:-${DIREXIO_WORKDIR:-$HOME/.direxio/deploy}}

log() { echo -e "\033[33m[destroy]\033[0m $*"; }

# Resolve source and load INSTANCE_ID/EIP_ID/SG_ID/KEY_NAME/KEY_FILE/REGION.
SRC=${1:-}
if [ -z "$SRC" ]; then
  if   [ -f "$P2P_WORKDIR/state.json" ]; then SRC="$P2P_WORKDIR/state.json"
  else echo "state.json not found; cannot determine which resources to destroy."; exit 1
  fi
fi
[ -f "$SRC" ] || { echo "$SRC not found."; exit 1; }
SRC_DIR=$(cd "$(dirname "$SRC")" && pwd -P)
P2P_ROOT=$(cd "${DIREXIO_HOME:-$HOME/.direxio}" 2>/dev/null && pwd -P || printf '%s' "${DIREXIO_HOME:-$HOME/.direxio}")

command -v jq >/dev/null 2>&1 || { echo "jq is required to parse state.json."; exit 1; }
REGION=$(jq -r '.region // empty' "$SRC")
INSTANCE_ID=$(jq -r '.resources.instance_id // empty' "$SRC")
EIP_ID=$(jq -r '.resources.eip_id // empty' "$SRC")
SG_ID=$(jq -r '.resources.sg_id // empty' "$SRC")
KEY_NAME=$(jq -r '.resources.key_name // empty' "$SRC")
KEY_FILE=$(jq -r '.resources.key_file // empty' "$SRC")
DOMAIN_MODE=$(jq -r '.domain_mode // empty' "$SRC")
DOMAIN=$(jq -r '.domain // empty' "$SRC")
PUBLIC_IP=$(jq -r '.resources.public_ip // empty' "$SRC")

export NO_PROXY="*"; export no_proxy="*"
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy 2>/dev/null || true
[ -n "${REGION:-${AWS_DEFAULT_REGION:-}}" ] || {
  echo "Region is missing. Add .region to state.json or set AWS_DEFAULT_REGION, then retry."
  exit 1
}
export AWS_DEFAULT_REGION=${REGION:-${AWS_DEFAULT_REGION:-}}

log "source = $SRC (region=$AWS_DEFAULT_REGION)"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials are required before destroy can remove cloud resources or local state."
  exit 1
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
  local domain=$1 public_ip=$2 zone zone_id zone_name change_file
  [ -n "$domain" ] && [ -n "$public_ip" ] || return 0
  zone=$(find_route53_zone "$domain")
  zone_id=$(printf '%s' "$zone" | cut -f1)
  zone_name=$(printf '%s' "$zone" | cut -f2)
  if [ -z "$zone_id" ]; then
    log "Route53 hosted zone not found for $domain; leaving DNS record untouched"
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
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "file://$change_file_aws" >/dev/null 2>&1 \
    || log "  (Route53 A record may already be absent or changed; check DNS manually)"
  rm -f "$change_file"
}

cleanup_local_workdir() {
  local src_dir=$1 root=$2

  if [ "${P2P_KEEP_WORKDIR:-0}" = "1" ]; then
    log "keeping local workdir because P2P_KEEP_WORKDIR=1: $src_dir"
    return 0
  fi

  [ -n "$src_dir" ] && [ -d "$src_dir" ] || return 0
  [ -n "$root" ] && [ -d "$root" ] || {
    log "local workdir root not found; leaving $src_dir untouched"
    return 0
  }

  case "$src_dir" in
    "$root"/*) ;;
    *)
      log "refusing to remove local workdir outside $root: $src_dir"
      return 0
      ;;
  esac

  case "$(basename "$src_dir")" in
    deploy|deploy-*) ;;
    *)
      log "refusing to remove unexpected local workdir name: $src_dir"
      return 0
      ;;
  esac

  log "removing local deploy workdir $src_dir ..."
  rm -rf -- "$src_dir"
}

# 0. Remove DNS record if ops created it through Route53 mode.
if [ "${DOMAIN_MODE:-}" = "route53" ]; then
  delete_route53_record "$DOMAIN" "$PUBLIC_IP"
fi

# 1. Terminate instance.
if [ -n "${INSTANCE_ID:-}" ]; then
  log "terminating instance $INSTANCE_ID ..."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || log "  (instance may already be gone)"
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || true
fi

# 2. Release Elastic IP.
if [ -n "${EIP_ID:-}" ]; then
  log "releasing Elastic IP $EIP_ID ..."
  aws ec2 release-address --allocation-id "$EIP_ID" 2>/dev/null || log "  (EIP may already be released)"
fi

# 3. Delete security group after instance/network interfaces detach.
if [ -n "${SG_ID:-}" ]; then
  log "deleting security group $SG_ID ..."
  for i in 1 2 3 4 5; do
    if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then break; fi
    sleep 6
    [ "$i" = 5 ] && log "  (security group delete failed; an ENI may still be attached, delete it manually later)"
  done
fi

# 4. Delete key pair and local private key.
if [ -n "${KEY_NAME:-}" ]; then
  log "deleting key pair $KEY_NAME ..."
  aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
  [ -n "${KEY_FILE:-}" ] && [ -f "$KEY_FILE" ] && rm -f "$KEY_FILE"
fi

log "Done. Processed resources recorded in $SRC."
log "User-managed DNS and domain purchases are outside automatic destroy scope; handle them manually if needed."
cleanup_local_workdir "$SRC_DIR" "$P2P_ROOT"
