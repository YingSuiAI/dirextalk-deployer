#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
source "$ROOT/tests/lib/split-release.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR"
printf 'fixture-host-key\n' >"$DIREXTALK_WORKDIR/known_hosts"
dirextalk_test_prepare_split_release "$tmp"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

case "${1:-} ${2:-}" in
  "sts get-caller-identity") printf '123456789012\n' ;;
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
    case "$*" in
      *instance.arn*) printf 'arn:aws:lightsail:us-east-1:123456789012:Instance/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\t123456789012/i-0123456789abcdef0\t203.0.113.144\n' ;;
      *) printf 'running\n' ;;
    esac
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
cat > "$fakebin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp-called\n' >> "$CALLS"
exit 97
EOF
chmod 700 "$fakebin/scp"
cat > "$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
cat >/dev/null
case "${!#}" in
  *'/etc/machine-id'*) printf '0123456789abcdef0123456789abcdef\tDOCKERENGINE1234\n' ;;
  *)
    if [ -f "$TMPDIR/updater-identity" ]; then
      cat "$TMPDIR/updater-identity"
    else
      printf 'v1.0.14\tdc97777c7169ea498199f7b31689f8373fe6c04c\t4deac3f24267bdb493d58b598e8f7ce69b5957a373f2103774d148f202e6189f\n'
    fi
    ;;
esac
EOF
chmod 700 "$fakebin/ssh"
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export TMPDIR="$tmp"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_CLOUD_PROVIDER=lightsail
export MSYS_NO_PATHCONV=1

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

json_test_check "$STATE_JSON" "data.deployment_layout === 'split-agent' && data.cloud_provider === 'lightsail' && data.phases.S3_PROVISION.status === 'done' && data.resources.lightsail_bundle_id === 'medium_3_0' && data.resources.lightsail_availability_zone === 'us-east-1b' && data.resources.lightsail_availability_status === 'available' && data.resources.lightsail_instance_name === 'dirextalk-lightsail-example-test' && data.resources.lightsail_static_ip_name === 'dirextalk-ip-lightsail-example-test' && data.resources.lightsail_ports_configured === 'true' && data.resources.public_ip === '203.0.113.144' && data.cost_estimate.provider === 'lightsail' && data.cost_estimate.total_monthly_usd === 12 && data.server_release.source === 'production_split' && data.server_release.version === '$DIREXTALK_MESSAGE_SERVER_VERSION' && data.server_release.image_ref === '$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE' && data.updater_release.version === 'v1.0.14' && data.updater_release.sha256 === '4deac3f24267bdb493d58b598e8f7ce69b5957a373f2103774d148f202e6189f' && data.node_identity.aws_account_id === '123456789012' && data.node_identity.provider_instance_id === 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' && data.node_identity.machine_id === '0123456789abcdef0123456789abcdef' && data.node_identity.docker_engine_id === 'DOCKERENGINE1234'" || { cat "$STATE_JSON" >&2; exit 1; }
userdata_file=$(json_get "$STATE_JSON" resources.user_data)
grep -q '^#!/bin/sh' "$userdata_file" || {
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
case "$(uname -s 2>/dev/null || printf unknown)" in
  *MINGW*|*MSYS*|*CYGWIN*)
    grep -Eq -- '--user-data file://[A-Za-z]:/' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
    ;;
