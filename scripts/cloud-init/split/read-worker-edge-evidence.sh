#!/usr/bin/env bash
# Read the exact AWS topology used by Agent Cloud Worker and atomically seal it.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/../../.." && pwd -P)
# shellcheck source=scripts/lib/json.sh
source "$repo_root/scripts/lib/json.sh"

output=${1:-}
die() { printf 'read worker edge evidence: %s\n' "$*" >&2; exit 1; }
required() { local value=${!1:-}; [ -n "$value" ] || die "$1 is required"; }

[ "$#" -eq 1 ] && [ -n "$output" ] || die 'usage: read-worker-edge-evidence.sh OUTPUT_JSON'
case "$output" in /*) ;; *) output=$(pwd -P)/$output ;; esac
[ -d "${output%/*}" ] && [ ! -L "${output%/*}" ] || die 'output directory is unavailable'
if [ -e "$output" ] || [ -L "$output" ]; then
  [ -f "$output" ] && [ ! -L "$output" ] || die 'output must be a regular file'
fi

for name in \
  DIREXTALK_WORKER_EDGE_RUN_ID DIREXTALK_WORKER_EDGE_ACCOUNT_ID \
  DIREXTALK_WORKER_EDGE_OWNER_ID DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION \
  DIREXTALK_WORKER_EDGE_REGION DIREXTALK_WORKER_EDGE_ROUTE_MODE \
  DIREXTALK_WORKER_EDGE_S2_REGION DIREXTALK_WORKER_EDGE_S2_INSTANCE_NAME \
  DIREXTALK_WORKER_EDGE_S2_INSTANCE_ARN DIREXTALK_WORKER_EDGE_S2_SUPPORT_CODE \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP \
  DIREXTALK_WORKER_EDGE_INSTANCE_ID DIREXTALK_WORKER_EDGE_EIP_ALLOCATION_ID \
  DIREXTALK_WORKER_EDGE_PRIVATE_HOSTED_ZONE_ID DIREXTALK_WORKER_EDGE_PUBLIC_HOSTED_ZONE_ID \
  DIREXTALK_WORKER_EDGE_SOURCE_CIDR DIREXTALK_WORKER_EDGE_SECURITY_GROUP_ID \
  DIREXTALK_WORKER_EDGE_DNS_RESOLVER_CIDR DIREXTALK_WORKER_CONTROL_DOMAIN \
  DIREXTALK_MODEL_RELAY_DOMAIN DIREXTALK_OUTBOUND_PROXY_DOMAIN; do
  required "$name"
done

run_id=$DIREXTALK_WORKER_EDGE_RUN_ID
account_id=$DIREXTALK_WORKER_EDGE_ACCOUNT_ID
owner_id=$DIREXTALK_WORKER_EDGE_OWNER_ID
account_generation=$DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION
edge_region=$DIREXTALK_WORKER_EDGE_REGION
route_mode=$DIREXTALK_WORKER_EDGE_ROUTE_MODE
s2_region=$DIREXTALK_WORKER_EDGE_S2_REGION
s2_name=$DIREXTALK_WORKER_EDGE_S2_INSTANCE_NAME
s2_arn=$DIREXTALK_WORKER_EDGE_S2_INSTANCE_ARN
s2_support_code=$DIREXTALK_WORKER_EDGE_S2_SUPPORT_CODE
s2_private_ip=$DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP
s2_public_ip=$DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP
edge_instance_id=$DIREXTALK_WORKER_EDGE_INSTANCE_ID
edge_eip_allocation_id=$DIREXTALK_WORKER_EDGE_EIP_ALLOCATION_ID
private_zone_id=${DIREXTALK_WORKER_EDGE_PRIVATE_HOSTED_ZONE_ID#/hostedzone/}
public_zone_id=${DIREXTALK_WORKER_EDGE_PUBLIC_HOSTED_ZONE_ID#/hostedzone/}
worker_source_cidr=$DIREXTALK_WORKER_EDGE_SOURCE_CIDR
edge_sg=$DIREXTALK_WORKER_EDGE_SECURITY_GROUP_ID
dns_resolver_cidr=$DIREXTALK_WORKER_EDGE_DNS_RESOLVER_CIDR
control_domain=$DIREXTALK_WORKER_CONTROL_DOMAIN
relay_domain=$DIREXTALK_MODEL_RELAY_DOMAIN
proxy_domain=$DIREXTALK_OUTBOUND_PROXY_DOMAIN

printf '%s\n' "$run_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' || die 'run id is invalid'
printf '%s\n' "$account_id" | grep -Eq '^[0-9]{12}$' || die 'account id is invalid'
printf '%s\n' "$owner_id" | grep -Eq '^@[A-Za-z0-9._=-]+:[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || die 'owner id is invalid'
printf '%s\n' "$account_generation" | grep -Eq '^[1-9][0-9]{0,18}$' || die 'account generation is invalid'
for value in "$edge_region" "$s2_region"; do
  printf '%s\n' "$value" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' || die 'AWS region is invalid'
done
case "$route_mode" in private|controlled-public) ;; *) die 'route mode is invalid' ;; esac
for value in "$s2_private_ip" "$s2_public_ip"; do
  printf '%s\n' "$value" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' || die 'S2 IP is invalid'
done
printf '%s\n' "$s2_arn" | grep -Eq "^arn:aws:lightsail:$s2_region:$account_id:Instance/[0-9a-f-]{36}$" || die 'S2 ARN is invalid'
printf '%s\n' "$edge_instance_id:$edge_eip_allocation_id:$edge_sg" | \
  grep -Eq '^i-[0-9a-f]{8,17}:eipalloc-[0-9a-f]{8,17}:sg-[0-9a-f]{8,17}$' || die 'edge AWS identifiers are invalid'
printf '%s\n' "$private_zone_id:$public_zone_id" | grep -Eq '^Z[A-Z0-9]{1,31}:Z[A-Z0-9]{1,31}$' || die 'hosted zone id is invalid'
printf '%s\n' "$dns_resolver_cidr" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/32$' || die 'DNS resolver CIDR is invalid'
printf '%s\n' "$worker_source_cidr" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})/(1[6-9]|2[0-8])$' \
  || die 'Worker source CIDR must be an AWS IPv4 subnet CIDR (/16 through /28)'
worker_source_ip=${worker_source_cidr%/*}
worker_source_prefix=${worker_source_cidr##*/}
IFS=. read -r worker_source_a worker_source_b worker_source_c worker_source_d <<<"$worker_source_ip"
for octet in "$worker_source_a" "$worker_source_b" "$worker_source_c" "$worker_source_d"; do
  [ "$octet" -le 255 ] || die 'Worker source CIDR contains an IPv4 octet above 255'
