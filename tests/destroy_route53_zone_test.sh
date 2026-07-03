#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
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
      *"--query Arn"*) printf 'arn:aws:iam::123456789012:user/DirextalkDeployer-Test\n' ;;
      *"--query Account"*) printf '123456789012\n' ;;
      *) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/DirextalkDeployer-Test"}\n' ;;
    esac
    ;;
  "route53 list-hosted-zones")
    printf '{"HostedZones":[{"Id":"/hostedzone/ZCREATE","Name":"route53-destroy.example.test."}]}\n'
    ;;
  "route53 change-resource-record-sets")
    exit 0
    ;;
  "route53 delete-hosted-zone")
    exit 0
    ;;
  "ec2 terminate-instances"|"ec2 wait"|"ec2 release-address"|"ec2 delete-security-group"|"ec2 delete-key-pair")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 700 "$fakebin/aws"

service_dir="$HOME/.dirextalk/nodes/route53-destroy.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
json_build object \
  region=us-east-1 \
  domain_mode=route53 \
  domain=route53-destroy.example.test \
  "agent_service_dir=$service_dir" \
  'resources={"public_ip":"203.0.113.99","route53_zone_id":"ZCREATE","route53_zone_name":"route53-destroy.example.test","route53_zone_created_by_deployer":"true"}' > "$state"

calls="$tmp/aws.calls"
CALLS="$calls" PATH="$fakebin:$PATH" bash "$ROOT/scripts/destroy.sh" "$state" >/dev/null

grep -q '^aws route53 change-resource-record-sets --hosted-zone-id ZCREATE' "$calls" || {
  echo "destroy should delete the Route53 A record from the recorded zone" >&2
  cat "$calls" >&2
  exit 1
}

grep -q '^aws route53 delete-hosted-zone --id ZCREATE$' "$calls" || {
  echo "destroy should delete a deployer-created hosted zone to stop Route53 hosted-zone billing" >&2
  cat "$calls" >&2
  exit 1
}

echo "destroy route53 zone ok"
