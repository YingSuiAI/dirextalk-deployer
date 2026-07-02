#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXIO_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$DIREXIO_WORKDIR"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

case "${1:-} ${2:-}" in
  "freetier get-free-tier-usage")
    printf '{"freeTierUsages":[]}\n'
    ;;
  "lightsail get-bundles")
    printf '{"bundles":[{"bundleId":"medium_3_0","price":12,"ramSizeInGb":2,"diskSizeInGb":60,"supportedPlatforms":["LINUX_UNIX"]}]}\n'
    ;;
  "lightsail get-regions")
    printf '{"regions":[{"name":"us-east-1","availabilityZones":[{"zoneName":"us-east-1a","state":"unavailable"},{"zoneName":"us-east-1b","state":"unavailable"}]}]}\n'
    ;;
  "ec2 describe-vpcs")
    printf 'vpc-fallback\n'
    ;;
  "service-quotas get-service-quota")
    case "$*" in
      *L-1216C47A*) printf '8.0\n' ;;
      *L-0263D0A3*) printf '5.0\n' ;;
      *) echo "unexpected quota command: $*" >&2; exit 1 ;;
    esac
    ;;
  "ec2 describe-addresses")
    printf '0\n'
    ;;
  "ssm get-parameters")
    printf 'ami-fallback\n'
    ;;
  "configure get")
    printf 'us-east-1\n'
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

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region us-east-1

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s1_preflight.sh"

if ! run_phase > "$tmp/preflight.out" 2>&1; then
  cat "$tmp/preflight.out" >&2
  exit 1
fi

json_test_check "$STATE_JSON" "data.cloud_provider === 'ec2' && data.cloud_recommendation.selected_provider === 'ec2' && data.cloud_recommendation.recommended_provider === 'ec2' && data.resources.lightsail_availability_status === 'unavailable' && data.resources.vpc_id === 'vpc-fallback' && data.resources.ami_id === 'ami-fallback'"
grep -q 'lightsail get-regions' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'ec2 describe-vpcs' "$CALLS" || { cat "$CALLS" >&2; exit 1; }

echo "s1 lightsail availability fallback ok"
