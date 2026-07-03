#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

case "${1:-} ${2:-}" in
  "route53 list-hosted-zones")
    printf '{"HostedZones":[]}\n'
    ;;
  "route53 create-hosted-zone")
    printf '{"HostedZone":{"Id":"/hostedzone/ZCREATE","Name":"auto-zone.example.test."},"DelegationSet":{"NameServers":["ns-1.awsdns.test","ns-2.awsdns.test"]}}\n'
    ;;
  "route53 change-resource-record-sets")
    printf '{"ChangeInfo":{"Id":"/change/C123","Status":"PENDING"}}\n'
    ;;
  "route53 wait")
    exit 0
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fakebin/aws"
export CALLS="$tmp/aws.calls"
export PATH="$fakebin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set run_id route53-test
state_set domain auto-zone.example.test
state_set domain_mode route53

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

_upsert_route53_record auto-zone.example.test 203.0.113.88

json_test_check "$STATE_JSON" "data.resources.route53_zone_id === 'ZCREATE' && data.resources.route53_zone_name === 'auto-zone.example.test' && data.resources.route53_zone_created_by_deployer === 'true' && data.resources.route53_name_servers.includes('ns-1.awsdns.test')"

grep -q 'route53 create-hosted-zone' "$CALLS"
grep -q 'route53 change-resource-record-sets' "$CALLS"

echo "route53 zone auto create ok"
