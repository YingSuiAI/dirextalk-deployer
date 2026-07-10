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
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_KEEP_WORKDIR=1

service_dir="$HOME/.dirextalk/nodes/lightsail.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
key_file="$service_dir/dirextalk-key.pem"
printf 'PRIVATE_KEY' > "$key_file"
json_build object \
  domain=lightsail.example.test \
  cloud_provider=lightsail \
  domain_mode=user \
  region=us-east-1 \
  agent_service_id=lightsail.example.test \
  "agent_service_dir=$service_dir" \
  "resources={\"lightsail_instance_name\":\"dirextalk-lightsail-example-test\",\"lightsail_static_ip_name\":\"dirextalk-ip-lightsail-example-test\",\"public_ip\":\"203.0.113.144\",\"key_name\":\"dirextalk-key-lightsail-example-test\",\"key_file\":\"$key_file\"}" > "$state"

bash "$ROOT/scripts/destroy.sh" "$state" > "$tmp/destroy.out" 2>&1

grep -q 'lightsail detach-static-ip' "$CALLS"
grep -q 'lightsail release-static-ip' "$CALLS"
grep -q 'lightsail delete-instance' "$CALLS"
grep -q 'lightsail delete-key-pair' "$CALLS"
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
json_test_check "$report" "data.destroy.evidence.lightsail_instance.status === 'deleted' && data.destroy.evidence.lightsail_static_ip.status === 'released' && data.destroy.evidence.key_pair.status === 'deleted' && data.billing.destroy_cleanup_status === 'no_recorded_billable_resource_residue'"

echo "destroy lightsail ok"
