#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
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

service_dir="$HOME/.direxio/nodes/root-destroy.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  '{
    region: "us-east-1",
    domain_mode: "user",
    domain: "root-destroy.example.test",
    agent_service_dir: $service_dir,
    agent_service_id: "root-destroy.example.test",
    resources: {
      instance_id: "i-root-destroy",
      eip_id: "eipalloc-root-destroy",
      sg_id: "sg-root-destroy",
      key_name: "direxio-root-destroy"
    }
  }' > "$state"

calls="$tmp/aws.calls"
: > "$calls"
set +e
CALLS="$calls" PATH="$fakebin:$PATH" bash "$ROOT/scripts/destroy.sh" "$state" > "$tmp/destroy.out" 2>&1
destroy_rc=$?
set -e

[ "$destroy_rc" -ne 0 ] || {
  echo "destroy must fail closed when AWS identity is root" >&2
  cat "$tmp/destroy.out" >&2
  exit 1
}
grep -q 'Root AWS access keys are not allowed' "$tmp/destroy.out"

if grep -E 'ec2 terminate-instances|ec2 release-address|ec2 delete-security-group|ec2 delete-key-pair|route53 change-resource-record-sets' "$calls" >/dev/null; then
  echo "destroy must not mutate AWS resources with a root identity" >&2
  cat "$calls" >&2
  exit 1
fi

if [ ! -d "$service_dir" ]; then
  echo "destroy must not remove local service state when root identity is rejected" >&2
  exit 1
fi

echo "destroy root identity ok"
