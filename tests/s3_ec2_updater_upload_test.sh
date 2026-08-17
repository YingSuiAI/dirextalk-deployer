#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/tests/lib/json_test.sh"
source "$ROOT/tests/lib/split-release.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_WORKDIR="$tmp/work"
export CALLS="$tmp/calls"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_CLOUD_PROVIDER=ec2
export INSTANCE_TYPE=t3.small
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
printf 'fixture-host-key\n' >"$DIREXTALK_WORKDIR/known_hosts"
dirextalk_test_prepare_split_release "$tmp"
: > "$CALLS"

cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
case "${1:-} ${2:-}" in
  "sts get-caller-identity") printf '123456789012\n' ;;
  "ec2 create-key-pair") printf 'test-private-key\n' ;;
  "ec2 create-security-group") printf 'sg-test\n' ;;
  "ec2 authorize-security-group-ingress"|"ec2 wait") ;;
  "ec2 associate-address") touch "$EC2_ATTACHED" ;;
  "ec2 run-instances") printf 'i-test\n' ;;
  "ec2 describe-instances")
    case "$*" in
      *Reservations*OwnerId*) printf '123456789012\ti-test\t203.0.113.155\n' ;;
      *) printf 'vol-root-test\n' ;;
    esac ;;
  "ec2 allocate-address") printf 'eipalloc-test\n' ;;
  "ec2 describe-addresses")
    case "$*" in
      *InstanceId*) [ -f "$EC2_ATTACHED" ] && printf 'i-test\n' || printf 'None\n' ;;
      *PublicIp*) printf '203.0.113.155\n' ;;
    esac ;;
  *) echo "unexpected aws command: $*" >&2; exit 1 ;;
esac
EOF
cat > "$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp-called\n' >> "$CALLS"
exit 97
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
cat >/dev/null
case "${!#}" in
  *'/etc/machine-id'*) printf '0123456789abcdef0123456789abcdef\tDOCKERENGINE1234\n' ;;
  *) printf 'v1.0.16\t2c23d1bba8d29449f6952624bc39ad991dd31e02\teb5fe3f84ff53cf0c7207198fd4a134b31960d0fc1d000b86e702682e4ffe3bf\n' ;;
esac
EOF
chmod 0700 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export EC2_ATTACHED="$tmp/ec2.attached"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region us-east-1
state_set domain ec2.example.test
state_set domain_mode user
res_set ami_id ami-test
res_set vpc_id vpc-test

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"
domain_resolves_to_ip() {
  printf 'dns-check %s %s\n' "$1" "$2" >> "$CALLS"
  return 0
}

run_phase > "$tmp/s3.out" 2>&1 || { cat "$tmp/s3.out" >&2; exit 1; }
json_test_check "$STATE_JSON" "data.deployment_layout === 'split-agent' && data.cloud_provider === 'ec2' && data.phases.S3_PROVISION.status === 'done' && data.resources.eip_id === 'eipalloc-test' && data.resources.public_ip === '203.0.113.155' && data.resources.root_volume_id === 'vol-root-test' && data.server_release.source === 'production_split' && data.server_release.version === '$DIREXTALK_MESSAGE_SERVER_VERSION' && data.server_release.image_ref === '$DIREXTALK_MESSAGE_SERVER_IMAGE' && data.updater_release.version === 'v1.0.16' && data.updater_release.commit === '2c23d1bba8d29449f6952624bc39ad991dd31e02' && data.updater_release.sha256 === 'eb5fe3f84ff53cf0c7207198fd4a134b31960d0fc1d000b86e702682e4ffe3bf' && data.node_identity.aws_account_id === '123456789012' && data.node_identity.provider_instance_id === 'i-test' && data.node_identity.provider_instance_arn === 'arn:aws:ec2:us-east-1:123456789012:instance/i-test' && data.node_identity.machine_id === '0123456789abcdef0123456789abcdef'" || { cat "$STATE_JSON" >&2; exit 1; }
if grep -q '^scp-called$\|^scp ' "$CALLS"; then
  echo "S3 must not SCP updater artifacts" >&2
  cat "$CALLS" >&2
  exit 1
fi
grep -q '^ssh .*ubuntu@203\.0\.113\.155.*tar.*apply-host-integration\.sh.*203\.0\.113\.155' "$CALLS"
grep -q '^ssh .*bootstrap-host\.sh.*--record-stable-ip.*203\.0\.113\.155.*apply-host-integration\.sh' "$CALLS"
grep -q '^ssh .*apply-host-integration\.sh.*cloud-init.*status.*--wait.*printf' "$CALLS"
grep -q -- '--no-same-owner' "$CALLS"
grep -q 'authorize-security-group-ingress .*--protocol tcp --port 3478 --cidr 0.0.0.0/0' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'authorize-security-group-ingress .*--protocol udp --port 3478 --cidr 0.0.0.0/0' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'authorize-security-group-ingress .*--protocol udp --port 49160-49200 --cidr 0.0.0.0/0' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
address_line=$(grep -n '^aws ec2 describe-addresses' "$CALLS" | cut -d: -f1 | head -n1)
upload_line=$(grep -n '^ssh ' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^dns-check ' "$CALLS" | cut -d: -f1 | head -n1)
[ "$address_line" -lt "$upload_line" ] && [ "$upload_line" -lt "$dns_line" ] || {
  echo "EC2 bootstrap resume must use the EIP and complete before DNS gating" >&2
  cat "$CALLS" >&2
  exit 1
}

echo "s3 EC2 updater upload ok"