done
if ! { [ "$worker_source_a" -eq 10 ] ||
  { [ "$worker_source_a" -eq 172 ] && [ "$worker_source_b" -ge 16 ] && [ "$worker_source_b" -le 31 ]; } ||
  { [ "$worker_source_a" -eq 192 ] && [ "$worker_source_b" -eq 168 ]; }; }; then
  die 'Worker source CIDR must be a private RFC1918 subnet'
fi
worker_source_value=$(( (worker_source_a << 24) | (worker_source_b << 16) | (worker_source_c << 8) | worker_source_d ))
worker_source_mask=$(( (0xFFFFFFFF << (32 - worker_source_prefix)) & 0xFFFFFFFF ))
[ $((worker_source_value & worker_source_mask)) -eq "$worker_source_value" ] || die 'Worker source CIDR is not a canonical network'
for value in "$control_domain" "$relay_domain" "$proxy_domain"; do
  printf '%s\n' "$value" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' || die 'Worker hostname is invalid'
done
[ "$(printf '%s\n' "$control_domain" "$relay_domain" "$proxy_domain" | LC_ALL=C sort -u | wc -l)" -eq 3 ] || die 'Worker hostnames must be distinct'

verify_account() {
  local actual
  actual=$(aws sts get-caller-identity --query Account --output text) || die 'STS caller identity read failed'
  [ "$actual" = "$account_id" ] || die 'STS caller account differs from the requested account'
}

