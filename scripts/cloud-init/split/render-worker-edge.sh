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
s2_region=${DIREXTALK_WORKER_EDGE_S2_REGION:-}
owner_id=${DIREXTALK_WORKER_EDGE_OWNER_ID:-}
account_generation=${DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION:-}
route_mode=${DIREXTALK_WORKER_EDGE_ROUTE_MODE:-}
listen_ip=${DIREXTALK_WORKER_EDGE_LISTEN_IP:-}
s2_private_ip=${DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP:-}
s2_public_ip=${DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP:-}
lightsail_vpc_peered=${DIREXTALK_WORKER_EDGE_LIGHTSAIL_VPC_PEERED:-false}
evidence_file=${DIREXTALK_WORKER_EDGE_EVIDENCE_FILE:-}
worker_source_cidr=${DIREXTALK_WORKER_EDGE_SOURCE_CIDR:-}

require_ipv4() {
  local name=$1 value=$2 octet
  printf '%s\n' "$value" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' \
    || die "$name must be a canonical IPv4 address"
  IFS=. read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do [ "$octet" -le 255 ] || die "$name contains an IPv4 octet above 255"; done
}

require_ipv4 DIREXTALK_WORKER_EDGE_LISTEN_IP "$listen_ip"
require_ipv4 DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP "$s2_private_ip"
require_ipv4 DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP "$s2_public_ip"
printf '%s\n' "$worker_source_cidr" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})/(1[6-9]|2[0-8])$' \
  || die 'DIREXTALK_WORKER_EDGE_SOURCE_CIDR must be an AWS IPv4 subnet CIDR (/16 through /28)'
worker_source_ip=${worker_source_cidr%/*}
worker_source_prefix=${worker_source_cidr##*/}
require_ipv4 DIREXTALK_WORKER_EDGE_SOURCE_CIDR "$worker_source_ip"
IFS=. read -r worker_source_a worker_source_b worker_source_c worker_source_d <<<"$worker_source_ip"
if ! { [ "$worker_source_a" -eq 10 ] ||
  { [ "$worker_source_a" -eq 172 ] && [ "$worker_source_b" -ge 16 ] && [ "$worker_source_b" -le 31 ]; } ||
  { [ "$worker_source_a" -eq 192 ] && [ "$worker_source_b" -eq 168 ]; }; }; then
  die 'DIREXTALK_WORKER_EDGE_SOURCE_CIDR must be a private RFC1918 subnet'
fi
worker_source_value=$(( (worker_source_a << 24) | (worker_source_b << 16) | (worker_source_c << 8) | worker_source_d ))
worker_source_mask=$(( (0xFFFFFFFF << (32 - worker_source_prefix)) & 0xFFFFFFFF ))
[ $((worker_source_value & worker_source_mask)) -eq "$worker_source_value" ] \
  || die 'DIREXTALK_WORKER_EDGE_SOURCE_CIDR must identify a canonical network'

printf '%s\n' "$region" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' \
  || die 'DIREXTALK_WORKER_EDGE_REGION must be an explicit AWS region'
printf '%s\n' "$s2_region" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' \
  || die 'DIREXTALK_WORKER_EDGE_S2_REGION must be an explicit AWS region'
printf '%s\n' "$owner_id" | grep -Eq '^@[A-Za-z0-9._=-]+:[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' \
  || die 'DIREXTALK_WORKER_EDGE_OWNER_ID must be a canonical Matrix user ID'
printf '%s\n' "$account_generation" | grep -Eq '^[1-9][0-9]{0,18}$' \
  || die 'DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION must be positive'
case "$route_mode" in
  private)
    [ "$lightsail_vpc_peered" = true ] \
      || die 'private route mode requires verified Lightsail VPC peering'
    [ "$region" = "$s2_region" ] \
      || die 'private route mode requires the edge and S2 to use the same AWS region'
    s2_route_ip=$s2_private_ip
    ;;
  controlled-public)
    [ "$lightsail_vpc_peered" = false ] \
      || die 'controlled-public route mode must not claim Lightsail VPC peering'
    s2_route_ip=$s2_public_ip
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
[ "$control_upstream" = "$s2_route_ip:10443" ] \
  || die 'WorkerControl upstream must use the verified S2 route address on port 10443'
[ "$relay_upstream" = "$s2_route_ip:11443" ] \
  || die 'Model Relay upstream must use the verified S2 route address on port 11443'
