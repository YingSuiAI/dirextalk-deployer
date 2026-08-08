#!/usr/bin/env bash
# Render a fail-closed TLS SNI passthrough config for Agent Cloud Worker.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/../../.." && pwd -P)
# shellcheck source=scripts/lib/json.sh
source "$repo_root/scripts/lib/json.sh"
template=$script_dir/WorkerEdge.haproxy.cfg
output=${1:-}

die() { printf 'render worker edge: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] && [ -n "$output" ] || die 'usage: render-worker-edge.sh OUTPUT_HAPROXY_CONFIG'
case "$output" in /*) ;; *) output=$(pwd -P)/$output ;; esac
[ -d "${output%/*}" ] && [ ! -L "${output%/*}" ] || die 'output directory is unavailable'
[ -f "$template" ] && [ ! -L "$template" ] || die 'Worker edge template is unavailable'
if [ -e "$output" ] || [ -L "$output" ]; then
  [ -f "$output" ] && [ ! -L "$output" ] || die 'output must be a regular file'
fi

require_domain() {
  local name=$1 value=$2
  [ "$value" = "${value,,}" ] || die "$name must be lowercase"
  [ "${#value}" -le 253 ] || die "$name is too long"
  printf '%s\n' "$value" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' \
    || die "$name must be a canonical DNS hostname"
  case "$value" in *..*|*.-*|*-.*) die "$name is not canonical" ;; esac
}

require_upstream() {
  local name=$1 value=$2 host port
  case "$value" in *[!a-zA-Z0-9.:-]*|*:*:*) die "$name must be HOST:PORT without a scheme or path" ;; esac
  host=${value%:*}
  port=${value##*:}
  [ -n "$host" ] && printf '%s\n' "$host" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*$' \
    || die "$name host is invalid"
  printf '%s\n' "$port" | grep -Eq '^[1-9][0-9]{0,4}$' || die "$name port is invalid"
  [ "$port" -le 65535 ] || die "$name port is above 65535"
}

control_domain=${DIREXTALK_WORKER_CONTROL_DOMAIN:-}
relay_domain=${DIREXTALK_MODEL_RELAY_DOMAIN:-}
proxy_domain=${DIREXTALK_OUTBOUND_PROXY_DOMAIN:-}
control_upstream=${DIREXTALK_WORKER_CONTROL_UPSTREAM:-}
relay_upstream=${DIREXTALK_MODEL_RELAY_UPSTREAM:-}
proxy_upstream=${DIREXTALK_OUTBOUND_PROXY_UPSTREAM:-}
region=${DIREXTALK_WORKER_EDGE_REGION:-}
route_mode=${DIREXTALK_WORKER_EDGE_ROUTE_MODE:-}
listen_ip=${DIREXTALK_WORKER_EDGE_LISTEN_IP:-}
s2_private_ip=${DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP:-}
lightsail_vpc_peered=${DIREXTALK_WORKER_EDGE_LIGHTSAIL_VPC_PEERED:-false}
evidence_file=${DIREXTALK_WORKER_EDGE_EVIDENCE_FILE:-}

require_ipv4() {
  local name=$1 value=$2 octet
  printf '%s\n' "$value" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' \
    || die "$name must be a canonical IPv4 address"
  IFS=. read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do [ "$octet" -le 255 ] || die "$name contains an IPv4 octet above 255"; done
}

require_ipv4 DIREXTALK_WORKER_EDGE_LISTEN_IP "$listen_ip"
require_ipv4 DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP "$s2_private_ip"

printf '%s\n' "$region" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' \
  || die 'DIREXTALK_WORKER_EDGE_REGION must be an explicit AWS region'
case "$route_mode" in
  private)
    [ "$lightsail_vpc_peered" = true ] \
      || die 'private route mode requires verified Lightsail VPC peering'
    ;;
  controlled-public)
    [ "$lightsail_vpc_peered" = false ] \
      || die 'controlled-public route mode must not claim Lightsail VPC peering'
    ;;
  *) die 'DIREXTALK_WORKER_EDGE_ROUTE_MODE must be private or controlled-public' ;;
esac

require_domain DIREXTALK_WORKER_CONTROL_DOMAIN "$control_domain"
require_domain DIREXTALK_MODEL_RELAY_DOMAIN "$relay_domain"
require_domain DIREXTALK_OUTBOUND_PROXY_DOMAIN "$proxy_domain"
[ "$(printf '%s\n' "$control_domain" "$relay_domain" "$proxy_domain" | LC_ALL=C sort -u | wc -l)" -eq 3 ] \
  || die 'Worker edge hostnames must be distinct'
require_upstream DIREXTALK_WORKER_CONTROL_UPSTREAM "$control_upstream"
require_upstream DIREXTALK_MODEL_RELAY_UPSTREAM "$relay_upstream"
require_upstream DIREXTALK_OUTBOUND_PROXY_UPSTREAM "$proxy_upstream"
[ "$control_upstream" = "$s2_private_ip:10443" ] \
  || die 'WorkerControl upstream must be the verified S2 private IP on port 10443'
[ "$relay_upstream" = "$s2_private_ip:11443" ] \
  || die 'Model Relay upstream must be the verified S2 private IP on port 11443'
case "$proxy_upstream" in 127.0.0.1:*) ;; *) die 'controlled proxy upstream must be loopback on the Worker edge host' ;; esac

[ -n "$evidence_file" ] || die 'DIREXTALK_WORKER_EDGE_EVIDENCE_FILE is required'
case "$evidence_file" in /*) ;; *) die 'Worker edge evidence path must be absolute' ;; esac
[ -f "$evidence_file" ] && [ ! -L "$evidence_file" ] || die 'Worker edge evidence must be a regular file'
[ "$(stat -c '%a' "$evidence_file")" = 600 ] || die 'Worker edge evidence must be mode 0600'
evidence_identity=$(stat -c '%d:%i:%u:%g:%a' "$evidence_file")
evidence_sha=$(sha256sum "$evidence_file" | awk '{print $1}')
json_check "$evidence_file" "
  data.schema === 'dirextalk-worker-edge-evidence-v1' &&
  /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(data.run_id) &&
  /^[0-9]{12}$/.test(data.account_id) && data.region === '$region' && data.route_mode === '$route_mode' &&
  new RegExp('^arn:aws:lightsail:' + data.region + ':' + data.account_id + ':Instance/[0-9a-f-]{36}$').test(data.lightsail.instance_arn) &&
  data.lightsail.private_ip === '$s2_private_ip' && /^vpc-[0-9a-f]{8,17}$/.test(data.lightsail.default_vpc_id) &&
  /^i-[0-9a-f]{8,17}$/.test(data.edge.instance_id) && data.edge.private_ip === '$listen_ip' &&
  /^eipalloc-[0-9a-f]{8,17}$/.test(data.edge.eip_allocation_id) && /^Z[A-Z0-9]{1,31}$/.test(data.private_dns.hosted_zone_id) &&
  JSON.stringify(data.private_dns.records.worker_control) === JSON.stringify({hostname:'$control_domain',address:'$listen_ip'}) &&
  JSON.stringify(data.private_dns.records.model_relay) === JSON.stringify({hostname:'$relay_domain',address:'$listen_ip'}) &&
  JSON.stringify(data.private_dns.records.outbound_proxy) === JSON.stringify({hostname:'$proxy_domain',address:'$listen_ip'}) &&
  /^sg-[0-9a-f]{8,17}$/.test(data.security.worker_security_group_id) && /^sg-[0-9a-f]{8,17}$/.test(data.security.edge_security_group_id) &&
  JSON.stringify(data.security.worker_egress) === JSON.stringify({destination:'$listen_ip/32',ports:[443]}) &&
  JSON.stringify(data.security.edge_ingress) === JSON.stringify({source_security_group_id:data.security.worker_security_group_id,ports:[443]}) &&
  JSON.stringify(data.security.edge_to_s2) === JSON.stringify({destination:'$s2_private_ip/32',ports:[10443,11443]}) &&
  JSON.stringify(data.backends) === JSON.stringify({worker_control:'$control_upstream',model_relay:'$relay_upstream',outbound_proxy:'$proxy_upstream'}) &&
  data.readback.owner_account_id === data.account_id && data.readback.region === '$region' &&
  data.lightsail.vpc_peered === ('$route_mode' === 'private')
" >/dev/null || die 'Worker edge evidence is incomplete or differs from the requested route'
[ "$(stat -c '%d:%i:%u:%g:%a' "$evidence_file")" = "$evidence_identity" ] \
  && [ "$(sha256sum "$evidence_file" | awk '{print $1}')" = "$evidence_sha" ] \
  || die 'Worker edge evidence identity changed during verification'
run_id=$(json_get "$evidence_file" run_id)
account_id=$(json_get "$evidence_file" account_id)
lightsail_instance_arn=$(json_get "$evidence_file" lightsail.instance_arn)
edge_instance_id=$(json_get "$evidence_file" edge.instance_id)
edge_eip_allocation_id=$(json_get "$evidence_file" edge.eip_allocation_id)
private_hosted_zone_id=$(json_get "$evidence_file" private_dns.hosted_zone_id)
worker_security_group_id=$(json_get "$evidence_file" security.worker_security_group_id)
edge_security_group_id=$(json_get "$evidence_file" security.edge_security_group_id)

tmp=$(mktemp "${output%/*}/.${output##*/}.XXXXXX") || die 'could not create output temporary file'
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT HUP INT TERM
sed \
  -e "s/__DIREXTALK_WORKER_CONTROL_DOMAIN__/$control_domain/g" \
  -e "s/__DIREXTALK_MODEL_RELAY_DOMAIN__/$relay_domain/g" \
  -e "s/__DIREXTALK_OUTBOUND_PROXY_DOMAIN__/$proxy_domain/g" \
  -e "s/__DIREXTALK_WORKER_CONTROL_UPSTREAM__/$control_upstream/g" \
  -e "s/__DIREXTALK_MODEL_RELAY_UPSTREAM__/$relay_upstream/g" \
  -e "s/__DIREXTALK_OUTBOUND_PROXY_UPSTREAM__/$proxy_upstream/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_REGION__/$region/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_ROUTE_MODE__/$route_mode/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_LISTEN_IP__/$listen_ip/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_EVIDENCE_SHA256__/sha256:$evidence_sha/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_RUN_ID__/$run_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_ACCOUNT_ID__/$account_id/g" \
  -e "s#__DIREXTALK_WORKER_EDGE_LIGHTSAIL_INSTANCE_ARN__#$lightsail_instance_arn#g" \
  -e "s/__DIREXTALK_WORKER_EDGE_INSTANCE_ID__/$edge_instance_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_EIP_ALLOCATION_ID__/$edge_eip_allocation_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_PRIVATE_HOSTED_ZONE_ID__/$private_hosted_zone_id/g" \
  -e "s/__DIREXTALK_WORKER_SECURITY_GROUP_ID__/$worker_security_group_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_SECURITY_GROUP_ID__/$edge_security_group_id/g" \
  "$template" >"$tmp" || die 'could not render Worker edge config'
if grep -Eq '__DIREXTALK_[A-Z0-9_]+__' "$tmp"; then
  die 'Worker edge config contains an unresolved placeholder'
fi
chmod 0444 "$tmp" || die 'could not set Worker edge config read permissions'
mv -f "$tmp" "$output" || die 'could not atomically install Worker edge config'
trap - EXIT HUP INT TERM