aws_read() {
  verify_account
  aws "$@"
}

read_single() {
  local value
  value=$(aws_read "$@") || die 'AWS read failed'
  [ -n "$value" ] || die 'AWS read returned no object'
  case "$value" in *$'\n'*) die 'AWS read returned multiple objects' ;; esac
  printf '%s\n' "$value"
}

tmp_dir=$(mktemp -d "${output%/*}/.worker-edge-evidence.XXXXXX") || die 'could not create evidence staging directory'
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM

edge_json=$tmp_dir/edge.json
eip_json=$tmp_dir/eip.json
edge_sg_json=$tmp_dir/edge-sg.json
private_records_json=$tmp_dir/private-records.json
public_records_json=$tmp_dir/public-records.json
port_states_json=$tmp_dir/port-states.json
s2_json=$tmp_dir/s2.json
private_zone_json=$tmp_dir/private-zone.json
public_zone_json=$tmp_dir/public-zone.json

aws_read --region "$edge_region" ec2 describe-instances --instance-ids "$edge_instance_id" --output json >"$edge_json" || die 'edge instance read failed'
json_check "$edge_json" "
  (() => {
    const r=data.Reservations?.[0], i=r?.Instances?.[0], tags=Object.fromEntries((i?.Tags || []).map(v => [v.Key,v.Value]));
    return data.Reservations?.length === 1 && r.Instances?.length === 1 && r.OwnerId === '$account_id' &&
      i.InstanceId === '$edge_instance_id' && i.State?.Name === 'running' && i.SecurityGroups?.length === 1 && i.SecurityGroups[0].GroupId === '$edge_sg' &&
      tags['dirextalk-run-id'] === '$run_id' && tags['dirextalk-owner'] === '$owner_id' && tags['dirextalk-generation'] === '$account_generation';
  })()
" >/dev/null || die 'edge instance owner, state, security group, or ownership tags differ'
edge_shape=$(json_get "$edge_json" 'Reservations.0.Instances.0.InstanceId')
[ "$edge_shape" = "$edge_instance_id" ] || die 'edge instance readback changed'
edge_vpc=$(json_get "$edge_json" 'Reservations.0.Instances.0.VpcId')
edge_subnet=$(json_get "$edge_json" 'Reservations.0.Instances.0.SubnetId')
edge_private_ip=$(json_get "$edge_json" 'Reservations.0.Instances.0.PrivateIpAddress')

aws_read --region "$edge_region" ec2 describe-addresses --allocation-ids "$edge_eip_allocation_id" --output json >"$eip_json" || die 'edge EIP read failed'
json_check "$eip_json" "
  (() => {
    const a=data.Addresses?.[0], tags=Object.fromEntries((a?.Tags || []).map(v => [v.Key,v.Value]));
    return data.Addresses?.length === 1 && a.AllocationId === '$edge_eip_allocation_id' && a.InstanceId === '$edge_instance_id' &&
      a.PrivateIpAddress === '$edge_private_ip' && /^eipassoc-[0-9a-f]{8,17}$/.test(a.AssociationId || '') &&
      tags['dirextalk-run-id'] === '$run_id' && tags['dirextalk-owner'] === '$owner_id' && tags['dirextalk-generation'] === '$account_generation';
  })()
" >/dev/null || die 'edge EIP association or ownership tags differ'
edge_public_ip=$(json_get "$eip_json" 'Addresses.0.PublicIp')
edge_eip_association_id=$(json_get "$eip_json" 'Addresses.0.AssociationId')
[ "$(json_get "$edge_json" 'Reservations.0.Instances.0.PublicIpAddress')" = "$edge_public_ip" ] || die 'edge instance public IP differs from its EIP'

