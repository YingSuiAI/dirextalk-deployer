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
  "sts get-caller-identity") printf '%s\n' "${AWS_ACCOUNT:-123456789012}" ;;
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
case "${!#}" in
  *python3*) cat >/dev/null; [ "${REMOTE_SSH_STATUS:-0}" -eq 0 ] || exit "$REMOTE_SSH_STATUS"; [ "${REMOTE_ROTATE_HOST:-0}" -eq 0 ] || printf 'rotated-host-key\n' >>"$KNOWN_HOSTS"; printf 'dns_status=%s machine_id_sha=%064d\n' "${REMOTE_DNS_STATUS:-0}" "${REMOTE_MACHINE_ID:-1}"; exit 0 ;;
  *machine_id_sha*) printf 'machine_id_sha=%064d\n' "${REMOTE_IDENTITY_MACHINE_ID:-1}"; exit 0 ;;
  *'apply-host-integration.sh'*)
    cat > "$TMPDIR/integration-upload.tar.gz"
    tar -tzf "$TMPDIR/integration-upload.tar.gz" > "$TMPDIR/integration-upload.list"
    if [ -f "$TMPDIR/updater-identity" ]; then
      cat "$TMPDIR/updater-identity"
    else
      printf 'v1.0.19\t1e71b9d53c599e8fb9227050b8c9643ce723acc5\t882f5131697a3f232c5975420e866ab165e1bc7f92e865f33114ed20b79a14b3\n'
    fi
    ;;
  *'/etc/machine-id'*) cat >/dev/null; printf '0123456789abcdef0123456789abcdef\tDOCKERENGINE1234\n' ;;
  *)
    cat >/dev/null
    if [ -f "$TMPDIR/updater-identity" ]; then
      cat "$TMPDIR/updater-identity"
    else
      printf 'v1.0.19\t1e71b9d53c599e8fb9227050b8c9643ce723acc5\t882f5131697a3f232c5975420e866ab165e1bc7f92e865f33114ed20b79a14b3\n'
    fi
    ;;
esac
EOF
chmod 700 "$fakebin/ssh"
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export TMPDIR="$tmp"
export KNOWN_HOSTS="$DIREXTALK_WORKDIR/known_hosts"
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

