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
    case "$*" in
      *"--query Arn"*) printf 'arn:aws:iam::123456789012:root\n' ;;
      *"--query Account"*) printf '123456789012\n' ;;
      *) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:root"}\n' ;;
    esac
    ;;
  "ec2 terminate-instances"|"ec2 release-address"|"ec2 delete-security-group"|"ec2 delete-key-pair"|"route53 change-resource-record-sets")
    exit 0
    ;;
  *)
    exit 0
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
EOF
chmod 700 "$fakebin/ssh"

service_dir="$HOME/.dirextalk/nodes/root-destroy.example.test"
mkdir -p "$service_dir"
key_file="$tmp/root-destroy.pem"
touch "$key_file"
state="$service_dir/state.json"
json_build object \
  region=us-east-1 \
  domain_mode=user \
  domain=root-destroy.example.test \
  "agent_service_dir=$service_dir" \
  agent_service_id=root-destroy.example.test \
  "resources={\"instance_id\":\"i-root-destroy\",\"eip_id\":\"eipalloc-root-destroy\",\"sg_id\":\"sg-root-destroy\",\"key_name\":\"dirextalk-root-destroy\",\"key_file\":\"$key_file\",\"public_ip\":\"203.0.113.77\"}" > "$state"

calls="$tmp/aws.calls"
: > "$calls"
set +e
CALLS="$calls" PATH="$fakebin:$PATH" bash "$ROOT/scripts/destroy.sh" "$state" > "$tmp/destroy.out" 2>&1
destroy_rc=$?
set -e

[ "$destroy_rc" -eq 0 ] || {
  echo "destroy must allow root identity when the operator chose root credentials" >&2
  cat "$tmp/destroy.out" >&2
  exit 1
}
grep -q 'source = ' "$tmp/destroy.out"

for expected in 'ec2 terminate-instances' 'ec2 release-address' 'ec2 delete-security-group' 'ec2 delete-key-pair'; do
  if ! grep -F "$expected" "$calls" >/dev/null; then
    echo "destroy should process recorded AWS resource with root identity: $expected" >&2
    cat "$calls" >&2
    exit 1
  fi
done

for expected in 'base64.*--decode' 'install.*set-desired-state' 'set-desired-state\.sh.*deprovisioned'; do
  if ! grep -E "$expected" "$calls" >/dev/null; then
    echo "destroy should suppress the remote watchdog before cloud termination: $expected" >&2
    cat "$calls" >&2
    exit 1
  fi
done

if grep -F 'route53 change-resource-record-sets' "$calls" >/dev/null; then
  echo "destroy should not touch Route53 for DOMAIN_MODE=user" >&2
  cat "$calls" >&2
  exit 1
fi

if [ -d "$service_dir" ]; then
  echo "destroy should remove local service state after processing resources" >&2
  exit 1
fi

echo "destroy root identity allowed ok"