# AWS defines supportCode as an opaque support lookup value, not an account or
# instance identifier. Ownership comes from fresh STS plus the exact ARN; the
# protected support code is only compared byte-for-byte with the API readback.
aws_read --region "$s2_region" lightsail get-instance --instance-name "$s2_name" --output json >"$s2_json" \
  || die 'S2 instance read failed'
[ "$(json_get "$s2_json" instance.name)" = "$s2_name" ] && \
  [ "$(json_get "$s2_json" instance.arn)" = "$s2_arn" ] && \
  [ "$(json_get "$s2_json" instance.supportCode)" = "$s2_support_code" ] && \
  [ "$(json_get "$s2_json" instance.location.regionName)" = "$s2_region" ] && \
  [ "$(json_get "$s2_json" instance.resourceType)" = Instance ] && \
  [ "$(json_get "$s2_json" instance.privateIpAddress)" = "$s2_private_ip" ] && \
  [ "$(json_get "$s2_json" instance.publicIpAddress)" = "$s2_public_ip" ] && \
  [ "$(json_get "$s2_json" instance.state.name)" = running ] \
  || die 'S2 immutable identity readback differs'

peered=$(read_single --region "$s2_region" lightsail is-vpc-peered --query isPeered --output text)
case "$peered" in True) peered_json=true ;; False) peered_json=false ;; *) die 'Lightsail peering readback is invalid' ;; esac
case "$route_mode:$peered_json" in
  private:true) [ "$edge_region" = "$s2_region" ] || die 'private mode is cross-region' ; route_ip=$s2_private_ip ; control_ingress=null ;;
  controlled-public:false) route_ip=$s2_public_ip ; control_ingress="{\"source\":\"$edge_public_ip/32\",\"ports\":[10443,11443]}" ;;
  *) die 'route mode differs from the Lightsail peering readback' ;;
esac

s2_vpc_shape=$(read_single --region "$s2_region" ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].[VpcId,OwnerId,State]' --output text)
IFS=$'\t' read -r s2_default_vpc s2_vpc_owner s2_vpc_state extra <<<"$s2_vpc_shape"
[ -z "${extra:-}" ] && [ "$s2_vpc_owner:$s2_vpc_state" = "$account_id:available" ] || die 'Lightsail default VPC readback differs'

aws_read --region "$s2_region" lightsail get-instance-port-states --instance-name "$s2_name" --output json >"$port_states_json" || die 'Lightsail firewall read failed'
if [ "$route_mode" = controlled-public ]; then
  json_check "$port_states_json" "
    (() => {
      const overlap=(p,port) => p.protocol === 'tcp' && p.state === 'open' && p.fromPort <= port && p.toPort >= port;
      const values=(data.portStates || []).filter(p => overlap(p,10443) || overlap(p,11443));
      return values.length === 2 && [10443,11443].every(port => values.some(p => p.fromPort === port && p.toPort === port &&
        JSON.stringify(p.cidrs) === JSON.stringify(['$edge_public_ip/32']) && (p.ipv6Cidrs || []).length === 0 && (p.cidrListAliases || []).length === 0));
    })()
  " >/dev/null || die 'Lightsail controlled-public firewall readback differs'
else
  json_check "$port_states_json" "
    !(data.portStates || []).some(p => p.protocol === 'tcp' && p.state === 'open' &&
      ((p.fromPort <= 10443 && p.toPort >= 10443) || (p.fromPort <= 11443 && p.toPort >= 11443)))
  " >/dev/null || die 'private mode exposes a Cloud Worker listener through Lightsail firewall'
fi

aws_read route53 get-hosted-zone --id "$private_zone_id" --output json >"$private_zone_json" \
  || die 'private hosted zone read failed'
json_check "$private_zone_json" "
  data.HostedZone?.Id === '/hostedzone/$private_zone_id' && data.HostedZone?.Config?.PrivateZone === true &&
  JSON.stringify(data.VPCs || []) === JSON.stringify([{VPCRegion:'$edge_region',VPCId:'$edge_vpc'}])
