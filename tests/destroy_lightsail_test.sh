#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    printf 'arn:aws:iam::123456789012:user/DirextalkDeployer\n'
    ;;
  "lightsail detach-static-ip"|"lightsail release-static-ip"|"lightsail delete-instance"|"lightsail delete-key-pair")
    ;;
  "lightsail get-static-ip"|"lightsail get-instance"|"lightsail get-key-pair")
    exit 255
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fakebin/aws"
cat > "$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
cat >/dev/null
EOF
chmod 700 "$fakebin/ssh"
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_KEEP_WORKDIR=1

service_dir="$HOME/.dirextalk/nodes/lightsail.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
key_file="$service_dir/dirextalk-key.pem"
known_hosts="$service_dir/known_hosts"
printf 'PRIVATE_KEY' > "$key_file"
printf '203.0.113.144 ssh-ed25519 test-host-key\n' > "$known_hosts"
json_build object \
  domain=lightsail.example.test \
  cloud_provider=lightsail \
  domain_mode=user \
  region=us-east-1 \
  agent_service_id=lightsail.example.test \
  "agent_service_dir=$service_dir" \
  'agent_release={"enabled":true}' \
  "resources={\"lightsail_instance_name\":\"dirextalk-lightsail-example-test\",\"lightsail_static_ip_name\":\"dirextalk-ip-lightsail-example-test\",\"public_ip\":\"203.0.113.144\",\"key_name\":\"dirextalk-key-lightsail-example-test\",\"key_file\":\"$key_file\",\"lightsail_ssh_known_hosts\":\"$known_hosts\"}" > "$state"

bash "$ROOT/scripts/destroy.sh" "$state" > "$tmp/destroy.out" 2>&1

grep -q 'lightsail detach-static-ip' "$CALLS"
grep -q 'lightsail release-static-ip' "$CALLS"
grep -q 'lightsail delete-instance' "$CALLS"
grep -q 'lightsail delete-key-pair' "$CALLS"
grep -q '^ssh .*StrictHostKeyChecking=yes.*UserKnownHostsFile=' "$CALLS" || {
  echo "mounted Agent secret cleanup must require the pinned SSH host key" >&2
  cat "$CALLS" >&2
  exit 1
}
grep -q 'mounted-secrets' "$CALLS" || {
  echo "mounted Agent secret cleanup must target the private mounted-secrets directory" >&2
  cat "$CALLS" >&2
  exit 1
}
if grep -q '^aws ec2 ' "$CALLS"; then
  echo "Lightsail destroy must not call EC2 APIs" >&2
  cat "$CALLS" >&2
  exit 1
fi
report=$(find "$HOME/.dirextalk/reports" -name operation-report.json -print | head -n 1)
[ -s "$report" ] || {
  echo "destroy report not found" >&2
  cat "$tmp/destroy.out" >&2
  exit 1
}
json_test_check "$report" "data.destroy.evidence.lightsail_instance.status === 'deleted' && data.destroy.evidence.lightsail_static_ip.status === 'released' && data.destroy.evidence.key_pair.status === 'deleted' && data.destroy.evidence.agent_mounted_secrets.status === 'cleared' && data.billing.destroy_cleanup_status === 'no_recorded_billable_resource_residue'"

no_pin_service="$HOME/.dirextalk/nodes/lightsail-no-pin.example.test"
mkdir -p "$no_pin_service"
no_pin_state="$no_pin_service/state.json"
no_pin_key="$no_pin_service/dirextalk-key.pem"
printf 'PRIVATE_KEY' > "$no_pin_key"
json_build object \
  domain=lightsail-no-pin.example.test \
  cloud_provider=lightsail \
  domain_mode=user \
  region=us-east-1 \
  'agent_release={"enabled":true}' \
  "resources={\"lightsail_instance_name\":\"dirextalk-no-pin-example-test\",\"lightsail_static_ip_name\":\"dirextalk-ip-no-pin-example-test\",\"public_ip\":\"203.0.113.144\",\"key_name\":\"dirextalk-key-no-pin-example-test\",\"key_file\":\"$no_pin_key\"}" > "$no_pin_state"
: > "$CALLS"
bash "$ROOT/scripts/destroy.sh" "$no_pin_state" > "$tmp/destroy-no-pin.out" 2>&1
if grep -q 'mounted-secrets' "$CALLS"; then
  echo "mounted Agent secret cleanup must not enroll or contact an unpinned host" >&2
  cat "$CALLS" >&2
  exit 1
fi

echo "destroy lightsail ok"
