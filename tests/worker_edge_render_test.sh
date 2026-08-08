#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
renderer=$ROOT/scripts/cloud-init/split/render-worker-edge.sh
output=$TEST_TMP/WorkerEdge.haproxy.cfg
write_evidence() {
  local file=$1 mode=$2 peered=$3
  cat >"$file" <<EOF
{"schema":"dirextalk-worker-edge-evidence-v1","run_id":"run-worker-edge","account_id":"123456789012","region":"ap-east-1","route_mode":"$mode","lightsail":{"instance_arn":"arn:aws:lightsail:ap-east-1:123456789012:Instance/00000000-0000-4000-8000-000000000001","private_ip":"10.20.0.10","default_vpc_id":"vpc-0123456789abcdef0","vpc_peered":$peered},"edge":{"instance_id":"i-0123456789abcdef0","private_ip":"10.20.0.20","eip_allocation_id":"eipalloc-0123456789abcdef0"},"private_dns":{"hosted_zone_id":"ZPRIVATE123","records":{"worker_control":{"hostname":"worker-control.example.test","address":"10.20.0.20"},"model_relay":{"hostname":"model-relay.example.test","address":"10.20.0.20"},"outbound_proxy":{"hostname":"worker-proxy.example.test","address":"10.20.0.20"}}},"security":{"worker_security_group_id":"sg-0123456789abcdef0","edge_security_group_id":"sg-1123456789abcdef0","worker_egress":{"destination":"10.20.0.20/32","ports":[443]},"edge_ingress":{"source_security_group_id":"sg-0123456789abcdef0","ports":[443]},"edge_to_s2":{"destination":"10.20.0.10/32","ports":[10443,11443]}},"backends":{"worker_control":"10.20.0.10:10443","model_relay":"10.20.0.10:11443","outbound_proxy":"127.0.0.1:12443"},"readback":{"owner_account_id":"123456789012","region":"ap-east-1"}}
EOF
  chmod 0600 "$file"
}

controlled_evidence=$TEST_TMP/controlled-evidence.json
write_evidence "$controlled_evidence" controlled-public false

render_controlled_public() {
  DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=10.20.0.10:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=10.20.0.10:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.20.0.20 \
  DIREXTALK_WORKER_EDGE_EVIDENCE_FILE="$controlled_evidence" \
    bash "$renderer" "$1"
}

render_controlled_public "$output"
[ "$(stat -c '%a' "$output")" = 444 ]
for expected in \
  'bind 10.20.0.20:443' \
  'acl worker_control req.ssl_sni -i worker-control.example.test' \
  'server worker_control 10.20.0.10:10443' \
  'acl model_relay req.ssl_sni -i model-relay.example.test' \
  'server model_relay 10.20.0.10:11443' \
  'acl outbound_proxy req.ssl_sni -i worker-proxy.example.test' \
  'server outbound_proxy 127.0.0.1:12443' \
  'tcp-request content reject unless worker_control or model_relay or outbound_proxy'; do
  grep -Fq "$expected" "$output"
done
grep -Fq '# deployment_region=ap-east-1' "$output"
grep -Fq '# route_mode=controlled-public' "$output"
! grep -Eq '__DIREXTALK_[A-Z0-9_]+__' "$output"

if DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=10.20.0.11:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=10.20.0.10:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.20.0.20 \
    bash "$renderer" "$TEST_TMP/drifted-backend" >/dev/null 2>&1; then
  echo 'renderer accepted a WorkerControl backend outside the read-back S2 private IP' >&2
  exit 1
fi

if DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
  DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
  DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
  DIREXTALK_WORKER_CONTROL_UPSTREAM=10.20.0.10:10443 \
  DIREXTALK_MODEL_RELAY_UPSTREAM=10.20.0.10:11443 \
  DIREXTALK_OUTBOUND_PROXY_UPSTREAM=10.20.0.30:12443 \
  DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
  DIREXTALK_WORKER_EDGE_REGION=ap-east-1 \
  DIREXTALK_WORKER_EDGE_ROUTE_MODE=controlled-public \
  DIREXTALK_WORKER_EDGE_LISTEN_IP=10.20.0.20 \
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
write_evidence "$private_evidence" private true
DIREXTALK_WORKER_CONTROL_DOMAIN=worker-control.example.test \
DIREXTALK_MODEL_RELAY_DOMAIN=model-relay.example.test \
DIREXTALK_OUTBOUND_PROXY_DOMAIN=worker-proxy.example.test \
DIREXTALK_WORKER_CONTROL_UPSTREAM=10.20.0.10:10443 \
DIREXTALK_MODEL_RELAY_UPSTREAM=10.20.0.10:11443 \
DIREXTALK_OUTBOUND_PROXY_UPSTREAM=127.0.0.1:12443 \
DIREXTALK_WORKER_EDGE_S2_PRIVATE_IP=10.20.0.10 \
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