" >/dev/null || die 'private hosted zone association differs'
aws_read route53 get-hosted-zone --id "$public_zone_id" --output json >"$public_zone_json" \
  || die 'public hosted zone read failed'
json_check "$public_zone_json" "
  data.HostedZone?.Id === '/hostedzone/$public_zone_id' && data.HostedZone?.Config?.PrivateZone === false &&
  (data.VPCs || []).length === 0
" >/dev/null || die 'public hosted zone readback differs'

for zone in "$private_zone_id:private:$private_records_json:$edge_private_ip" "$public_zone_id:public:$public_records_json:$edge_public_ip"; do
  IFS=: read -r zone_id zone_kind records_file address <<<"$zone"
  aws_read route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json >"$records_file" || die "$zone_kind DNS records read failed"
  json_check "$records_file" "
    (() => {
      const expected=['$control_domain.','$relay_domain.','$proxy_domain.'];
      const records=(data.ResourceRecordSets || []).filter(v => expected.includes(v.Name));
      return records.length === 3 && expected.every(name => records.some(v => v.Name === name && v.Type === 'A' &&
        !v.AliasTarget && v.TTL === 60 && JSON.stringify((v.ResourceRecords || []).map(x => x.Value)) === JSON.stringify(['$address'])));
    })()
  " >/dev/null || die "$zone_kind DNS A records differ"
  tags_file=$tmp_dir/$zone_kind-zone-tags.json
  aws_read route53 list-tags-for-resource --resource-type hostedzone --resource-id "$zone_id" --output json >"$tags_file" || die "$zone_kind hosted zone tags read failed"
  json_check "$tags_file" "
    (() => { const t=Object.fromEntries((data.ResourceTagSet?.Tags || []).map(v => [v.Key,v.Value]));
      return t['dirextalk-run-id'] === '$run_id' && t['dirextalk-owner'] === '$owner_id' && t['dirextalk-generation'] === '$account_generation'; })()
  " >/dev/null || die "$zone_kind hosted zone ownership tags differ"
done

aws_read --region "$edge_region" ec2 describe-security-groups --group-ids "$edge_sg" --output json >"$edge_sg_json" || die 'edge security group read failed'
json_check "$edge_sg_json" "
  (() => {
    const g=data.SecurityGroups?.[0], tags=Object.fromEntries((g?.Tags || []).map(v => [v.Key,v.Value]));
    const cidr=(p,proto,port,dst) => p.IpProtocol === proto && p.FromPort === port && p.ToPort === port &&
      JSON.stringify(p.IpRanges || []) === JSON.stringify([{Description:'dirextalk-worker-edge-v3',CidrIp:dst}]) &&
      (p.Ipv6Ranges || []).length === 0 && (p.PrefixListIds || []).length === 0 && (p.UserIdGroupPairs || []).length === 0;
    const ingress=g.IpPermissions?.[0];
    const exactIngress=(g.IpPermissions || []).length === 1 && ingress.IpProtocol === '-1' && ingress.FromPort === undefined && ingress.ToPort === undefined &&
      JSON.stringify(ingress.IpRanges || []) === JSON.stringify([{Description:'dirextalk-worker-edge-v3',CidrIp:'$worker_source_cidr'}]) &&
      (ingress.Ipv6Ranges || []).length === 0 && (ingress.PrefixListIds || []).length === 0 && (ingress.UserIdGroupPairs || []).length === 0;
    return data.SecurityGroups?.length === 1 && g.GroupId === '$edge_sg' && g.OwnerId === '$account_id' && g.VpcId === '$edge_vpc' && exactIngress &&
      (g.IpPermissionsEgress || []).length === 5 &&
      [['tcp',53,'$dns_resolver_cidr'],['udp',53,'$dns_resolver_cidr'],['tcp',443,'0.0.0.0/0'],['tcp',10443,'$route_ip/32'],['tcp',11443,'$route_ip/32']].every(v =>
        g.IpPermissionsEgress.some(p => cidr(p,v[0],v[1],v[2]))) &&
      tags['dirextalk-run-id'] === '$run_id' && tags['dirextalk-owner'] === '$owner_id' && tags['dirextalk-generation'] === '$account_generation';
  })()
