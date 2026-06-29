#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export P2P_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$P2P_WORKDIR"

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
    printf '{"HostedZones":[{"Id":"/hostedzone/ZEXISTING","Name":"overwrite.example.test."}]}\n'
    ;;
  "route53 list-resource-record-sets")
    printf '{"ResourceRecordSets":[{"Name":"overwrite.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"198.51.100.10"}]}]}\n'
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
export PATH="$fakebin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set run_id route53-overwrite-test
state_set domain overwrite.example.test
state_set domain_mode route53

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

CALLS="$tmp/blocked.calls"
export CALLS
set +e
_upsert_route53_record overwrite.example.test 203.0.113.88 > "$tmp/blocked.out" 2>&1
blocked_rc=$?
set -e
[ "$blocked_rc" -eq 2 ] || {
  echo "Route53 overwrite without confirmation should return waiting_user rc=2" >&2
  cat "$tmp/blocked.out" >&2
  exit 1
}
grep -q 'Route53 A record overwrite requires confirmation' "$tmp/blocked.out"
if grep -q 'route53 change-resource-record-sets' "$CALLS"; then
  echo "Route53 overwrite without confirmation must not change records" >&2
  cat "$CALLS" >&2
  exit 1
fi
jq -e '
  .phases.S3_PROVISION.status == "waiting_user"
  and .resources.route53_existing_a_value == "198.51.100.10"
  and .resources.route53_pending_a_value == "203.0.113.88"
' "$STATE_JSON" >/dev/null

CALLS="$tmp/confirmed.calls"
export CALLS
DIREXIO_CONFIRM_DNS_OVERWRITE=1 _upsert_route53_record overwrite.example.test 203.0.113.88
grep -q 'route53 change-resource-record-sets' "$CALLS"
jq -e '
  .resources.route53_existing_a_value == "198.51.100.10"
  and .resources.route53_pending_a_value == "203.0.113.88"
  and .resources.route53_overwrite_confirmed == "true"
' "$STATE_JSON" >/dev/null

echo "route53 overwrite guard ok"
