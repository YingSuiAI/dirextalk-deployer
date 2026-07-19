#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
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
    case "${ROUTE53_TEST_SCENARIO:-missing}" in
      missing) printf '{"HostedZones":[]}\n' ;;
      overwrite) printf '{"HostedZones":[{"Id":"/hostedzone/ZEXISTING","Name":"overwrite.example.test."}]}\n' ;;
      *) exit 1 ;;
    esac
    ;;
  "route53 list-resource-record-sets")
    [ "${ROUTE53_TEST_SCENARIO:-missing}" = overwrite ] || exit 1
    printf '{"ResourceRecordSets":[{"Name":"overwrite.example.test.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"198.51.100.10"}]}]}\n'
    ;;
  "route53 change-resource-record-sets"|"route53 wait")
    [ "${ROUTE53_TEST_SCENARIO:-missing}" = overwrite ] || exit 1
    printf '{"ChangeInfo":{"Id":"/change/C123","Status":"PENDING"}}\n'
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
state_set domain missing-zone.example.test
state_set domain_mode route53

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

set +e
_upsert_route53_record missing-zone.example.test 203.0.113.88 >"$tmp/output" 2>&1
rc=$?
set -e

[ "$rc" -eq 1 ] || {
  echo "missing Route53 hosted zone should fail before changing DNS" >&2
  exit 1
}
grep -q 'existing public Route53 hosted zone' "$tmp/output"
grep -q 'route53 list-hosted-zones' "$CALLS"
if grep -q 'route53 create-hosted-zone\|route53 change-resource-record-sets' "$CALLS"; then
  echo "deployer must not create a hosted zone or A record when no matching zone exists" >&2
  cat "$CALLS" >&2
  exit 1
fi

# Existing A records are never silently overwritten: the direct DNS safety
# contract lives with the required-zone test rather than a second Route53 file.
state_init >/dev/null 2>&1
state_set run_id route53-overwrite-test
state_set domain overwrite.example.test
state_set domain_mode route53
: > "$CALLS"
export ROUTE53_TEST_SCENARIO=overwrite
set +e
_upsert_route53_record overwrite.example.test 203.0.113.88 > "$tmp/overwrite-blocked.out" 2>&1
overwrite_rc=$?
set -e
[ "$overwrite_rc" -eq 2 ] || {
  echo "Route53 overwrite without confirmation should return waiting_user rc=2" >&2
  exit 1
}
grep -q 'Route53 A record overwrite requires confirmation' "$tmp/overwrite-blocked.out"
if grep -q 'route53 change-resource-record-sets' "$CALLS"; then
  echo "Route53 overwrite without confirmation must not change records" >&2
  cat "$CALLS" >&2
  exit 1
fi
json_test_check "$STATE_JSON" "data.phases.S3_PROVISION.status === 'waiting_user' && data.resources.route53_existing_a_value === '198.51.100.10' && data.resources.route53_pending_a_value === '203.0.113.88'"

: > "$CALLS"
DIREXTALK_CONFIRM_DNS_OVERWRITE=1 _upsert_route53_record overwrite.example.test 203.0.113.88
grep -q 'route53 change-resource-record-sets' "$CALLS"
json_test_check "$STATE_JSON" "data.resources.route53_existing_a_value === '198.51.100.10' && data.resources.route53_pending_a_value === '203.0.113.88' && data.resources.route53_overwrite_confirmed === 'true'"

echo "Route53 hosted zone required ok"