" >/dev/null || die 'edge security group rules or ownership tags differ'

control_upstream=$route_ip:10443
relay_upstream=$route_ip:11443
proxy_upstream=127.0.0.1:12443
read_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
evidence_tmp=$tmp_dir/evidence.json
json_build object \
  schema=dirextalk-worker-edge-evidence-v3 run_id="$run_id" account_id="$account_id" owner_id="$owner_id" account_generation="$account_generation" \
  edge_region="$edge_region" route_mode="$route_mode" \
  lightsail.region="$s2_region" lightsail.instance_arn="$s2_arn" lightsail.support_code="$s2_support_code" \
  lightsail.private_ip="$s2_private_ip" lightsail.public_ip="$s2_public_ip" lightsail.default_vpc_id="$s2_default_vpc" \
  lightsail.vpc_peered="$peered_json" lightsail.control_ingress="$control_ingress" \
  edge.owner_account_id="$account_id" edge.region="$edge_region" edge.instance_id="$edge_instance_id" edge.vpc_id="$edge_vpc" edge.subnet_id="$edge_subnet" \
  edge.private_ip="$edge_private_ip" edge.public_ip="$edge_public_ip" edge.eip_allocation_id="$edge_eip_allocation_id" edge.eip_association_id="$edge_eip_association_id" \
  private_dns.hosted_zone_id="$private_zone_id" private_dns.vpc_id="$edge_vpc" private_dns.region="$edge_region" \
  private_dns.records.worker_control="{\"hostname\":\"$control_domain\",\"address\":\"$edge_private_ip\"}" \
  private_dns.records.model_relay="{\"hostname\":\"$relay_domain\",\"address\":\"$edge_private_ip\"}" \
  private_dns.records.outbound_proxy="{\"hostname\":\"$proxy_domain\",\"address\":\"$edge_private_ip\"}" \
  public_dns.hosted_zone_id="$public_zone_id" \
  public_dns.records.worker_control="{\"hostname\":\"$control_domain\",\"address\":\"$edge_public_ip\"}" \
  public_dns.records.model_relay="{\"hostname\":\"$relay_domain\",\"address\":\"$edge_public_ip\"}" \
  public_dns.records.outbound_proxy="{\"hostname\":\"$proxy_domain\",\"address\":\"$edge_public_ip\"}" \
  security.edge_security_group_id="$edge_sg" \
  security.edge_ingress="{\"source_cidr\":\"$worker_source_cidr\",\"ip_protocol\":\"-1\"}" \
  security.edge_to_s2="{\"destination\":\"$route_ip/32\",\"ports\":[10443,11443]}" \
  security.edge_dns_egress="[{\"destination\":\"$dns_resolver_cidr\",\"ports\":[53],\"protocols\":[\"tcp\",\"udp\"]}]" \
  security.edge_https_egress='{"destination":"0.0.0.0/0","ports":[443]}' \
  backends.worker_control="$control_upstream" backends.model_relay="$relay_upstream" backends.outbound_proxy="$proxy_upstream" \
  readback.owner_account_id="$account_id" readback.edge_region="$edge_region" readback.lightsail_region="$s2_region" readback.read_at="$read_at" \
  >"$evidence_tmp" || die 'could not build evidence JSON'
chmod 0600 "$evidence_tmp" || die 'could not protect evidence JSON'
mv -f "$evidence_tmp" "$output" || die 'could not atomically install evidence JSON'
trap - EXIT HUP INT TERM
rm -rf -- "$tmp_dir"
printf '%s\n' "$output"
