#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_WORKDIR="$tmp/work"
export CALLS="$tmp/calls"
export AWS_DEFAULT_REGION=ap-northeast-3
export DIREXTALK_CLOUD_PROVIDER=ec2
export INSTANCE_TYPE=t3.small
export EC2_ATTACHED="$tmp/ec2.attached"
export LAUNCH_USER_DATA="$tmp/ec2-launch-user-data"
export REMOTE_NONCE="$tmp/remote-nonce"
export ECR_REMOTE_SCRIPT="$tmp/ecr-remote-script"
export ECR_PASSWORD_STDIN="$tmp/ecr-password-stdin"
export SECRET_STDIN="$tmp/secret-stdin"
export AGENT_AWS_IMPORT_PAYLOAD="$tmp/agent-aws-import.tar.gz"
export AGENT_AWS_IMPORT_REMOTE_APPLIED="$tmp/agent-aws-import.remote-applied"
export AGENT_AWS_IMPORT_FAIL_ONCE_FILE="$tmp/agent-aws-import.fail-once"
export AGENT_AWS_IMPORT_AMBIGUOUS_ONCE_FILE="$tmp/agent-aws-import.ambiguous-once"
export FAKE_CALLER_ACCOUNT=123456789012
export FAKE_CALLER_ARN=arn:aws:iam::123456789012:root
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
: > "$CALLS"

cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    case "$*" in
      *"--query Account"*) printf '%s\n' "$FAKE_CALLER_ACCOUNT" ;;
      *"--query Arn"*) printf '%s\n' "$FAKE_CALLER_ARN" ;;
      *) printf '{"Account":"%s","Arn":"%s"}\n' "$FAKE_CALLER_ACCOUNT" "$FAKE_CALLER_ARN" ;;
    esac
    ;;
  "sts get-federation-token")
    printf '%s\n' '{"AccessKeyId":"TESTSESSIONACCESS","SecretAccessKey":"TESTSESSIONSECRET","SessionToken":"TESTSESSIONTOKEN","Expiration":"2030-01-01T00:00:00Z"}'
    ;;
  "ecr get-login-password")
    [ -f "$AWS_SHARED_CREDENTIALS_FILE" ]
    grep -q 'aws_access_key_id = TESTSESSIONACCESS' "$AWS_SHARED_CREDENTIALS_FILE"
    grep -q 'aws_secret_access_key = TESTSESSIONSECRET' "$AWS_SHARED_CREDENTIALS_FILE"
    grep -q 'aws_session_token = TESTSESSIONTOKEN' "$AWS_SHARED_CREDENTIALS_FILE"
    printf '%s\n' 'test-only-ecr-password'
    ;;
  "ec2 create-key-pair") printf 'test-private-key\n' ;;
  "ec2 create-security-group") printf 'sg-test\n' ;;
  "ec2 authorize-security-group-ingress"|"ec2 wait") ;;
  "ec2 associate-address") touch "$EC2_ATTACHED" ;;
  "ec2 run-instances")
    launch_ref=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --user-data) launch_ref=${2#file://}; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "$launch_ref" "$LAUNCH_USER_DATA"
    grep -Eo '[0-9a-f]{64}' "$launch_ref" | head -n 1 > "$REMOTE_NONCE"
    printf 'i-test\n'
    ;;
  "ec2 describe-instances")
    case "$*" in
      *"State.Name"*) printf 'running\n' ;;
      *"BlockDeviceMappings"*) printf 'vol-root-test\n' ;;
      *) printf 'running\n' ;;
    esac
    ;;
  "ec2 allocate-address") printf 'eipalloc-test\n' ;;
  "ec2 describe-addresses")
    case "$*" in
      *InstanceId*) [ -f "$EC2_ATTACHED" ] && printf 'i-test\n' || printf 'None\n' ;;
      *PublicIp*) printf '203.0.113.155\n' ;;
    esac
    ;;
  *) echo "unexpected aws command: $*" >&2; exit 1 ;;
esac
EOF

cat > "$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp-called\n' >> "$CALLS"
exit 97
EOF

cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
all=$*
known_hosts=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = -o ] && [ $((i + 1)) -lt ${#args[@]} ]; then
    case "${args[$((i + 1))]}" in
      UserKnownHostsFile=*) known_hosts=${args[$((i + 1))]#UserKnownHostsFile=} ;;
    esac
  fi
done
if [[ "$all" == *"/bin/cat /var/lib/dirextalk-bootstrap/nonce"* ]]; then
  printf 'ssh-enroll\n' >> "$CALLS"
  if [ -n "$known_hosts" ] && [ ! -s "$known_hosts" ]; then
    printf '203.0.113.155 ssh-ed25519 test-host-key\n' > "$known_hosts"
  fi
  if [ -n "${FAKE_NONCE_MISMATCH:-}" ]; then
    printf '%064d\n' 0
  else
    cat "$REMOTE_NONCE"
  fi
elif [[ "$all" == *"/bin/bash -s --"* ]]; then
  printf 'ssh-bootstrap\n' >> "$CALLS"
  cat > "$TMPDIR/ec2-bootstrap.stdin"
elif [[ "$all" == *"reconcile-host.sh"* ]]; then
  printf 'ssh-updater-stage\n' >> "$CALLS"
  cat > "$TMPDIR/ec2-updater-integration.tar.gz"
  printf 'v1.0.10\ta8971d7b04e8fef29b35ef889cc1b70d7ceca7a5\t730f3d1e4c6f604069e1b6eed60121bffb47f32d2f1d960cb3f8a0121974b6b8\n'
elif [[ "$all" == *"reconcile-agent-aws-control.sh"* ]]; then
  printf 'ssh-agent-aws-import\n' >> "$CALLS"
  cat > "$AGENT_AWS_IMPORT_PAYLOAD"
  if [ -e "$AGENT_AWS_IMPORT_FAIL_ONCE_FILE" ]; then
    rm -f "$AGENT_AWS_IMPORT_FAIL_ONCE_FILE"
    exit 86
  fi
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  tar -xzf "$AGENT_AWS_IMPORT_PAYLOAD" -C "$stage"
  compose_sha=$(sha256sum "$stage/docker-compose.yml" | awk '{print $1}')
  publication_sha=$(sha256sum "$stage/agent-worker-ami-publication.json" | awk '{print $1}')
  if [ ! -e "$AGENT_AWS_IMPORT_REMOTE_APPLIED" ]; then
    touch "$AGENT_AWS_IMPORT_REMOTE_APPLIED"
    printf 'agent-aws-import-mutation\n' >> "$CALLS"
    printf 'agent-aws-import-restart\n' >> "$CALLS"
    if [ -e "$AGENT_AWS_IMPORT_AMBIGUOUS_ONCE_FILE" ]; then
      rm -f "$AGENT_AWS_IMPORT_AMBIGUOUS_ONCE_FILE"
      exit 255
    fi
    printf 'applied\t%s\t%s\trestarted\n' "$compose_sha" "$publication_sha"
  else
    printf 'agent-aws-import-readback\n' >> "$CALLS"
    printf 'applied\t%s\t%s\treadback\n' "$compose_sha" "$publication_sha"
  fi
elif [[ "$all" == *"dirextalk-ecr-pull"* ]]; then
  printf 'ssh-ecr-auth\n' >> "$CALLS"
  cat > "$ECR_PASSWORD_STDIN"
  payload=$(printf '%s\n' "$all" | sed -n "s/.*printf '%s' '\([^']*\)'.*/\1/p")
  [ -n "$payload" ]
  printf '%s' "$payload" | base64 --decode > "$ECR_REMOTE_SCRIPT"
  printf 'v1.0.10\ta8971d7b04e8fef29b35ef889cc1b70d7ceca7a5\t730f3d1e4c6f604069e1b6eed60121bffb47f32d2f1d960cb3f8a0121974b6b8\tecr-auth-clean=true\n'
elif [[ "$all" == *"agent-mounted-secret-delivery"* ]]; then
  printf 'ssh-secret-delivery\n' >> "$CALLS"
  cat > "$SECRET_STDIN"
else
  echo "unexpected ssh command: $all" >&2
  exit 1
fi
EOF
chmod 0700 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export TMPDIR="$tmp"

agent_image='123456789012.dkr.ecr.ap-northeast-3.amazonaws.com/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
message_image='dirextalk/message-server:v1.2.3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
agent_instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
agent_profiles="$tmp/model-profiles.json"
worker_publication="$tmp/worker-ami-publication.json"
worker_publication_changed="$tmp/worker-ami-publication-changed.json"
secret_source="$tmp/operator-mounted-secret"
secret_value='test-only-mounted-secret'
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"test-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$agent_profiles"
printf '%s\n' "$secret_value" > "$secret_source"
export AGENT_IMAGE="$agent_image"
export AGENT_INSTANCE_ID="$agent_instance_id"
export AGENT_MODEL_PROFILES_FILE="$agent_profiles"
export AGENT_MOUNTED_SECRET_NAME=test-token
export AGENT_MOUNTED_SECRET_FILE="$secret_source"
export DIREXTALK_MESSAGE_SERVER_RELEASE_IMAGE="$message_image"
export AGENT_ENABLE_AWS_CONTROL=true
export AGENT_AWS_REAPER_IMAGE_URI='123456789012.dkr.ecr.ap-northeast-3.amazonaws.com/dirextalk-aws-reaper:v0.1.0-alpha.20260718.1-abcdef123456@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
export AGENT_WORKER_CONTROL_ENDPOINT='grpcs://worker-control.example.test:443'
export AGENT_ENABLE_MANAGED_PREPARATION_AWS=false
unset AGENT_WORKER_AMI_PUBLICATION_FILE

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region ap-northeast-3
state_set domain ec2.example.test
state_set domain_mode user
res_set ami_id ami-test
res_set vpc_id vpc-test

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"
domain_resolves_to_ip() {
  printf 'dns-check %s %s\n' "$1" "$2" >> "$CALLS"
  return 0
}

run_phase > "$tmp/s3.out" 2>&1 || { cat "$tmp/s3.out" >&2; exit 1; }
json_test_check "$STATE_JSON" "data.cloud_provider === 'ec2' && data.phases.S3_PROVISION.status === 'done' && data.resources.eip_id === 'eipalloc-test' && data.resources.public_ip === '203.0.113.155' && data.resources.root_volume_id === 'vol-root-test' && data.resources.ec2_client_token.length === 64 && data.resources.agent_registry_auth_cleanup_verified === 'true' && data.server_release.source === 'immutable_release' && data.server_release.image_ref === '$message_image' && data.agent_release.image_ref === '$agent_image' && data.agent_registry.source === 'private_ecr' && data.agent_registry.repository === 'dirextalk-agent' && data.agent_registry.auth_mode === 'federation_token' && data.agent_aws_control.source === 'operator_configuration' && data.agent_aws_control.enabled === true && data.agent_aws_control.aws_reaper_image_uri === '$AGENT_AWS_REAPER_IMAGE_URI' && data.agent_aws_control.worker_control_endpoint === '$AGENT_WORKER_CONTROL_ENDPOINT' && data.agent_aws_control.managed_preparation_aws === false && data.agent_aws_control.worker_ami_publication_snapshot_file === '' && data.agent_aws_control.worker_ami_publication_sha256 === '' && data.updater_release.version === 'v1.0.10'"
snapshot_file=$(json_get "$STATE_JSON" agent_aws_control.worker_ami_publication_snapshot_file)
[ -z "$snapshot_file" ]
[ ! -e "$DIREXTALK_WORKDIR/agent-worker-ami-publication.json" ]
if grep -Eiq 'aws_access_key_id|aws_secret_access_key|aws_session_token|TESTSESSION(ACCESS|SECRET|TOKEN)' "$STATE_JSON"; then
  echo "EC2 Agent AWS control state persisted credential material" >&2
  exit 1
fi

userdata_file=$(json_get "$STATE_JSON" resources.user_data)
bootstrap_file=$(json_get "$STATE_JSON" resources.ec2_bootstrap_script)
bootstrap_sha256=$(json_get "$STATE_JSON" resources.ec2_bootstrap_sha256)
nonce_file=$(json_get "$STATE_JSON" resources.ec2_bootstrap_nonce_file)
known_hosts=$(json_get "$STATE_JSON" resources.ec2_ssh_known_hosts)
[ -s "$userdata_file" ] && [ -s "$bootstrap_file" ] && [ -s "$nonce_file" ] && [ -s "$known_hosts" ]
[ "$(wc -c < "$userdata_file" | tr -d '[:space:]')" -lt 512 ]
cmp "$userdata_file" "$LAUNCH_USER_DATA"
cmp "$bootstrap_file" "$TMPDIR/ec2-bootstrap.stdin"
[ "$(_s3_file_sha256 "$bootstrap_file")" = "$bootstrap_sha256" ]
grep -F -q "AGENT_IMAGE=$agent_image" "$bootstrap_file"
grep -F -q "MESSAGE_SERVER_IMAGE=$message_image" "$bootstrap_file"
grep -q 'DIREXTALK_BOOTSTRAP_DEFER_START=1 updater/bootstrap-host.sh' "$bootstrap_file"
awk '/^base64 -d>bundle\.tar\.gz<<B$/ { capture=1; next } capture && /^B$/ { exit } capture { print }' "$bootstrap_file" | base64 -d > "$tmp/ec2-bundle.tar.gz"
mkdir "$tmp/ec2-bundle"
tar -xzf "$tmp/ec2-bundle.tar.gz" -C "$tmp/ec2-bundle"
grep -F -q "AGENT_AWS_REAPER_IMAGE_URI: \"$AGENT_AWS_REAPER_IMAGE_URI\"" "$tmp/ec2-bundle/docker-compose.yml"
grep -F -q "AGENT_WORKER_CONTROL_ENDPOINT: \"$AGENT_WORKER_CONTROL_ENDPOINT\"" "$tmp/ec2-bundle/docker-compose.yml"
grep -q 'AGENT_ENABLE_MANAGED_PREPARATION_AWS: "false"' "$tmp/ec2-bundle/docker-compose.yml"
if [ -e "$tmp/ec2-bundle/agent-worker-ami-publication.json" ] \
    || grep -q 'AGENT_WORKER_AMI_PUBLICATION_FILE\|agent-worker-ami-publication.json:/run/dirextalk-agent' "$tmp/ec2-bundle/docker-compose.yml"; then
  echo "phase-1 EC2 Agent bootstrap included a Worker-AMI publication or mount" >&2
  exit 1
fi
if grep -Eq 'bundle\.tar\.gz|AGENT_IMAGE|MESSAGE_SERVER_IMAGE|docker|updater|ecr|AWS_' "$userdata_file"; then
  echo "EC2 launch user-data must contain only the identity nonce launcher" >&2
  exit 1
fi

cmp "$secret_source" "$SECRET_STDIN"
[ "$(tr -d '\r\n' < "$ECR_PASSWORD_STDIN")" = test-only-ecr-password ]
grep -q '^auth_dir=/run/dirextalk-ecr-auth$' "$ECR_REMOTE_SCRIPT"
grep -q 'docker --config "$auth_dir" login --username AWS --password-stdin' "$ECR_REMOTE_SCRIPT"
grep -q 'DOCKER_CONFIG="$auth_dir" /bin/bash .*bootstrap-host.sh' "$ECR_REMOTE_SCRIPT"
grep -q 'docker --config "$auth_dir" logout' "$ECR_REMOTE_SCRIPT"
grep -q 'rm -rf -- "$auth_dir"' "$ECR_REMOTE_SCRIPT"
grep -q '\[ ! -e "$auth_dir" \]' "$ECR_REMOTE_SCRIPT"

if grep -F -q "$secret_value" "$CALLS" "$STATE_JSON" "$userdata_file" "$bootstrap_file" "$ECR_REMOTE_SCRIPT"; then
  echo "mounted Agent secret leaked outside SSH stdin" >&2
  exit 1
fi
if grep -Eq 'TESTSESSION(ACCESS|SECRET|TOKEN)|test-only-ecr-password' "$CALLS" "$STATE_JSON" "$userdata_file" "$bootstrap_file"; then
  echo "STS or ECR credentials leaked into state, user-data, bootstrap, or argv log" >&2
  exit 1
fi
if grep -q '^scp-called$\|^scp ' "$CALLS"; then
  echo "S3 must not SCP updater artifacts" >&2
  exit 1
fi

eip_line=$(grep -n '^aws ec2 describe-addresses.*PublicIp' "$CALLS" | cut -d: -f1 | head -n1)
enroll_line=$(grep -n '^ssh-enroll$' "$CALLS" | cut -d: -f1 | head -n1)
bootstrap_line=$(grep -n '^ssh-bootstrap$' "$CALLS" | cut -d: -f1 | head -n1)
stage_line=$(grep -n '^ssh-updater-stage$' "$CALLS" | cut -d: -f1 | head -n1)
ecr_line=$(grep -n '^ssh-ecr-auth$' "$CALLS" | cut -d: -f1 | head -n1)
secret_line=$(grep -n '^ssh-secret-delivery$' "$CALLS" | cut -d: -f1 | head -n1)
dns_line=$(grep -n '^dns-check ' "$CALLS" | cut -d: -f1 | head -n1)
[ "$eip_line" -lt "$enroll_line" ] && [ "$enroll_line" -lt "$bootstrap_line" ] \
  && [ "$bootstrap_line" -lt "$stage_line" ] && [ "$stage_line" -lt "$ecr_line" ] \
  && [ "$ecr_line" -lt "$secret_line" ] && [ "$secret_line" -lt "$dns_line" ] || {
  echo "EC2 secure bootstrap/auth/secret/DNS ordering is unsafe" >&2
  cat "$CALLS" >&2
  exit 1
}
awk '/^ssh / && /ssh-(bootstrap|updater|ecr|secret)/ { next }' "$CALLS" >/dev/null
for marker in ssh-bootstrap ssh-updater-stage ssh-ecr-auth ssh-secret-delivery; do
  line=$(grep -n "^$marker$" "$CALLS" | cut -d: -f1 | head -n1)
  [ "$line" -gt 1 ] && sed -n "$((line - 1))p" "$CALLS" | grep -q 'StrictHostKeyChecking=yes' || {
    echo "$marker did not use the pinned SSH host key" >&2
    exit 1
  }
done

# A lost run-instances response/resume reuses both the exact frozen bootstrap
# and EC2 client token, while pre-cleaning and obtaining fresh ECR auth.
first_bootstrap_sha=$(_s3_file_sha256 "$bootstrap_file")
first_client_token=$(json_get "$STATE_JSON" resources.ec2_client_token)
res_set instance_id ""
run_phase > "$tmp/s3-resume.out" 2>&1 || { cat "$tmp/s3-resume.out" >&2; exit 1; }
[ "$(_s3_file_sha256 "$bootstrap_file")" = "$first_bootstrap_sha" ]
[ "$(grep -c '^aws ec2 run-instances' "$CALLS")" = 2 ]
[ "$(json_get "$STATE_JSON" resources.ec2_client_token)" = "$first_client_token" ]
[ "$(grep '^aws ec2 run-instances' "$CALLS" | grep -c -- "--client-token $first_client_token")" = 2 ]
[ "$(grep -c '^aws sts get-federation-token' "$CALLS")" -ge 2 ]
[ "$(grep -c '^ssh-ecr-auth$' "$CALLS")" -ge 2 ]
grep -q '# Lost-response resume always removes any prior auth directory' "$ECR_REMOTE_SCRIPT"

# The explicit phase-2 transition validates and durably prepares the frozen
# publication before any remote call, and never makes an AWS API call.
export AGENT_ENABLE_MANAGED_PREPARATION_AWS=true
unset AGENT_WORKER_AMI_PUBLICATION_FILE
before_import_calls=$(wc -l < "$CALLS")
if agent_aws_control_import_ec2 > "$tmp/agent-aws-import-missing.out" 2>&1; then
  echo "Agent AWS-control import accepted a missing Worker-AMI publication" >&2
  exit 1
fi
[ "$(wc -l < "$CALLS")" = "$before_import_calls" ]

printf '%s\n' '{"schema_version":"dirextalk.agent.worker-ami-publication/v1","image_manifest":{"schema_version":"dirextalk.agent.worker-ami/v1","agent_instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","image_id":"ami-0123456789abcdef0","image_name":"dtx-worker-ami-0123456789abcdef0123","root_snapshot_id":"snap-0123456789abcdef0","account_id":"123456789012","region":"ap-northeast-3","architecture":"amd64","base_ami_id":"ami-0abcdef0123456789","base_ami_owner_id":"099720109477","root_device_name":"/dev/sda1","release_manifest_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","worker_rootfs_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","worker_binary_digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333","created_at":"2026-07-16T08:00:00Z"},"image_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","attestation":{"schema_version":1,"agent_instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","ami_id":"ami-0123456789abcdef0","root_snapshot_id":"snap-0123456789abcdef0","account_id":"123456789012","region":"ap-northeast-3","architecture":"amd64","release_manifest_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","worker_rootfs_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","worker_binary_digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333","observed_at":"2026-07-16T08:01:00Z"}}' > "$worker_publication"
export AGENT_WORKER_AMI_PUBLICATION_FILE="$worker_publication"
before_import_calls=$(wc -l < "$CALLS")
if AGENT_WORKER_CONTROL_ENDPOINT='grpcs://drift.example.test:443' agent_aws_control_import_ec2 > "$tmp/agent-aws-import-core-drift.out" 2>&1; then
  echo "Agent AWS-control import accepted changed core wiring" >&2
  exit 1
fi
[ "$(wc -l < "$CALLS")" = "$before_import_calls" ]

aws_calls_before_import=$(grep -c '^aws ' "$CALLS")
touch "$AGENT_AWS_IMPORT_FAIL_ONCE_FILE"
if DIREXTALK_AGENT_AWS_IMPORT_ATTEMPTS=1 DIREXTALK_AGENT_AWS_IMPORT_DELAY_SECONDS=0 \
    agent_aws_control_import_ec2 > "$tmp/agent-aws-import-failed.out" 2>&1; then
  echo "Agent AWS-control import unexpectedly succeeded after a remote failure" >&2
  exit 1
fi
json_test_check "$STATE_JSON" "data.agent_aws_control.managed_preparation_aws === false && data.agent_aws_control.worker_ami_publication_snapshot_file === '' && data.agent_aws_control_import.status === 'prepared' && data.agent_aws_control_import.target_managed_preparation_aws === true && data.agent_aws_control_import.worker_ami_publication_sha256.length === 64"
[ ! -e "$AGENT_AWS_IMPORT_REMOTE_APPLIED" ]
[ "$(grep -c '^ssh-agent-aws-import$' "$CALLS")" = 1 ]
[ "$(grep -c '^aws ' "$CALLS")" = "$aws_calls_before_import" ]

# A lost success response is recovered by readback. The frozen transition is
# mutated and restarted once even though the transport is retried.
touch "$AGENT_AWS_IMPORT_AMBIGUOUS_ONCE_FILE"
DIREXTALK_AGENT_AWS_IMPORT_ATTEMPTS=3 DIREXTALK_AGENT_AWS_IMPORT_DELAY_SECONDS=0 \
  agent_aws_control_import_ec2 > "$tmp/agent-aws-import-ambiguous.out" 2>&1 \
  || { cat "$tmp/agent-aws-import-ambiguous.out" >&2; exit 1; }
[ "$(grep -c '^agent-aws-import-mutation$' "$CALLS")" = 1 ]
[ "$(grep -c '^agent-aws-import-restart$' "$CALLS")" = 1 ]
[ "$(grep -c '^agent-aws-import-readback$' "$CALLS")" -ge 1 ]
[ "$(grep -c '^ssh-agent-aws-import$' "$CALLS")" -ge 3 ]
[ "$(grep -c '^aws ' "$CALLS")" = "$aws_calls_before_import" ]
json_test_check "$STATE_JSON" "data.agent_aws_control.enabled === true && data.agent_aws_control.managed_preparation_aws === true && data.agent_aws_control.worker_ami_publication_snapshot_file === '$DIREXTALK_WORKDIR/agent-worker-ami-publication.json' && data.agent_aws_control.worker_ami_publication_sha256.length === 64 && data.agent_aws_control_import.status === 'applied' && data.agent_aws_control_import.worker_ami_publication_sha256 === data.agent_aws_control.worker_ami_publication_sha256"
snapshot_file=$(json_get "$STATE_JSON" agent_aws_control.worker_ami_publication_snapshot_file)
cmp "$worker_publication" "$snapshot_file"

mkdir "$tmp/agent-aws-import-bundle"
tar -xzf "$AGENT_AWS_IMPORT_PAYLOAD" -C "$tmp/agent-aws-import-bundle"
cmp "$worker_publication" "$tmp/agent-aws-import-bundle/agent-worker-ami-publication.json"
grep -F -q "AGENT_AWS_REAPER_IMAGE_URI: \"$AGENT_AWS_REAPER_IMAGE_URI\"" "$tmp/agent-aws-import-bundle/docker-compose.yml"
grep -F -q "AGENT_WORKER_CONTROL_ENDPOINT: \"$AGENT_WORKER_CONTROL_ENDPOINT\"" "$tmp/agent-aws-import-bundle/docker-compose.yml"
grep -q 'AGENT_ENABLE_MANAGED_PREPARATION_AWS: "true"' "$tmp/agent-aws-import-bundle/docker-compose.yml"
grep -q './agent-worker-ami-publication.json:/run/dirextalk-agent/worker-ami-publication.json:ro' "$tmp/agent-aws-import-bundle/docker-compose.yml"

# A later transport failure cannot downgrade an already-applied journal.
touch "$AGENT_AWS_IMPORT_FAIL_ONCE_FILE"
if DIREXTALK_AGENT_AWS_IMPORT_ATTEMPTS=1 DIREXTALK_AGENT_AWS_IMPORT_DELAY_SECONDS=0 \
    agent_aws_control_import_ec2 > "$tmp/agent-aws-import-applied-transport-failure.out" 2>&1; then
  echo "Agent AWS-control retry unexpectedly succeeded through a forced transport failure" >&2
  exit 1
fi
json_test_check "$STATE_JSON" "data.agent_aws_control.managed_preparation_aws === true && data.agent_aws_control_import.status === 'applied'"

mutation_count=$(grep -c '^agent-aws-import-mutation$' "$CALLS")
restart_count=$(grep -c '^agent-aws-import-restart$' "$CALLS")
readback_count=$(grep -c '^agent-aws-import-readback$' "$CALLS")
DIREXTALK_AGENT_AWS_IMPORT_DELAY_SECONDS=0 agent_aws_control_import_ec2 > "$tmp/agent-aws-import-retry.out" 2>&1 \
  || { cat "$tmp/agent-aws-import-retry.out" >&2; exit 1; }
[ "$(grep -c '^agent-aws-import-mutation$' "$CALLS")" = "$mutation_count" ]
[ "$(grep -c '^agent-aws-import-restart$' "$CALLS")" = "$restart_count" ]
[ "$(grep -c '^agent-aws-import-readback$' "$CALLS")" -gt "$readback_count" ]
[ "$(grep -c '^aws ' "$CALLS")" = "$aws_calls_before_import" ]

sed 's/"observed_at":"2026-07-16T08:01:00Z"/"observed_at":"2026-07-16T08:02:00Z"/' "$worker_publication" > "$worker_publication_changed"
before_drift_calls=$(wc -l < "$CALLS")
if AGENT_WORKER_AMI_PUBLICATION_FILE="$worker_publication_changed" agent_aws_control_import_ec2 > "$tmp/agent-aws-import-publication-drift.out" 2>&1; then
  echo "Agent AWS-control import accepted changed Worker-AMI publication bytes" >&2
  exit 1
fi
[ "$(wc -l < "$CALLS")" = "$before_drift_calls" ]
cmp "$worker_publication" "$snapshot_file"

before_drift_calls=$(wc -l < "$CALLS")
if AGENT_ENABLE_MANAGED_PREPARATION_AWS=false agent_aws_control_import_ec2 > "$tmp/agent-aws-import-revert.out" 2>&1; then
  echo "Agent AWS-control import allowed the managed transition to be reverted" >&2
  exit 1
fi
[ "$(wc -l < "$CALLS")" = "$before_drift_calls" ]

# Mismatched first-contact nonce must never pin or stream root bootstrap code.
res_set ec2_ssh_known_hosts ""
mismatch_known="$DIREXTALK_WORKDIR/ec2-mismatch-known-hosts"
rm -f "$mismatch_known"
res_set ec2_ssh_known_hosts "$mismatch_known"
before_bootstrap_count=$(grep -c '^ssh-bootstrap$' "$CALLS")
export FAKE_NONCE_MISMATCH=1
if _bootstrap_ec2_host 203.0.113.155 "$(json_get "$STATE_JSON" resources.key_file)" "$bootstrap_file" "$(_bootstrap_nonce_read "$nonce_file")" > "$tmp/nonce-mismatch.out" 2>&1; then
  echo "EC2 bootstrap accepted a mismatched host identity nonce" >&2
  exit 1
fi
unset FAKE_NONCE_MISMATCH
[ "$(grep -c '^ssh-bootstrap$' "$CALLS")" = "$before_bootstrap_count" ]
[ ! -e "$mismatch_known" ]

echo "s3 EC2 secure bootstrap and private ECR pull ok"
