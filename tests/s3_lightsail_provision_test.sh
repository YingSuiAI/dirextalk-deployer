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
    case "$*" in
      *staticIp.name*) [ -f "$TMPDIR/static-ip.allocated" ] || exit 255; printf 'dirextalk-ip-lightsail-example-test\n' ;;
      *staticIp.attachedTo*) [ -f "$TMPDIR/static-ip.attached" ] && printf 'dirextalk-lightsail-example-test\n' || printf 'None\n' ;;
      *staticIp.ipAddress*) printf '203.0.113.144\n' ;;
      *) exit 90 ;;
    esac
    ;;
  "lightsail create-instances"|"lightsail open-instance-public-ports") ;;
  "lightsail allocate-static-ip") touch "$TMPDIR/static-ip.allocated" ;;
  "lightsail attach-static-ip") touch "$TMPDIR/static-ip.attached" ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fakebin/aws"
cat > "$fakebin/dirextalk-updater" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "resolve-release" ] || exit 90
cat <<'JSON'
{"source":"github_release","version":"v1.1.0","image":"dirextalk/message-server:v1.1.0","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_ref":"dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifest_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
JSON
EOF
chmod 700 "$fakebin/dirextalk-updater"
for command_name in scp ssh; do
  cat > "$fakebin/$command_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
EOF
  chmod 700 "$fakebin/$command_name"
done
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export TMPDIR="$tmp"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_CLOUD_PROVIDER=lightsail
export DIREXTALK_UPDATER_BINARY="$fakebin/dirextalk-updater"
export DIREXTALK_UPDATER_RESOLVER_BINARY="$fakebin/dirextalk-updater"

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
domain_resolves_to_ip() {
  printf 'dns-check %s %s\n' "$1" "$2" >> "$CALLS"
  return 0
}

if ! run_phase > "$tmp/s3.out" 2>&1; then
  cat "$tmp/s3.out" >&2
  exit 1
fi

json_test_check "$STATE_JSON" "data.cloud_provider === 'lightsail' && data.phases.S3_PROVISION.status === 'done' && data.resources.lightsail_bundle_id === 'medium_3_0' && data.resources.lightsail_availability_zone === 'us-east-1b' && data.resources.lightsail_availability_status === 'available' && data.resources.lightsail_instance_name === 'dirextalk-lightsail-example-test' && data.resources.lightsail_static_ip_name === 'dirextalk-ip-lightsail-example-test' && data.resources.lightsail_ports_configured === 'true' && data.resources.public_ip === '203.0.113.144' && data.cost_estimate.provider === 'lightsail' && data.cost_estimate.total_monthly_usd === 12 && data.server_release.source === 'github_release' && data.server_release.digest === 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' && data.server_release.image_ref.endsWith('@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
userdata_file=$(json_get "$STATE_JSON" resources.user_data)
grep -q '^#!/usr/bin/env bash' "$userdata_file" || {
  echo "Lightsail launch script must be shell user-data, not cloud-config" >&2
  sed -n '1,12p' "$userdata_file" >&2
  exit 1
}
key_file=$(json_get "$STATE_JSON" resources.key_file)
grep -q -- '-----BEGIN OPENSSH PRIVATE KEY-----' "$key_file" || {
  echo "Lightsail private key should be written as PEM text when AWS returns PEM text" >&2
  xxd -l 32 "$key_file" >&2
  exit 1
}
grep -q 'lightsail create-instances' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail get-instance' "$CALLS" || {
  echo "Lightsail provisioning should wait for instance state before port/static IP operations" >&2
  cat "$CALLS" >&2
  exit 1
}
grep -q -- '--availability-zone us-east-1b' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail allocate-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail attach-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q '^scp .*dirextalk-updater.*ubuntu@203\.0\.113\.144:/tmp/dirextalk-updater' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q '^scp .*bootstrap-host\.sh.*ubuntu@203\.0\.113\.144:/tmp/dirextalk-bootstrap-host' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q '^ssh .*ubuntu@203\.0\.113\.144.*\/usr\/local\/libexec\/dirextalk-bootstrap-host.*203\.0\.113\.144' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
static_ip_line=$(grep -n '^aws lightsail get-static-ip .*--query staticIp.ipAddress' "$CALLS" | cut -d: -f1 | head -n1)
upload_line=$(grep -n '^scp ' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^dns-check ' "$CALLS" | cut -d: -f1 | head -n1)
[ "$static_ip_line" -lt "$upload_line" ] && [ "$upload_line" -lt "$dns_line" ] || {
  echo "Lightsail updater upload must use the static IP and complete before DNS gating" >&2
  cat "$CALLS" >&2
  exit 1
}
before=$(grep -c '^scp ' "$CALLS")
_upload_updater_binary 203.0.113.144 "$(res_get key_file)" "$DIREXTALK_UPDATER_BINARY"
after=$(grep -c '^scp ' "$CALLS")
[ "$after" -eq $((before + 2)) ] || { echo "updater and bootstrap upload must be idempotently retryable" >&2; exit 1; }
grep -q 'fromPort=49160\\,toPort=49200\\,protocol=udp' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
if grep -q '^aws ec2 ' "$CALLS"; then
  echo "Lightsail provisioning must not call EC2 APIs" >&2
  cat "$CALLS" >&2
  exit 1
fi

echo "s3 lightsail provision ok"
