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
    printf '{"bundles":[{"bundleId":"medium_3_0","price":12,"ramSizeInGb":2,"diskSizeInGb":60,"supportedPlatforms":["LINUX_UNIX"]}]}\n'
    ;;
  "lightsail get-regions")
    printf '{"regions":[{"name":"us-east-1","availabilityZones":[{"zoneName":"us-east-1a","state":"available"}]}]}\n'
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
    exit 255
    ;;
  "lightsail create-instances"|"lightsail open-instance-public-ports"|"lightsail attach-static-ip")
    ;;
  "lightsail allocate-static-ip")
    echo "An error occurred (ServiceException) when calling the AllocateStaticIp operation: Sorry, you have reached the maximum number of static IP addresses." >&2
    exit 255
    ;;
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
[ "${1:-}" = resolve-release ] || exit 90
printf '%s\n' '{"source":"github_release","version":"v1.1.0","image":"dirextalk/message-server:v1.1.0","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_ref":"dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifest_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
EOF
chmod 700 "$fakebin/dirextalk-updater"
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_CLOUD_PROVIDER=lightsail
export DIREXTALK_UPDATER_BINARY="$fakebin/dirextalk-updater"
export DIREXTALK_UPDATER_RESOLVER_BINARY="$fakebin/dirextalk-updater"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region us-east-1
state_set domain quota.example.test
state_set domain_mode user

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"
domain_resolves_to_ip() { return 0; }

set +e
run_phase > "$tmp/s3.out" 2>&1
rc=$?
set -e

[ "$rc" -eq 2 ] || {
  cat "$tmp/s3.out" >&2
  echo "expected Lightsail static IP quota exhaustion to wait for user action, got rc=$rc" >&2
  exit 1
}

json_test_check "$STATE_JSON" "data.phases.S3_PROVISION.status === 'waiting_user' && data.resources.lightsail_static_ip_allocation_status === 'quota_exceeded' && data.resources.lightsail_static_ip_quota_action.includes('get-static-ips')"
grep -q 'maximum number of static IP' "$tmp/s3.out"

echo "lightsail static ip quota ok"
