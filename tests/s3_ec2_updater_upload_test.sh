#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/tests/lib/json_test.sh"
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
: > "$CALLS"

cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
case "${1:-} ${2:-}" in
  "ec2 create-key-pair") printf 'test-private-key\n' ;;
  "ec2 create-security-group") printf 'sg-test\n' ;;
  "ec2 authorize-security-group-ingress"|"ec2 wait") ;;
  "ec2 associate-address") touch "$EC2_ATTACHED" ;;
  "ec2 run-instances") printf 'i-test\n' ;;
  "ec2 describe-instances") printf 'vol-root-test\n' ;;
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
printf 'v1.0.6\t586f5ee82f1697269cfd764545198d88707734b8\tfc25f8ff811313dfc18c2b4e0f01b46802697385b24395f9c78e634e5ac426e4\n'
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
state_set_raw server_release '{"source":"github_release","version":"v1.1.0","image":"dirextalk/message-server:v1.1.0","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_ref":"dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifest_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
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
json_test_check "$STATE_JSON" "data.cloud_provider === 'ec2' && data.phases.S3_PROVISION.status === 'done' && data.resources.eip_id === 'eipalloc-test' && data.resources.public_ip === '203.0.113.155' && data.server_release.digest === 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' && data.updater_release.version === 'v1.0.6' && data.updater_release.commit === '586f5ee82f1697269cfd764545198d88707734b8' && data.updater_release.sha256 === 'fc25f8ff811313dfc18c2b4e0f01b46802697385b24395f9c78e634e5ac426e4'"
if grep -q '^scp-called$\|^scp ' "$CALLS"; then
  echo "S3 must not SCP updater artifacts" >&2
  cat "$CALLS" >&2
  exit 1
fi
grep -q '^ssh .*ubuntu@203\.0\.113\.155.*tar.*reconcile-host\.sh.*203\.0\.113\.155' "$CALLS"
address_line=$(grep -n '^aws ec2 describe-addresses' "$CALLS" | cut -d: -f1 | head -n1)
upload_line=$(grep -n '^ssh ' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^dns-check ' "$CALLS" | cut -d: -f1 | head -n1)
[ "$address_line" -lt "$upload_line" ] && [ "$upload_line" -lt "$dns_line" ] || {
  echo "EC2 bootstrap resume must use the EIP and complete before DNS gating" >&2
  cat "$CALLS" >&2
  exit 1
}

echo "s3 EC2 updater upload ok"
