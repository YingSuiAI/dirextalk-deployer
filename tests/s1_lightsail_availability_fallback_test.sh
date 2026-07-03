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
  "lightsail get-bundles")
    printf '{"bundles":[{"bundleId":"medium_3_0","price":12,"ramSizeInGb":2,"diskSizeInGb":60,"supportedPlatforms":["LINUX_UNIX"]}]}\n'
    ;;
  "lightsail get-regions")
    printf '{"regions":[{"name":"us-east-1","availabilityZones":[{"zoneName":"us-east-1a","state":"unavailable"},{"zoneName":"us-east-1b","state":"unavailable"}]}]}\n'
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

rc=0
run_phase > "$tmp/preflight.out" 2>&1 || rc=$?
if [ "$rc" -ne 2 ]; then
  cat "$tmp/preflight.out" >&2
  echo "expected S1 to wait for user choice with rc=2, got rc=$rc" >&2
  exit 1
fi

json_test_check "$STATE_JSON" "data.cloud_provider === 'lightsail' && data.cloud_recommendation.selected_provider === 'lightsail' && data.cloud_recommendation.recommended_provider === 'lightsail' && data.cloud_recommendation.ec2_cost_estimate.provider === 'ec2' && data.cloud_recommendation.ec2_cost_estimate.total_monthly_usd > 0 && data.resources.lightsail_availability_status === 'unavailable' && data.phases.S1_PREFLIGHT.status === 'waiting_user'"
grep -q 'lightsail get-regions' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
if grep -q '^aws ec2 ' "$CALLS" || grep -q '^aws service-quotas ' "$CALLS" || grep -q '^aws ssm ' "$CALLS"; then
  echo "S1 must not run EC2 preflight when Lightsail is unavailable by default" >&2
  cat "$CALLS" >&2
  exit 1
fi
! grep -q 'freetier' "$CALLS" || { cat "$CALLS" >&2; exit 1; }

echo "s1 lightsail availability user choice ok"
