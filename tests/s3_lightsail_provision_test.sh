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
    printf '{"regions":[{"name":"us-east-1","availabilityZones":[{"zoneName":"us-east-1a","state":"unavailable"},{"zoneName":"us-east-1b","state":"available"}]}]}\n'
    ;;
  "lightsail create-key-pair")
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----'
    printf '%s\n' 'test-key-material'
    printf '%s\n' '-----END OPENSSH PRIVATE KEY-----'
    ;;
  "lightsail get-instance")
    printf 'running\n'
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

json_test_check "$STATE_JSON" "data.cloud_provider === 'lightsail' && data.phases.S3_PROVISION.status === 'done' && data.resources.lightsail_bundle_id === 'medium_3_0' && data.resources.lightsail_availability_zone === 'us-east-1b' && data.resources.lightsail_availability_status === 'available' && data.resources.lightsail_instance_name === 'direxio-lightsail-example-test' && data.resources.lightsail_static_ip_name === 'direxio-ip-lightsail-example-test' && data.resources.lightsail_ports_configured === 'true' && data.resources.public_ip === '203.0.113.144' && data.cost_estimate.provider === 'lightsail' && data.cost_estimate.total_monthly_usd === 12"
key_file=$(json_get "$STATE_JSON" resources.key_file)
grep -q -- '-----BEGIN OPENSSH PRIVATE KEY-----' "$key_file" || {
  echo "Lightsail private key should be written as PEM text when AWS returns PEM text" >&2
  xxd -l 32 "$key_file" >&2
  exit 1
}
user_data=$(json_get "$STATE_JSON" resources.user_data)
[ "${user_data##*/}" = "user-data.sh" ] || {
  echo "Lightsail provisioning should render shell user-data, got: $user_data" >&2
  exit 1
}
head -n 1 "$user_data" | grep -Fx -q '#!/usr/bin/env bash'
if grep -q '^#cloud-config\|^package_update:' "$user_data"; then
  echo "Lightsail provisioning must not pass cloud-config YAML to create-instances" >&2
  exit 1
fi
grep -q 'docker compose --env-file .env up -d' "$user_data"
grep -q 'lightsail create-instances' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q -- '--user-data .*user-data.sh' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail get-instance' "$CALLS" || {
  echo "Lightsail provisioning should wait for instance state before port/static IP operations" >&2
  cat "$CALLS" >&2
  exit 1
}
grep -q -- '--availability-zone us-east-1b' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail allocate-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail attach-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'fromPort=49160\\,toPort=49200\\,protocol=udp' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
if grep -q '^aws ec2 ' "$CALLS"; then
  echo "Lightsail provisioning must not call EC2 APIs" >&2
  cat "$CALLS" >&2
  exit 1
fi

echo "s3 lightsail provision ok"
