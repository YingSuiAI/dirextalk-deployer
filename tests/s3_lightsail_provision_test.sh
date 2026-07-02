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
    printf '{"bundles":[{"bundleId":"medium_3_0","price":12,"ramSizeInGb":2,"diskSizeInGb":60,"transferPerMonthInGb":3072,"cpuCount":2,"supportedPlatforms":["LINUX_UNIX"]}]}\n'
    ;;
  "lightsail get-regions")
    printf '{"regions":[{"name":"us-east-1","availabilityZones":[{"zoneName":"us-east-1a","state":"available"}]}]}\n'
    ;;
  "lightsail create-key-pair")
    printf '%s\n' "$(printf 'PRIVATE_KEY' | base64 | tr -d '\n')"
    ;;
  "lightsail get-static-ip")
    count_file="$TMPDIR/get-static-ip.count"
    count=0
    [ -f "$count_file" ] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then
      exit 255
    fi
    printf '203.0.113.144\n'
    ;;
  "lightsail create-instances"|"lightsail open-instance-public-ports"|"lightsail allocate-static-ip"|"lightsail attach-static-ip")
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
export TMPDIR="$tmp"
export AWS_DEFAULT_REGION=us-east-1
export DIREXIO_CLOUD_PROVIDER=lightsail

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region us-east-1
state_set domain lightsail.example.test
state_set domain_mode user

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"
domain_resolves_to_ip() { return 0; }

if ! run_phase > "$tmp/s3.out" 2>&1; then
  cat "$tmp/s3.out" >&2
  exit 1
fi

json_test_check "$STATE_JSON" "data.cloud_provider === 'lightsail' && data.phases.S3_PROVISION.status === 'done' && data.resources.lightsail_bundle_id === 'medium_3_0' && data.resources.lightsail_instance_name === 'direxio-lightsail-example-test' && data.resources.lightsail_static_ip_name === 'direxio-ip-lightsail-example-test' && data.resources.lightsail_ports_configured === 'true' && data.resources.public_ip === '203.0.113.144' && data.cost_estimate.provider === 'lightsail' && data.cost_estimate.total_monthly_usd === 12"
grep -q 'lightsail create-instances' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail allocate-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail attach-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'fromPort=49160\\,toPort=49200\\,protocol=udp' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
if grep -q '^aws ec2 ' "$CALLS"; then
  echo "Lightsail provisioning must not call EC2 APIs" >&2
  cat "$CALLS" >&2
  exit 1
fi

echo "s3 lightsail provision ok"