case "$proxy_upstream" in 127.0.0.1:*) ;; *) die 'controlled proxy upstream must be loopback on the Worker edge host' ;; esac

[ -n "$evidence_file" ] || die 'DIREXTALK_WORKER_EDGE_EVIDENCE_FILE is required'
case "$evidence_file" in /*) ;; *) die 'Worker edge evidence path must be absolute' ;; esac
[ -f "$evidence_file" ] && [ ! -L "$evidence_file" ] || die 'Worker edge evidence must be a regular file'
[ "$(stat -c '%a' "$evidence_file")" = 600 ] || die 'Worker edge evidence must be mode 0600'
evidence_identity=$(stat -c '%d:%i:%u:%g:%a' "$evidence_file")
evidence_sha=$(sha256sum "$evidence_file" | awk '{print $1}')
json_check "$evidence_file" "
  data.schema === 'dirextalk-worker-edge-evidence-v3' &&
  /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(data.run_id) &&
  /^[0-9]{12}$/.test(data.account_id) && data.owner_id === '$owner_id' && String(data.account_generation) === '$account_generation' &&
  data.edge_region === '$region' && data.route_mode === '$route_mode' &&
  data.lightsail.region === '$s2_region' &&
  new RegExp('^arn:aws:lightsail:' + data.lightsail.region + ':' + data.account_id + ':Instance/[0-9a-f-]{36}$').test(data.lightsail.instance_arn) &&
  typeof data.lightsail.support_code === 'string' && /\\S/.test(data.lightsail.support_code) &&
  data.lightsail.private_ip === '$s2_private_ip' && data.lightsail.public_ip === '$s2_public_ip' &&
  /^vpc-[0-9a-f]{8,17}$/.test(data.lightsail.default_vpc_id) &&
  data.edge.owner_account_id === data.account_id && data.edge.region === '$region' &&
  /^i-[0-9a-f]{8,17}$/.test(data.edge.instance_id) && data.edge.private_ip === '$listen_ip' &&
  /^([0-9]{1,3}\\.){3}[0-9]{1,3}$/.test(data.edge.public_ip) &&
  /^vpc-[0-9a-f]{8,17}$/.test(data.edge.vpc_id) && /^subnet-[0-9a-f]{8,17}$/.test(data.edge.subnet_id) &&
  /^eipalloc-[0-9a-f]{8,17}$/.test(data.edge.eip_allocation_id) && /^eipassoc-[0-9a-f]{8,17}$/.test(data.edge.eip_association_id) &&
  /^Z[A-Z0-9]{1,31}$/.test(data.private_dns.hosted_zone_id) && data.private_dns.vpc_id === data.edge.vpc_id && data.private_dns.region === '$region' &&
  JSON.stringify(data.private_dns.records.worker_control) === JSON.stringify({hostname:'$control_domain',address:'$listen_ip'}) &&
  JSON.stringify(data.private_dns.records.model_relay) === JSON.stringify({hostname:'$relay_domain',address:'$listen_ip'}) &&
  JSON.stringify(data.private_dns.records.outbound_proxy) === JSON.stringify({hostname:'$proxy_domain',address:'$listen_ip'}) &&
  /^Z[A-Z0-9]{1,31}$/.test(data.public_dns.hosted_zone_id) &&
  JSON.stringify(data.public_dns.records.worker_control) === JSON.stringify({hostname:'$control_domain',address:data.edge.public_ip}) &&
  JSON.stringify(data.public_dns.records.model_relay) === JSON.stringify({hostname:'$relay_domain',address:data.edge.public_ip}) &&
  JSON.stringify(data.public_dns.records.outbound_proxy) === JSON.stringify({hostname:'$proxy_domain',address:data.edge.public_ip}) &&
  JSON.stringify(Object.keys(data.security || {}).sort()) === JSON.stringify(['edge_dns_egress','edge_https_egress','edge_ingress','edge_security_group_id','edge_to_s2']) &&
  /^sg-[0-9a-f]{8,17}$/.test(data.security.edge_security_group_id) &&
  JSON.stringify(data.security.edge_ingress) === JSON.stringify({source_cidr:'$worker_source_cidr',ip_protocol:'-1'}) &&
  JSON.stringify(data.security.edge_to_s2) === JSON.stringify({destination:'$s2_route_ip/32',ports:[10443,11443]}) &&
  Array.isArray(data.security.edge_dns_egress) && data.security.edge_dns_egress.length > 0 &&
  data.security.edge_dns_egress.every(value => /^([0-9]{1,3}\\.){3}[0-9]{1,3}\\/32$/.test(value.destination) && JSON.stringify(value.ports) === JSON.stringify([53]) && JSON.stringify(value.protocols) === JSON.stringify(['tcp','udp'])) &&
  JSON.stringify(data.security.edge_https_egress) === JSON.stringify({destination:'0.0.0.0/0',ports:[443]}) &&
  JSON.stringify(data.backends) === JSON.stringify({worker_control:'$control_upstream',model_relay:'$relay_upstream',outbound_proxy:'$proxy_upstream'}) &&
  data.readback.owner_account_id === data.account_id && data.readback.edge_region === '$region' && data.readback.lightsail_region === '$s2_region' &&
  data.lightsail.vpc_peered === ('$route_mode' === 'private') &&
  ('$route_mode' !== 'controlled-public' || JSON.stringify(data.lightsail.control_ingress) === JSON.stringify({source:data.edge.public_ip + '/32',ports:[10443,11443]})) &&
  ('$route_mode' !== 'private' || data.lightsail.control_ingress === null)
" >/dev/null || die 'Worker edge evidence is incomplete or differs from the requested route'
[ "$(stat -c '%d:%i:%u:%g:%a' "$evidence_file")" = "$evidence_identity" ] \
  && [ "$(sha256sum "$evidence_file" | awk '{print $1}')" = "$evidence_sha" ] \
  || die 'Worker edge evidence identity changed during verification'
run_id=$(json_get "$evidence_file" run_id)
account_id=$(json_get "$evidence_file" account_id)
evidence_owner_id=$(json_get "$evidence_file" owner_id)
evidence_account_generation=$(json_get "$evidence_file" account_generation)
lightsail_instance_arn=$(json_get "$evidence_file" lightsail.instance_arn)
edge_instance_id=$(json_get "$evidence_file" edge.instance_id)
edge_eip_allocation_id=$(json_get "$evidence_file" edge.eip_allocation_id)
edge_eip_association_id=$(json_get "$evidence_file" edge.eip_association_id)
private_hosted_zone_id=$(json_get "$evidence_file" private_dns.hosted_zone_id)
public_hosted_zone_id=$(json_get "$evidence_file" public_dns.hosted_zone_id)
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
  -e "s/__DIREXTALK_WORKER_EDGE_S2_REGION__/$s2_region/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_ROUTE_MODE__/$route_mode/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_LISTEN_IP__/$listen_ip/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_EVIDENCE_SHA256__/sha256:$evidence_sha/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_RUN_ID__/$run_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_ACCOUNT_ID__/$account_id/g" \
  -e "s#__DIREXTALK_WORKER_EDGE_OWNER_ID__#$evidence_owner_id#g" \
  -e "s/__DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION__/$evidence_account_generation/g" \
  -e "s#__DIREXTALK_WORKER_EDGE_LIGHTSAIL_INSTANCE_ARN__#$lightsail_instance_arn#g" \
  -e "s/__DIREXTALK_WORKER_EDGE_INSTANCE_ID__/$edge_instance_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_EIP_ALLOCATION_ID__/$edge_eip_allocation_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_EIP_ASSOCIATION_ID__/$edge_eip_association_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_PRIVATE_HOSTED_ZONE_ID__/$private_hosted_zone_id/g" \
  -e "s/__DIREXTALK_WORKER_EDGE_PUBLIC_HOSTED_ZONE_ID__/$public_hosted_zone_id/g" \
  -e "s#__DIREXTALK_WORKER_EDGE_SOURCE_CIDR__#$worker_source_cidr#g" \
  -e "s/__DIREXTALK_WORKER_EDGE_SECURITY_GROUP_ID__/$edge_security_group_id/g" \
  "$template" >"$tmp" || die 'could not render Worker edge config'
if grep -Eq '__DIREXTALK_[A-Z0-9_]+__' "$tmp"; then
  die 'Worker edge config contains an unresolved placeholder'
fi
chmod 0444 "$tmp" || die 'could not set Worker edge config read permissions'
mv -f "$tmp" "$output" || die 'could not atomically install Worker edge config'
trap - EXIT HUP INT TERM
