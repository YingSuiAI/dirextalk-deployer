#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
source "$ROOT/scripts/lib/json.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
renderer=$ROOT/scripts/cloud-init/split/render-worker-edge.sh
output=$TEST_TMP/WorkerEdge.haproxy.cfg
export DIREXTALK_WORKER_EDGE_OWNER_ID=@owner:example.test
export DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION=7
write_evidence() {
  local file=$1 mode=$2 peered=$3 edge_region=$4 listen_ip=$5 route_ip=$6 control_ingress=$7
  cat >"$file" <<EOF
{"schema":"dirextalk-worker-edge-evidence-v2","run_id":"run-worker-edge","account_id":"123456789012","owner_id":"@owner:example.test","account_generation":"7","edge_region":"$edge_region","route_mode":"$mode","lightsail":{"region":"ap-east-1","instance_arn":"arn:aws:lightsail:ap-east-1:123456789012:Instance/00000000-0000-4000-8000-000000000001","support_code":"123456789012/i-0123456789abcdef0","private_ip":"10.20.0.10","public_ip":"43.199.101.138","default_vpc_id":"vpc-0123456789abcdef0","vpc_peered":$peered,"control_ingress":$control_ingress},"edge":{"owner_account_id":"123456789012","region":"$edge_region","instance_id":"i-0123456789abcdef0","vpc_id":"vpc-1123456789abcdef0","subnet_id":"subnet-0123456789abcdef0","private_ip":"$listen_ip","public_ip":"18.180.1.2","eip_allocation_id":"eipalloc-0123456789abcdef0","eip_association_id":"eipassoc-0123456789abcdef0"},"private_dns":{"hosted_zone_id":"ZPRIVATE123","vpc_id":"vpc-1123456789abcdef0","region":"$edge_region","records":{"worker_control":{"hostname":"worker-control.example.test","address":"$listen_ip"},"model_relay":{"hostname":"model-relay.example.test","address":"$listen_ip"},"outbound_proxy":{"hostname":"worker-proxy.example.test","address":"$listen_ip"}}},"public_dns":{"hosted_zone_id":"ZPUBLIC123","records":{"worker_control":{"hostname":"worker-control.example.test","address":"18.180.1.2"},"model_relay":{"hostname":"model-relay.example.test","address":"18.180.1.2"},"outbound_proxy":{"hostname":"worker-proxy.example.test","address":"18.180.1.2"}}},"security":{"worker_security_group_id":"sg-0123456789abcdef0","edge_security_group_id":"sg-1123456789abcdef0","worker_dns_egress":[{"destination":"10.0.0.2/32","ports":[53],"protocols":["tcp","udp"]}],"worker_edge_egress":{"destination":"$listen_ip/32","ports":[443]},"edge_ingress":{"source_security_group_id":"sg-0123456789abcdef0","ports":[443]},"edge_to_s2":{"destination":"$route_ip/32","ports":[10443,11443]},"edge_dns_egress":[{"destination":"10.0.0.2/32","ports":[53],"protocols":["tcp","udp"]}],"edge_https_egress":{"destination":"0.0.0.0/0","ports":[443]}},"backends":{"worker_control":"$route_ip:10443","model_relay":"$route_ip:11443","outbound_proxy":"127.0.0.1:12443"},"readback":{"owner_account_id":"123456789012","edge_region":"$edge_region","lightsail_region":"ap-east-1"}}
EOF
  chmod 0600 "$file"
}

controlled_evidence=$TEST_TMP/controlled-evidence.json
write_evidence "$controlled_evidence" controlled-public false ap-northeast-1 10.30.0.20 43.199.101.138 '{"source":"18.180.1.2/32","ports":[10443,11443]}'

render_controlled_public() {
  DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=43.199.101.138:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=43.199.101.138:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
  DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_REGION=ap-northeast-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.30.0.20 \
  DIREXTALK_WORKER_EDGE_EVIDENCE_FILE="$controlled_evidence" \
    bash "$renderer" "$1"
}