json_test_check "$STATE_JSON" "data.deployment_layout === 'split-agent' && data.cloud_provider === 'lightsail' && data.phases.S3_PROVISION.status === 'done' && data.resources.lightsail_bundle_id === 'medium_3_0' && data.resources.lightsail_availability_zone === 'us-east-1b' && data.resources.lightsail_availability_status === 'available' && data.resources.lightsail_instance_name === 'dirextalk-lightsail-example-test' && data.resources.lightsail_static_ip_name === 'dirextalk-ip-lightsail-example-test' && data.resources.lightsail_ports_configured === 'true' && data.resources.public_ip === '203.0.113.144' && data.cost_estimate.provider === 'lightsail' && data.cost_estimate.total_monthly_usd === 12 && data.server_release.source === 'production_split' && data.server_release.version === '$DIREXTALK_MESSAGE_SERVER_VERSION' && data.server_release.image_ref === '$DIREXTALK_MESSAGE_SERVER_IMAGE' && data.server_release.manifest_digest === '$DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST' && data.split_release.message_manifest_digest === '$DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST' && data.split_release.agent_manifest_digest === '$DIREXTALK_AGENT_MANIFEST_DIGEST' && data.updater_release.version === 'v1.0.19' && data.updater_release.sha256 === '882f5131697a3f232c5975420e866ab165e1bc7f92e865f33114ed20b79a14b3' && data.node_identity.aws_account_id === '123456789012' && data.node_identity.provider_instance_id === 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' && data.node_identity.machine_id === '0123456789abcdef0123456789abcdef' && data.node_identity.docker_engine_id === 'DOCKERENGINE1234'" || { cat "$STATE_JSON" >&2; exit 1; }
userdata_file=$(json_get "$STATE_JSON" resources.user_data)
grep -q '^#!/bin/sh' "$userdata_file" || {
  echo "Lightsail launch script must be shell user-data, not cloud-config" >&2
  sed -n '1,12p' "$userdata_file" >&2
  exit 1
}
grep -Fqx 'DIREXTALK_CLOUD_WORKER_HOST_REGION=us-east-1' "$userdata_file"
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
grep -q '^ssh .*apply-host-integration\.sh.*203\.0\.113\.144.*us-east-1' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q -- '--no-same-owner' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
identity_line=$(grep -n '^ssh .*StrictHostKeyChecking=accept-new.*machine_id_sha' "$CALLS" | head -n1 | cut -d: -f1)
strict_dns_line=$(grep -n '^ssh .*StrictHostKeyChecking=yes.*python3' "$CALLS" | head -n1 | cut -d: -f1)
[ -n "$identity_line" ] && [ -n "$strict_dns_line" ] && [ "$identity_line" -lt "$strict_dns_line" ] || { cat "$CALLS" >&2; exit 1; }
static_ip_line=$(grep -n '^aws lightsail get-static-ip .*--query staticIp.ipAddress' "$CALLS" | cut -d: -f1 | head -n1)
upload_line=$(grep -n '^ssh .*tar.*apply-host-integration' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^ssh .*python3' "$CALLS" | cut -d: -f1 | head -n1)
[ "$static_ip_line" -lt "$dns_line" ] && [ "$dns_line" -lt "$upload_line" ] || {
  echo "Lightsail DNS must be authoritative before the host integration can trigger ACME" >&2
  cat "$CALLS" >&2
  exit 1
}
if grep -q '^dns-check ' "$CALLS"; then
  echo 'a successful local resolver must never be used as the S3 DNS gate' >&2
  exit 1
fi
if AWS_ACCOUNT=999999999999 run_phase >/dev/null 2>&1; then
  echo 'S3 accepted a changed AWS account while resuming recorded resources' >&2
  exit 1
fi
[ "$(state_get aws_account_id)" = 123456789012 ]
for dns_case in not_propagated infrastructure_unavailable; do
  before_host_calls=$(grep -c 'apply-host-integration' "$CALLS" || true)
  if [ "$dns_case" = not_propagated ]; then
    expected_phase_rc=2
  else
    expected_phase_rc=1
  fi
  if [ "$dns_case" = not_propagated ]; then
    if AWS_ACCOUNT=123456789012 REMOTE_DNS_STATUS=1 _run_phase_lightsail >/dev/null 2>&1; then phase_attempt_rc=0; else phase_attempt_rc=$?; fi
  else
    if AWS_ACCOUNT=123456789012 REMOTE_DNS_STATUS=2 _run_phase_lightsail >/dev/null 2>&1; then phase_attempt_rc=0; else phase_attempt_rc=$?; fi
  fi
  if [ "$phase_attempt_rc" -eq 0 ]; then
    echo "S3 accepted remote DNS $dns_case" >&2
    exit 1
  else
    phase_rc=$phase_attempt_rc
  fi
  [ "$phase_rc" -eq "$expected_phase_rc" ]
  after_host_calls=$(grep -c 'apply-host-integration' "$CALLS" || true)
  [ "$after_host_calls" -eq "$before_host_calls" ]
done
set +e
REMOTE_DNS_STATUS=1 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null 2>&1
remote_not_ready_rc=$?
REMOTE_DNS_STATUS=2 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null 2>&1
remote_infra_rc=$?
set -e
[ "$remote_not_ready_rc" -eq 2 ]
[ "$remote_infra_rc" -eq 1 ]
[ "$(state_get dns_check_status)" = infrastructure_unavailable ]
if REMOTE_SSH_STATUS=255 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null 2>&1; then
  echo 'SSH shell failure must not be classified as remote DNS propagation' >&2
  exit 1
else
  remote_ssh_rc=$?
fi
[ "$remote_ssh_rc" -eq 1 ]
if DNS_READY=1 REMOTE_DNS_STATUS=1 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null 2>&1; then
  echo 'DNS_READY must not bypass a remote not-propagated result' >&2
  exit 1
fi
if REMOTE_DNS_STATUS=0 REMOTE_MACHINE_ID=2 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null 2>&1; then
  echo 'remote DNS gate accepted a changed deployed-host identity' >&2
  exit 1
fi
if REMOTE_DNS_STATUS=0 REMOTE_ROTATE_HOST=1 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null 2>&1; then
  echo 'remote DNS gate accepted a changed SSH host identity' >&2
  exit 1
fi
printf 'fixture-host-key\n' >"$KNOWN_HOSTS"
REMOTE_DNS_STATUS=0 _require_user_dns_ready user lightsail.example.test 203.0.113.144 'DIREXTALK_CLOUD_PROVIDER=lightsail' >/dev/null
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
DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server@sha256:$(printf '1%.0s' {1..64})
DIREXTALK_MESSAGE_SOURCE_REVISION=1111111111111111111111111111111111111111
DIREXTALK_AGENT_VERSION=v9.2.0
DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent@sha256:$(printf '2%.0s' {1..64})
DIREXTALK_AGENT_SOURCE_REVISION=2222222222222222222222222222222222222222
DIREXTALK_CADDY_IMAGE_IMMUTABLE=docker.io/library/caddy@sha256:$(printf '3%.0s' {1..64})
DIREXTALK_COTURN_IMAGE_IMMUTABLE=docker.io/coturn/coturn:4.6.3-alpine@sha256:$(printf '4%.0s' {1..64})
DIREXTALK_SPLIT_SOURCE_REVISION=3333333333333333333333333333333333333333
UPDATER_PIN_VERSION=v1.0.19
UPDATER_PIN_COMMIT=4444444444444444444444444444444444444444
UPDATER_PIN_SHA256=$(printf '5%.0s' {1..64})
UPDATER_PIN_URL=https://github.com/YingSuiAI/dirextalk-updater/releases/download/v1.0.19/dirextalk-updater-linux-amd64
printf '%s\t%s\t%s\n' "$UPDATER_PIN_VERSION" "$UPDATER_PIN_COMMIT" "$UPDATER_PIN_SHA256" >"$TMPDIR/updater-identity"
_resume_host_bootstrap 203.0.113.144 "$(res_get key_file)"
[ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ]
[ "$(state_get split_release.message_version)" = "$recorded_message_version" ]
[ "$(state_get split_release.message_image)" = "$recorded_message_image" ]
[ "$(state_get split_release.agent_version)" = "$recorded_agent_version" ]
[ "$(state_get split_release.agent_image)" = "$recorded_agent_image" ]
[ "$(state_get updater_release.version)" = v1.0.19 ]
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