esac
grep -q 'lightsail get-instance' "$CALLS" || {
  echo "Lightsail provisioning should wait for instance state before port/static IP operations" >&2
  cat "$CALLS" >&2
  exit 1
}
grep -q -- '--availability-zone us-east-1b' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail allocate-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'lightsail attach-static-ip' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
if grep -q '^scp-called$\|^scp ' "$CALLS"; then echo "S3 must not SCP updater artifacts" >&2; cat "$CALLS" >&2; exit 1; fi
grep -q '^ssh .*ubuntu@203\.0\.113\.144.*tar.*apply-host-integration\.sh.*203\.0\.113\.144' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q '^ssh .*bootstrap-host\.sh.*--record-stable-ip.*203\.0\.113\.144.*apply-host-integration\.sh' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q '^ssh .*apply-host-integration\.sh.*cloud-init.*status.*--wait.*printf' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q -- '--no-same-owner' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
static_ip_line=$(grep -n '^aws lightsail get-static-ip .*--query staticIp.ipAddress' "$CALLS" | cut -d: -f1 | head -n1)
upload_line=$(grep -n '^ssh ' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^dns-check ' "$CALLS" | cut -d: -f1 | head -n1)
[ "$static_ip_line" -lt "$upload_line" ] && [ "$upload_line" -lt "$dns_line" ] || {
  echo "Lightsail updater upload must use the static IP and complete before DNS gating" >&2
  cat "$CALLS" >&2
  exit 1
}
before=$(grep -c '^ssh ' "$CALLS")
_resume_host_bootstrap 203.0.113.144 "$(res_get key_file)"
after=$(grep -c '^ssh ' "$CALLS")
[ "$after" -eq $((before + 1)) ] || { echo "host bootstrap resume must be idempotently retryable" >&2; exit 1; }

recorded_split_revision=$(state_get split_release.split_source_revision)
recorded_message_version=$(state_get split_release.message_version)
recorded_message_image=$(state_get split_release.message_image)
recorded_agent_version=$(state_get split_release.agent_version)
recorded_agent_image=$(state_get split_release.agent_image)
DIREXTALK_MESSAGE_SERVER_VERSION=v9.1.0
DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=docker.io/dirextalk/message-server@sha256:$(printf '1%.0s' {1..64})
DIREXTALK_MESSAGE_SOURCE_REVISION=1111111111111111111111111111111111111111
DIREXTALK_AGENT_VERSION=v9.2.0
DIREXTALK_AGENT_IMAGE_IMMUTABLE=docker.io/dirextalk/agent@sha256:$(printf '2%.0s' {1..64})
DIREXTALK_AGENT_SOURCE_REVISION=2222222222222222222222222222222222222222
DIREXTALK_CADDY_IMAGE_IMMUTABLE=docker.io/library/caddy@sha256:$(printf '3%.0s' {1..64})
DIREXTALK_COTURN_IMAGE_IMMUTABLE=docker.io/coturn/coturn:4.6.3-alpine@sha256:$(printf '4%.0s' {1..64})
DIREXTALK_SPLIT_SOURCE_REVISION=3333333333333333333333333333333333333333
UPDATER_PIN_VERSION=v1.0.14
UPDATER_PIN_COMMIT=4444444444444444444444444444444444444444
UPDATER_PIN_SHA256=$(printf '5%.0s' {1..64})
UPDATER_PIN_URL=https://github.com/YingSuiAI/dirextalk-updater/releases/download/v1.0.14/dirextalk-updater-linux-amd64
printf '%s\t%s\t%s\n' "$UPDATER_PIN_VERSION" "$UPDATER_PIN_COMMIT" "$UPDATER_PIN_SHA256" >"$TMPDIR/updater-identity"
_resume_host_bootstrap 203.0.113.144 "$(res_get key_file)"
[ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ]
[ "$(state_get split_release.message_version)" = "$recorded_message_version" ]
[ "$(state_get split_release.message_image)" = "$recorded_message_image" ]
[ "$(state_get split_release.agent_version)" = "$recorded_agent_version" ]
[ "$(state_get split_release.agent_image)" = "$recorded_agent_image" ]
[ "$(state_get updater_release.version)" = v1.0.14 ]
[ "$recorded_split_revision" != "$(state_get split_release.split_source_revision)" ]
grep -q 'fromPort=49160\\,toPort=49200\\,protocol=udp' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'fromPort=3478\\,toPort=3478\\,protocol=tcp' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q 'fromPort=3478\\,toPort=3478\\,protocol=udp' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
if grep -q '^aws ec2 ' "$CALLS"; then
  echo "Lightsail provisioning must not call EC2 APIs" >&2
  cat "$CALLS" >&2
  exit 1
fi

echo "s3 lightsail provision ok"
