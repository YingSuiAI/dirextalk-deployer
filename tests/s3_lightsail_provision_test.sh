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
    if [ -n "${DIREXTALK_FAKE_INSTANCE_LOOKUP_FAILURE:-}" ]; then
      printf '%s\n' 'An error occurred (ServiceUnavailableException) when calling the GetInstance operation: test transport failure' >&2
      exit 255
    fi
    if [ ! -f "$TMPDIR/instance.created" ]; then
      printf '%s\n' 'An error occurred (NotFoundException) when calling the GetInstance operation: test instance absent' >&2
      exit 255
    fi
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
  "lightsail create-instances")
    launch_ref=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --user-data) launch_ref=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    launch_path=${launch_ref#file://}
    case "$(uname -s 2>/dev/null || printf unknown)" in
      *MINGW*|*MSYS*|*CYGWIN*) launch_path=$(cygpath -u "$launch_path") ;;
    esac
    cat "$launch_path" > "$TMPDIR/lightsail-launch-user-data"
    grep -Eo '[0-9a-f]{64}' "$launch_path" | head -n1 > "$TMPDIR/lightsail-bootstrap.nonce"
    touch "$TMPDIR/instance.created"
    ;;
  "lightsail open-instance-public-ports") ;;
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
known_hosts=''
for arg in "$@"; do
  case "$arg" in
    UserKnownHostsFile=*) known_hosts=${arg#UserKnownHostsFile=} ;;
  esac
done
if [ -n "$known_hosts" ]; then
  printf '203.0.113.144 ssh-ed25519 fake-host-key\n' > "$known_hosts"
fi
if [[ "$*" == *"/bin/cat /var/lib/dirextalk-bootstrap/nonce"* ]]; then
  printf 'ssh-enroll\n' >> "$CALLS"
  if [ -n "${DIREXTALK_FAKE_ENROLL_NOT_READY_ONCE:-}" ] && [ ! -f "$TMPDIR/fake-enroll-not-ready.once" ]; then
    : > "$TMPDIR/fake-enroll-not-ready.once"
    exit 255
  fi
  if [ -n "${DIREXTALK_FAKE_ENROLL_EMPTY_ONCE:-}" ] && [ ! -f "$TMPDIR/fake-enroll-empty.once" ]; then
    : > "$TMPDIR/fake-enroll-empty.once"
    exit 0
  fi
  if [ -n "${DIREXTALK_FAKE_NONCE:-}" ]; then
    printf '%s\n' "$DIREXTALK_FAKE_NONCE"
  else
    cat "$TMPDIR/lightsail-bootstrap.nonce"
  fi
elif [[ "$*" == *"sudo -n -- /bin/bash -s"* ]]; then
  printf 'ssh-bootstrap\n' >> "$CALLS"
  cat > "$TMPDIR/lightsail-bootstrap.stdin"
elif [[ "$*" == *"agent-runtime-init"* && "$*" == *"mounted-secrets"* ]]; then
  printf 'ssh-secret-delivery\n' >> "$CALLS"
  if [ -n "${DIREXTALK_FAKE_SECRET_DELIVERY_FAILURE:-}" ]; then
    exit 255
  fi
  cat > "$TMPDIR/lightsail-secret.stdin"
else
  cat >/dev/null
  printf 'v1.0.8\t1efa90fd776d355d4cd898bcdb4922267b03d180\t04ec14457b59430042d1340bf2b2bd39fd4ecc38d55892ea09b38012a069969b\n'
fi
EOF
chmod 700 "$fakebin/ssh"
export PATH="$fakebin:$PATH"
export CALLS="$tmp/aws.calls"
export TMPDIR="$tmp"
export AWS_DEFAULT_REGION=us-east-1
export DIREXTALK_CLOUD_PROVIDER=lightsail
export DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=1
export DIREXTALK_BOOTSTRAP_SSH_DELAY=0
export MSYS_NO_PATHCONV=1

# Exercise the optional Agent through the real S3 render invocation while the
# AWS CLI remains fully mocked below.  The renderer/Agent contract covers the
# bundle internals; this test owns the hand-off from provision state.
agent_image='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
agent_instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
agent_profiles="$tmp/agent-model-profiles.json"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"test-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$agent_profiles"
secret_source="$tmp/operator-mounted-secret"
secret_value='test-only-mounted-secret'
printf '%s\n' "$secret_value" > "$secret_source"
export AGENT_IMAGE="$agent_image"
export AGENT_INSTANCE_ID="$agent_instance_id"
export AGENT_MODEL_PROFILES_FILE="$agent_profiles"

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

unsafe_secret_source="$DIREXTALK_WORKDIR/unsafe-mounted-secret"
printf '%s\n' "$secret_value" > "$unsafe_secret_source"
set +e
AGENT_MOUNTED_SECRET_FILE="$unsafe_secret_source" AGENT_MOUNTED_SECRET_NAME=test-token run_phase > "$tmp/s3-unsafe-secret.out" 2>&1
unsafe_secret_rc=$?
set -e
[ "$unsafe_secret_rc" -eq 1 ] || {
  cat "$tmp/s3-unsafe-secret.out" >&2
  echo "managed-workdir mounted secret source must fail before provisioning" >&2
  exit 1
}
if grep -q 'lightsail create-key-pair' "$CALLS" 2>/dev/null; then
  echo "invalid mounted secret source must fail before creating a key pair" >&2
  cat "$CALLS" >&2
  exit 1
fi

invalid_scripts="$tmp/invalid-scripts"
mkdir -p "$invalid_scripts/render"
cat > "$invalid_scripts/render/render-userdata.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'if then'
EOF
set +e
DIREXTALK_INSTALL_SCRIPTS_DIR="$invalid_scripts" run_phase > "$tmp/s3-invalid.out" 2>&1
invalid_rc=$?
set -e
[ "$invalid_rc" -eq 1 ] || {
  cat "$tmp/s3-invalid.out" >&2
  echo "expected invalid Lightsail bootstrap to fail before provisioning" >&2
  exit 1
}
grep -q 'Rendered Lightsail bootstrap script is empty or invalid' "$tmp/s3-invalid.out"
if grep -q 'lightsail create-key-pair' "$CALLS" 2>/dev/null; then
  echo "invalid Lightsail bootstrap must fail before creating a key pair" >&2
  cat "$CALLS" >&2
  exit 1
fi
json_test_check "$STATE_JSON" "data.phases.S3_PROVISION.status === 'failed' && !data.resources.key_name"
unset DIREXTALK_INSTALL_SCRIPTS_DIR

# A valid bootstrap can exceed the Lightsail public user-data limit because only
# the small launcher reaches the provider; the full script stays on encrypted SSH.
oversized_scripts="$tmp/oversized-scripts"
mkdir -p "$oversized_scripts/render"
cat > "$oversized_scripts/render/render-userdata.sh" <<'EOF'
#!/usr/bin/env bash
printf '#!/bin/bash\nset -eu\n#'
head -c 20000 /dev/zero | tr '\000' x
printf '\n'
EOF
state_init >/dev/null 2>&1
state_set region us-east-1
state_set domain lightsail.example.test
state_set domain_mode user
: > "$CALLS"
rm -f "$tmp/instance.created" "$tmp/static-ip.allocated" "$tmp/static-ip.attached" "$tmp/lightsail-launch-user-data" "$tmp/lightsail-bootstrap.stdin" "$tmp/lightsail-bootstrap.nonce"
if ! DIREXTALK_INSTALL_SCRIPTS_DIR="$oversized_scripts" run_phase > "$tmp/s3-oversized.out" 2>&1; then
  cat "$tmp/s3-oversized.out" >&2
  echo "expected oversized valid Lightsail bootstrap to succeed" >&2
  exit 1
fi
oversized_bootstrap=$(json_get "$STATE_JSON" resources.lightsail_bootstrap_script)
oversized_launcher=$(json_get "$STATE_JSON" resources.user_data)
[ "$(wc -c < "$oversized_bootstrap" | tr -d '[:space:]')" -gt 16000 ] || { echo "fixture must exceed the public user-data limit" >&2; exit 1; }
[ "$(wc -c < "$oversized_launcher" | tr -d '[:space:]')" -lt 512 ] || { echo "Lightsail launch user-data must remain small" >&2; exit 1; }
cmp "$oversized_launcher" "$tmp/lightsail-launch-user-data"
cmp "$oversized_bootstrap" "$tmp/lightsail-bootstrap.stdin"
if grep -q 'bundle.tar.gz\|AGENT_IMAGE' "$tmp/lightsail-launch-user-data"; then
  echo "Lightsail launch user-data must not contain the full bootstrap payload" >&2
  exit 1
fi
if grep -q '^ssh-secret-delivery$' "$CALLS"; then
  echo "unset mounted Agent secret inputs must not trigger delivery" >&2
  cat "$CALLS" >&2
  exit 1
fi

# Reset the isolated state and mock call log before the independent Agent happy path.
state_init >/dev/null 2>&1
state_set region us-east-1
state_set domain lightsail.example.test
state_set domain_mode user
: > "$CALLS"
rm -f "$tmp/instance.created" "$tmp/static-ip.allocated" "$tmp/static-ip.attached" "$tmp/lightsail-launch-user-data" "$tmp/lightsail-bootstrap.stdin" "$tmp/lightsail-bootstrap.nonce"

if ! AGENT_MOUNTED_SECRET_FILE="$secret_source" AGENT_MOUNTED_SECRET_NAME=test-token run_phase > "$tmp/s3.out" 2>&1; then
  cat "$tmp/s3.out" >&2
  exit 1
fi

json_test_check "$STATE_JSON" "data.cloud_provider === 'lightsail' && data.phases.S3_PROVISION.status === 'done' && data.resources.lightsail_bundle_id === 'medium_3_0' && data.resources.lightsail_availability_zone === 'us-east-1b' && data.resources.lightsail_availability_status === 'available' && data.resources.lightsail_instance_name === 'dirextalk-lightsail-example-test' && data.resources.lightsail_static_ip_name === 'dirextalk-ip-lightsail-example-test' && data.resources.lightsail_ports_configured === 'true' && data.resources.public_ip === '203.0.113.144' && data.cost_estimate.provider === 'lightsail' && data.cost_estimate.total_monthly_usd === 12 && data.server_release.source === 'default_latest' && data.server_release.version === 'latest' && data.server_release.image_ref === 'dirextalk/message-server:latest' && data.server_release.digest === '' && data.agent_release.source === 'operator_image' && data.agent_release.enabled === true && data.agent_release.image_ref === '$agent_image' && data.agent_release.instance_id === '$agent_instance_id' && data.agent_release.model_profiles_sha256.length === 64 && data.updater_release.version === 'v1.0.8' && data.updater_release.sha256 === '04ec14457b59430042d1340bf2b2bd39fd4ecc38d55892ea09b38012a069969b'"
userdata_file=$(json_get "$STATE_JSON" resources.user_data)
bootstrap_file=$(json_get "$STATE_JSON" resources.lightsail_bootstrap_script)
bootstrap_sha256=$(json_get "$STATE_JSON" resources.lightsail_bootstrap_sha256)
bootstrap_nonce_file=$(json_get "$STATE_JSON" resources.lightsail_bootstrap_nonce_file)
known_hosts_file=$(json_get "$STATE_JSON" resources.lightsail_ssh_known_hosts)
grep -q '^#!/bin/bash' "$userdata_file" || {
  echo "Lightsail launcher must be shell user-data, not cloud-config" >&2
  sed -n '1,12p' "$userdata_file" >&2
  exit 1
}
[ "$(wc -c < "$userdata_file" | tr -d '[:space:]')" -lt 512 ] || {
  echo "Lightsail launcher must remain minimal" >&2
  exit 1
}
if grep -q 'bundle.tar.gz\|AGENT_IMAGE' "$userdata_file"; then
  echo "Lightsail launcher must not contain the full bootstrap payload" >&2
  exit 1
fi
grep -q 'nonce_tmp=\$(mktemp /var/lib/dirextalk-bootstrap/.nonce.XXXXXX)' "$userdata_file"
grep -q 'mv -f "\$nonce_tmp" /var/lib/dirextalk-bootstrap/nonce' "$userdata_file"
grep -F -q "AGENT_IMAGE=$agent_image" "$bootstrap_file"
grep -F -q "AGENT_INSTANCE_ID=$agent_instance_id" "$bootstrap_file"
grep -F -q 'updater/bootstrap-host.sh "${1:-}"' "$bootstrap_file"
bash -n "$bootstrap_file"
[ "$(_s3_file_sha256 "$bootstrap_file")" = "$bootstrap_sha256" ]
[ "$(_lightsail_bootstrap_nonce_read "$bootstrap_nonce_file")" != '' ]
[ -s "$known_hosts_file" ]
cmp "$userdata_file" "$TMPDIR/lightsail-launch-user-data"
cmp "$bootstrap_file" "$TMPDIR/lightsail-bootstrap.stdin"
cmp "$secret_source" "$TMPDIR/lightsail-secret.stdin"
if grep -F -q "$secret_value" "$CALLS" "$STATE_JSON" "$userdata_file" "$bootstrap_file"; then
  echo "mounted Agent secret must stay out of state, launch data, bootstrap, and SSH arguments" >&2
  exit 1
fi
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
grep -q '^ssh-enroll$' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -q '^ssh-bootstrap$' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
grep -F -q "AGENT_IMAGE=$agent_image" "$TMPDIR/lightsail-bootstrap.stdin"
grep -F -q "AGENT_INSTANCE_ID=$agent_instance_id" "$TMPDIR/lightsail-bootstrap.stdin"
grep -q '^ssh .*ubuntu@203\.0\.113\.144.*tar.*reconcile-host\.sh.*203\.0\.113\.144' "$CALLS" || { cat "$CALLS" >&2; exit 1; }
static_ip_line=$(grep -n '^aws lightsail get-static-ip .*--query staticIp.ipAddress' "$CALLS" | cut -d: -f1 | head -n1)
enroll_line=$(grep -n '^ssh-enroll$' "$CALLS" | cut -d: -f1 | head -n1)
bootstrap_line=$(grep -n '^ssh-bootstrap$' "$CALLS" | cut -d: -f1 | head -n1)
upload_line=$(grep -n '^ssh .*reconcile-host\.sh' "$CALLS" | cut -d: -f1 | head -n1)
secret_line=$(grep -n '^ssh-secret-delivery$' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^dns-check ' "$CALLS" | cut -d: -f1 | head -n1)
[ "$bootstrap_line" -gt 1 ] && sed -n "$((bootstrap_line - 1))p" "$CALLS" | grep -q 'StrictHostKeyChecking=yes' || {
  echo "Lightsail root bootstrap must use the nonce-verified pinned host key" >&2
  cat "$CALLS" >&2
  exit 1
}
[ "$secret_line" -gt 1 ] && sed -n "$((secret_line - 1))p" "$CALLS" | grep -q 'StrictHostKeyChecking=yes' || {
  echo "mounted Agent secret delivery must use the pinned SSH host key" >&2
  cat "$CALLS" >&2
  exit 1
}
[ "$static_ip_line" -lt "$enroll_line" ] && [ "$enroll_line" -lt "$bootstrap_line" ] && [ "$bootstrap_line" -lt "$upload_line" ] && [ "$upload_line" -lt "$secret_line" ] && [ "$secret_line" -lt "$dns_line" ] || {
  echo "Lightsail bootstrap, updater upload, and secret delivery must complete before DNS gating" >&2
  cat "$CALLS" >&2
  exit 1
}
before_bootstrap=$(grep -c '^ssh-bootstrap$' "$CALLS")
_bootstrap_lightsail_host 203.0.113.144 "$(res_get key_file)" "$bootstrap_file" "$(_lightsail_bootstrap_nonce_read "$bootstrap_nonce_file")"
after_bootstrap=$(grep -c '^ssh-bootstrap$' "$CALLS")
[ "$after_bootstrap" -eq $((before_bootstrap + 1)) ] || { echo "Lightsail bootstrap must be idempotently retryable" >&2; exit 1; }
before_mismatch=$(grep -c '^ssh-bootstrap$' "$CALLS")
if DIREXTALK_FAKE_NONCE=not-the-recorded-nonce DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=1 _bootstrap_lightsail_host 203.0.113.144 "$(res_get key_file)" "$bootstrap_file" "$(_lightsail_bootstrap_nonce_read "$bootstrap_nonce_file")"; then
  echo "mismatched Lightsail SSH identity nonce must fail closed" >&2
  exit 1
fi
after_mismatch=$(grep -c '^ssh-bootstrap$' "$CALLS")
[ "$after_mismatch" -eq "$before_mismatch" ] || { echo "mismatched Lightsail SSH identity must not stream root bootstrap code" >&2; exit 1; }
cp "$CALLS" "$tmp/initial-aws.calls"
frozen_sha=$(_s3_file_sha256 "$bootstrap_file")
: > "$CALLS"
set +e
AGENT_MOUNTED_SECRET_FILE="$secret_source" AGENT_MOUNTED_SECRET_NAME=test-token DIREXTALK_FAKE_SECRET_DELIVERY_FAILURE=1 run_phase > "$tmp/s3-secret-delivery-failure.out" 2>&1
secret_delivery_rc=$?
set -e
[ "$secret_delivery_rc" -eq 1 ] || {
  cat "$tmp/s3-secret-delivery-failure.out" >&2
  echo "failed mounted Agent secret delivery must stop S3" >&2
  exit 1
}
if grep -q '^dns-check ' "$CALLS"; then
  echo "failed mounted Agent secret delivery must stop before DNS gating" >&2
  cat "$CALLS" >&2
  exit 1
fi
: > "$CALLS"
if DIREXTALK_FAKE_INSTANCE_LOOKUP_FAILURE=1 run_phase > "$tmp/s3-ambiguous-instance.out" 2>&1; then
  echo "ambiguous Lightsail instance lookup must fail closed" >&2
  exit 1
fi
[ "$(_s3_file_sha256 "$bootstrap_file")" = "$frozen_sha" ] || { echo "ambiguous instance lookup must not replace frozen bootstrap" >&2; exit 1; }
[ -s "$known_hosts_file" ] || { echo "ambiguous instance lookup must preserve pinned host key" >&2; exit 1; }
if grep -q 'lightsail create-instances' "$CALLS"; then
  echo "ambiguous Lightsail instance lookup must not create a replacement instance" >&2
  cat "$CALLS" >&2
  exit 1
fi
: > "$CALLS"
rm -f "$known_hosts_file" "$tmp/fake-enroll-not-ready.once" "$tmp/fake-enroll-empty.once"
if ! DIREXTALK_INSTALL_SCRIPTS_DIR="$invalid_scripts" DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=3 DIREXTALK_BOOTSTRAP_SSH_DELAY=0 DIREXTALK_FAKE_ENROLL_NOT_READY_ONCE=1 DIREXTALK_FAKE_ENROLL_EMPTY_ONCE=1 run_phase > "$tmp/s3-frozen-resume.out" 2>&1; then
  cat "$tmp/s3-frozen-resume.out" >&2
  echo "existing Lightsail instance must reuse its frozen bootstrap artifact and retry host-key enrollment" >&2
  exit 1
fi
[ "$(_s3_file_sha256 "$bootstrap_file")" = "$frozen_sha" ] || { echo "Lightsail resume must not replace its frozen bootstrap artifact" >&2; exit 1; }
[ -s "$known_hosts_file" ] || { echo "Lightsail resume must re-enroll the host key through its persisted nonce" >&2; exit 1; }
[ -f "$tmp/fake-enroll-not-ready.once" ] && [ -f "$tmp/fake-enroll-empty.once" ] || { echo "Lightsail enrollment must retry both unavailable and empty nonce responses" >&2; exit 1; }
[ "$(grep -c '^ssh-enroll$' "$CALLS")" -ge 3 ] || { echo "Lightsail enrollment should retry before streaming bootstrap" >&2; cat "$CALLS" >&2; exit 1; }
before=$(grep -c '^ssh ' "$CALLS")
_resume_host_bootstrap 203.0.113.144 "$(res_get key_file)"
after=$(grep -c '^ssh ' "$CALLS")
[ "$after" -eq $((before + 1)) ] || { echo "host bootstrap resume must be idempotently retryable" >&2; exit 1; }
grep -q 'fromPort=49160\\,toPort=49200\\,protocol=udp' "$tmp/initial-aws.calls" || { cat "$tmp/initial-aws.calls" >&2; exit 1; }
if grep -q '^aws ec2 ' "$tmp/initial-aws.calls"; then
  echo "Lightsail provisioning must not call EC2 APIs" >&2
  cat "$tmp/initial-aws.calls" >&2
  exit 1
fi

echo "s3 lightsail provision ok"