render_controlled_public "$output"
[ "$(stat -c '%a' "$output")" = 444 ]
for expected in \
  'bind 10.30.0.20:443' \
  'acl worker_control req.ssl_sni -i worker-control.example.test' \
  'server worker_control 43.199.101.138:10443' \
  'acl model_relay req.ssl_sni -i model-relay.example.test' \
  'server model_relay 43.199.101.138:11443' \
  'acl outbound_proxy req.ssl_sni -i worker-proxy.example.test' \
  'server outbound_proxy 127.0.0.1:12443' \
  'tcp-request content reject unless worker_control or model_relay or outbound_proxy'; do
  grep -Fq "$expected" "$output"
done
grep -Fq '# deployment_region=ap-northeast-1' "$output"
grep -Fq '# s2_region=ap-east-1' "$output"
grep -Fq '# route_mode=controlled-public' "$output"
! grep -Eq '__DIREXTALK_[A-Z0-9_]+__' "$output"

if DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=43.199.101.139:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=43.199.101.138:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
  DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_REGION=ap-northeast-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.30.0.20 \
  DIREXTALK_WORKER_EDGE_EVIDENCE_FILE="$controlled_evidence" \
    bash "$renderer" "$TEST_TMP/drifted-backend" >/dev/null 2>&1; then
  echo 'renderer accepted a WorkerControl backend outside the read-back S2 route address' >&2
  exit 1
fi

if DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=43.199.101.138:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=43.199.101.138:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=10.20.0.30:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
  DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_REGION=ap-northeast-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.30.0.20 \
  DIREXTALK_WORKER_EDGE_EVIDENCE_FILE="$controlled_evidence" \
    bash "$renderer" "$TEST_TMP/remote-proxy" >/dev/null 2>&1; then
  echo 'renderer accepted a non-loopback controlled proxy' >&2
  exit 1
fi

if DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=10.20.0.10:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=10.20.0.10:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
  DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=private \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.20.0.20 \
  DIREXTALK_WORKER_EDGE_LIGHTSAIL_VPC_PEERED=true \
    bash "$renderer" "$TEST_TMP/incomplete-private" >/dev/null 2>&1; then
  echo 'renderer accepted private mode without all read-back proofs' >&2
  exit 1
fi

private_output=$TEST_TMP/private.cfg
private_evidence=$TEST_TMP/private-evidence.json
write_evidence "$private_evidence" private true ap-east-1 10.20.0.20 10.20.0.10 null
DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
DIREXTALK_WORKER_CONTROL_UPSTREAM=10.20.0.10:10443 \
DIREXTALK_MODEL_RELAY_UPSTREAM=10.20.0.10:11443 \
DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 \
DIREXTALK_WORKER_EDGE_REGION=ap-east-1 \
DIREXTALK_WORKER_EDGE_ROUTE_MODE=private \
DIREXTALK_WORKER_EDGE_LISTEN_IP=10.20.0.20 \
DIREXTALK_WORKER_EDGE_LIGHTSAIL_VPC_PEERED=true \
DIREXTALK_WORKER_EDGE_EVIDENCE_FILE="$private_evidence" \
  bash "$renderer" "$private_output"
grep -Fq '# route_mode=private' "$private_output"
grep -Fq '# account_id=123456789012' "$private_output"
grep -Fq '# edge_instance_id=i-0123456789abcdef0' "$private_output"

grep -Fq 'image: ${DIREXTALK_WORKER_EDGE_HAPROXY_IMAGE_IMMUTABLE:?set an immutable official HAProxy Alpine image reference}' \
  "$ROOT/scripts/cloud-init/split/worker-edge-compose.yaml"
