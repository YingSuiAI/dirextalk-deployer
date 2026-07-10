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
    printf '{"HostedZones":[]}\n'
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

echo "Route53 hosted zone required ok"