grep -Fq 'network_mode: host' "$ROOT/scripts/cloud-init/split/worker-edge-compose.yaml"
grep -Fq 'worker-controlled-proxy:' "$ROOT/scripts/cloud-init/split/worker-edge-compose.yaml"
grep -Fq 'DIREXTALK_WORKER_EDGE_PROXY_IMAGE_IMMUTABLE' "$ROOT/scripts/cloud-init/split/worker-edge-compose.yaml"
grep -Fq 'DIREXTALK_WORKER_EDGE_SQUID_CONFIG' "$ROOT/scripts/cloud-init/split/worker-edge-compose.yaml"

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
case "$args" in
  *' sts get-caller-identity '*) printf '%s\n' 123456789012 ;;
  *' ec2 describe-instances '*)
    cat <<'JSON'
{"Reservations":[{"OwnerId":"123456789012","Instances":[{"InstanceId":"i-0123456789abcdef0","State":{"Name":"running"},"VpcId":"vpc-1123456789abcdef0","SubnetId":"subnet-0123456789abcdef0","PrivateIpAddress":"10.30.0.20","PublicIpAddress":"18.180.1.2","SecurityGroups":[{"GroupId":"sg-1123456789abcdef0","GroupName":"edge"}],"Tags":[{"Key":"dirextalk-run-id","Value":"run-worker-edge"},{"Key":"dirextalk-owner","Value":"@owner:example.test"},{"Key":"dirextalk-generation","Value":"7"}]}]}]}
JSON
    ;;
  *' ec2 describe-addresses '*)
    cat <<'JSON'
{"Addresses":[{"AllocationId":"eipalloc-0123456789abcdef0","AssociationId":"eipassoc-0123456789abcdef0","InstanceId":"i-0123456789abcdef0","PrivateIpAddress":"10.30.0.20","PublicIp":"18.180.1.2","Domain":"vpc","Tags":[{"Key":"dirextalk-run-id","Value":"run-worker-edge"},{"Key":"dirextalk-owner","Value":"@owner:example.test"},{"Key":"dirextalk-generation","Value":"7"}]}]}
JSON
    ;;
  *' lightsail get-instance '*) printf '%s\t%s\t%s\t%s\t%s\n' 'arn:aws:lightsail:ap-east-1:123456789012:Instance/00000000-0000-4000-8000-000000000001' '123456789012/i-0123456789abcdef0' '10.20.0.10' '43.199.101.138' running ;;
  *' lightsail is-vpc-peered '*) printf '%s\n' False ;;
  *' ec2 describe-vpcs '*) printf '%s\t%s\t%s\n' vpc-0123456789abcdef0 123456789012 available ;;
  *' lightsail get-instance-port-states '*)
    if [ "${AWS_MOCK_BAD_FIREWALL:-false}" = true ]; then cidr=203.0.113.1/32; else cidr=18.180.1.2/32; fi
    printf '{"portStates":[{"fromPort":10443,"toPort":10443,"protocol":"tcp","state":"open","cidrs":["%s"],"ipv6Cidrs":[],"cidrListAliases":[]},{"fromPort":11443,"toPort":11443,"protocol":"tcp","state":"open","cidrs":["%s"],"ipv6Cidrs":[],"cidrListAliases":[]}]}\n' "$cidr" "$cidr"
    ;;
  *' route53 get-hosted-zone '*ZPRIVATE123*) printf '/hostedzone/ZPRIVATE123\ttrue\t1\tvpc-1123456789abcdef0\tap-northeast-1\n' ;;
  *' route53 get-hosted-zone '*ZPUBLIC123*) printf '/hostedzone/ZPUBLIC123\tfalse\t0\n' ;;
  *' route53 list-resource-record-sets '*ZPRIVATE123*) address=10.30.0.20; printf '{"ResourceRecordSets":[{"Name":"worker-control.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"%s"}]},{"Name":"model-relay.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"%s"}]},{"Name":"worker-proxy.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"%s"}]}]}\n' "$address" "$address" "$address" ;;
  *' route53 list-resource-record-sets '*ZPUBLIC123*) address=18.180.1.2; printf '{"ResourceRecordSets":[{"Name":"worker-control.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"%s"}]},{"Name":"model-relay.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"%s"}]},{"Name":"worker-proxy.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"%s"}]}]}\n' "$address" "$address" "$address" ;;
  *' route53 list-tags-for-resource '*)
    printf '%s\n' '{"ResourceTagSet":{"Tags":[{"Key":"dirextalk-run-id","Value":"run-worker-edge"},{"Key":"dirextalk-owner","Value":"@owner:example.test"},{"Key":"dirextalk-generation","Value":"7"}]}}'
    ;;
  *' ec2 describe-security-groups '*sg-0123456789abcdef0*)
    cat <<'JSON'
{"SecurityGroups":[{"GroupId":"sg-0123456789abcdef0","OwnerId":"123456789012","VpcId":"vpc-1123456789abcdef0","IpPermissions":[],"IpPermissionsEgress":[{"IpProtocol":"tcp","FromPort":53,"ToPort":53,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"10.30.0.2/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"udp","FromPort":53,"ToPort":53,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"10.30.0.2/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"10.30.0.20/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]}],"Tags":[{"Key":"dirextalk-run-id","Value":"run-worker-edge"},{"Key":"dirextalk-owner","Value":"@owner:example.test"},{"Key":"dirextalk-generation","Value":"7"}]}]}
JSON
    ;;
  *' ec2 describe-security-groups '*sg-1123456789abcdef0*)
    cat <<'JSON'
{"SecurityGroups":[{"GroupId":"sg-1123456789abcdef0","OwnerId":"123456789012","VpcId":"vpc-1123456789abcdef0","IpPermissions":[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[{"Description":"dirextalk-worker-edge-v2","UserId":"123456789012","GroupId":"sg-0123456789abcdef0"}]}],"IpPermissionsEgress":[{"IpProtocol":"tcp","FromPort":53,"ToPort":53,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"10.30.0.2/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"udp","FromPort":53,"ToPort":53,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"10.30.0.2/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"0.0.0.0/0"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"tcp","FromPort":10443,"ToPort":10443,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"43.199.101.138/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"tcp","FromPort":11443,"ToPort":11443,"IpRanges":[{"Description":"dirextalk-worker-edge-v2","CidrIp":"43.199.101.138/32"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]}],"Tags":[{"Key":"dirextalk-run-id","Value":"run-worker-edge"},{"Key":"dirextalk-owner","Value":"@owner:example.test"},{"Key":"dirextalk-generation","Value":"7"}]}]}
JSON
    ;;
  *) printf 'unexpected aws invocation: %s\n' "$*" >&2; exit 99 ;;
esac
EOF
chmod 0755 "$TEST_TMP/bin/aws"

reader=$ROOT/scripts/cloud-init/split/read-worker-edge-evidence.sh
reader_evidence=$TEST_TMP/reader-evidence.json
PATH="$TEST_TMP/bin:$PATH" \
DIREXTALK_WORKER_EDGE_RUN_ID=run-worker-edge \
DIREXTALK_WORKER_EDGE_ACCOUNT_ID=123456789012 \
DIREXTALK_WORKER_EDGE_OWNER_ID=@owner:example.test \
DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION=7 \
DIREXTALK_WORKER_EDGE_REGION=ap-northeast-1 \
DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 \
DIREXTALK_WORKER_EDGE_S2_INSTANCE_NAME=dirextalk-s2 \
DIREXTALK_WORKER_EDGE_S2_INSTANCE_ARN=arn:aws:lightsail:ap-east-1:123456789012:Instance/00000000-0000-4000-8000-000000000001 \
DIREXTALK_WORKER_EDGE_S2_SUPPORT_CODE=123456789012/i-0123456789abcdef0 \
DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
DIREXTALK_WORKER_EDGE_INSTANCE_ID=i-0123456789abcdef0 \
DIREXTALK_WORKER_EDGE_EIP_ALLOCATION_ID=eipalloc-0123456789abcdef0 \
DIREXTALK_WORKER_EDGE_PRIVATE_HOSTED_ZONE_ID=ZPRIVATE123 \
DIREXTALK_WORKER_EDGE_PUBLIC_HOSTED_ZONE_ID=ZPUBLIC123 \
DIREXTALK_WORKER_SECURITY_GROUP_ID=sg-0123456789abcdef0 \
DIREXTALK_WORKER_EDGE_SECURITY_GROUP_ID=sg-1123456789abcdef0 \
DIREXTALK_WORKER_EDGE_DNS_RESOLVER_CIDR=10.30.0.2/32 \
DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  bash "$reader" "$reader_evidence" >/dev/null
[ "$(stat -c '%a' "$reader_evidence")" = 600 ]
json_check "$reader_evidence" "data.schema === 'dirextalk-worker-edge-evidence-v2' && data.account_generation === 7 && data.edge.public_ip === '18.180.1.2' && data.lightsail.control_ingress.source === '18.180.1.2/32'"

if PATH="$TEST_TMP/bin:$PATH" AWS_MOCK_BAD_FIREWALL=true \
DIREXTALK_WORKER_EDGE_RUN_ID=run-worker-edge DIREXTALK_WORKER_EDGE_ACCOUNT_ID=123456789012 \
DIREXTALK_WORKER_EDGE_OWNER_ID=@owner:example.test DIREXTALK_WORKER_EDGE_ACCOUNT_GENERATION=7 \
DIREXTALK_WORKER_EDGE_REGION=ap-northeast-1 DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
DIREXTALK_WORKER_EDGE_S2_REGION=ap-east-1 DIREXTALK_WORKER_EDGE_S2_INSTANCE_NAME=dirextalk-s2 \
DIREXTALK_WORKER_EDGE_S2_INSTANCE_ARN=arn:aws:lightsail:ap-east-1:123456789012:Instance/00000000-0000-4000-8000-000000000001 \
DIREXTALK_WORKER_EDGE_S2_SUPPORT_CODE=123456789012/i-0123456789abcdef0 \
DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 DIREXTALK_WORKER_EDGE_S2_PUBLIC_IP=43.199.101.138 \
DIREXTALK_WORKER_EDGE_INSTANCE_ID=i-0123456789abcdef0 DIREXTALK_WORKER_EDGE_EIP_ALLOCATION_ID=eipalloc-0123456789abcdef0 \
DIREXTALK_WORKER_EDGE_PRIVATE_HOSTED_ZONE_ID=ZPRIVATE123 DIREXTALK_WORKER_EDGE_PUBLIC_HOSTED_ZONE_ID=ZPUBLIC123 \
DIREXTALK_WORKER_SECURITY_GROUP_ID=sg-0123456789abcdef0 DIREXTALK_WORKER_EDGE_SECURITY_GROUP_ID=sg-1123456789abcdef0 \
DIREXTALK_WORKER_EDGE_DNS_RESOLVER_CIDR=10.30.0.2/32 DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  bash "$reader" "$TEST_TMP/bad-firewall-evidence.json" >/dev/null 2>&1; then
  echo 'evidence reader accepted a different Lightsail firewall source' >&2
  exit 1
fi

cat >"$TEST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'image inspect') exit 0 ;;
  'run --rm') exit 0 ;;
  *) exit 99 ;;
esac
EOF
chmod 0755 "$TEST_TMP/bin/docker"
image=docker.io/library/haproxy:3.2-alpine@sha256:$(printf 'b%.0s' {1..64})
PATH="$TEST_TMP/bin:$PATH" bash "$ROOT/scripts/cloud-init/split/verify-worker-edge-image.sh" "$image" "$output" \
  | grep -Fq "worker edge image verified: image=$image"

echo 'worker edge render ok'
