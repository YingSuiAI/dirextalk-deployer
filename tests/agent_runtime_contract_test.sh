#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DIREXTALK_WORKDIR="$tmp/work"
mkdir -p "$DIREXTALK_WORKDIR"

# Use the production strict publication/snapshot helper. The state JSON builder
# is replaced below with the deliberately small in-memory test double.
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/json.sh"

image='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
lightsail_message_image='dirextalk/z3-message-server-20260718:v0.1.0-alpha.20260718.1-0258d0a493ad@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
changed_image='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.2-bbbbbbbbbbbb@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
profiles="$tmp/model-profiles.json"
changed_profiles="$tmp/model-profiles-changed.json"
unsafe_profiles="$tmp/model-profiles-unsafe.json"
worker_publication="$tmp/worker-ami-publication.json"
unsafe_worker_publication="$tmp/worker-ami-publication-unsafe.json"
malformed_worker_publication="$tmp/worker-ami-publication-malformed.json"
symlink_worker_publication="$tmp/worker-ami-publication-symlink.json"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"test-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$profiles"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"changed-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$changed_profiles"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"unsafe-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","api_key":"not-a-real-provider-token"}]}' > "$unsafe_profiles"
printf '%s\n' '{"schema_version":"dirextalk.agent.worker-ami-publication/v1","image_manifest":{"schema_version":"dirextalk.agent.worker-ami/v1","agent_instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","image_id":"ami-0123456789abcdef0","image_name":"dtx-worker-ami-0123456789abcdef0123","root_snapshot_id":"snap-0123456789abcdef0","account_id":"123456789012","region":"us-east-1","architecture":"amd64","base_ami_id":"ami-0abcdef0123456789","base_ami_owner_id":"099720109477","root_device_name":"/dev/sda1","release_manifest_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","worker_rootfs_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","worker_binary_digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333","created_at":"2026-07-16T08:00:00Z"},"image_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","attestation":{"schema_version":1,"agent_instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","ami_id":"ami-0123456789abcdef0","root_snapshot_id":"snap-0123456789abcdef0","account_id":"123456789012","region":"us-east-1","architecture":"amd64","release_manifest_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","worker_rootfs_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","worker_binary_digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333","observed_at":"2026-07-16T08:01:00Z"}}' > "$worker_publication"
printf '%s\n' '{"schema_version":"dirextalk.agent.worker-ami-publication/v1","image_manifest":{},"image_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","attestation":{},"aws_access_key_id":"AKIA0000000000000000"}' > "$unsafe_worker_publication"
printf '%s\n' '{"arbitrary":"content"} trailing' > "$malformed_worker_publication"
ln -s "$worker_publication" "$symlink_worker_publication"

test_source=
test_enabled=
test_image_ref=
test_instance_id=
test_profiles_sha256=
test_aws_source=
test_aws_enabled=
test_aws_reaper_image_uri=
test_worker_control_endpoint=
test_worker_control_endpoint_service_name=
test_managed_preparation_aws=
test_worker_publication_snapshot_file=
test_worker_publication_sha256=
test_infrastructure_id=
test_cloud_provider=ec2
test_import_status=
test_import_publication_snapshot_file=
test_import_publication_sha256=
test_producer_status=
test_producer_service_name=

warn() { :; }
json_build() {
  [ "$1" = object ] || return 1
  shift
  local pair key value first=1
  printf '{'
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    [ "$first" = 1 ] || printf ','
    printf '"%s":"%s"' "$key" "$value"
    first=0
  done
  printf '}'
}
state_get() {
  case "$1" in
    resources.instance_id) printf '%s' "$test_infrastructure_id" ;;
    agent_release.source) printf '%s' "$test_source" ;;
    agent_release.enabled) printf '%s' "$test_enabled" ;;
    agent_release.image_ref) printf '%s' "$test_image_ref" ;;
    agent_release.instance_id) printf '%s' "$test_instance_id" ;;
    agent_release.model_profiles_sha256) printf '%s' "$test_profiles_sha256" ;;
    agent_aws_control.source) printf '%s' "$test_aws_source" ;;
    agent_aws_control.enabled) printf '%s' "$test_aws_enabled" ;;
    agent_aws_control.aws_reaper_image_uri) printf '%s' "$test_aws_reaper_image_uri" ;;
    agent_aws_control.worker_control_endpoint) printf '%s' "$test_worker_control_endpoint" ;;
    agent_aws_control.worker_control_endpoint_service_name) printf '%s' "$test_worker_control_endpoint_service_name" ;;
    agent_aws_control.managed_preparation_aws) printf '%s' "$test_managed_preparation_aws" ;;
    agent_aws_control.worker_ami_publication_snapshot_file) printf '%s' "$test_worker_publication_snapshot_file" ;;
    agent_aws_control.worker_ami_publication_sha256) printf '%s' "$test_worker_publication_sha256" ;;
    agent_aws_control_import.status) printf '%s' "$test_import_status" ;;
    agent_aws_control_import.worker_ami_publication_snapshot_file) printf '%s' "$test_import_publication_snapshot_file" ;;
    agent_aws_control_import.worker_ami_publication_sha256) printf '%s' "$test_import_publication_sha256" ;;
    agent_worker_control.status) printf '%s' "$test_producer_status" ;;
    agent_worker_control.endpoint_service_name) printf '%s' "$test_producer_service_name" ;;
    cloud_provider) printf '%s' "$test_cloud_provider" ;;
    *) return 1 ;;
  esac
}
state_set_object() {
  local path=$1 pair key value
  shift
  [ "$path" = agent_aws_control_import ] || return 1
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    case "$key" in
      status) test_import_status=$value ;;
      worker_ami_publication_snapshot_file) test_import_publication_snapshot_file=$value ;;
      worker_ami_publication_sha256) test_import_publication_sha256=$value ;;
    esac
  done
}
state_set_raw() {
  local value=$2
  case "$1" in
    agent_release)
      test_source=$(printf '%s' "$value" | sed -nE 's/.*"source":"([^"]*)".*/\1/p')
      test_enabled=$(printf '%s' "$value" | sed -nE 's/.*"enabled":"([^"]*)".*/\1/p')
      test_image_ref=$(printf '%s' "$value" | sed -nE 's/.*"image_ref":"([^"]*)".*/\1/p')
      test_instance_id=$(printf '%s' "$value" | sed -nE 's/.*"instance_id":"([^"]*)".*/\1/p')
      test_profiles_sha256=$(printf '%s' "$value" | sed -nE 's/.*"model_profiles_sha256":"([^"]*)".*/\1/p')
      ;;
    agent_aws_control)
      test_aws_source=$(printf '%s' "$value" | sed -nE 's/.*"source":"([^"]*)".*/\1/p')
      test_aws_enabled=$(printf '%s' "$value" | sed -nE 's/.*"enabled":"([^"]*)".*/\1/p')
      test_aws_reaper_image_uri=$(printf '%s' "$value" | sed -nE 's/.*"aws_reaper_image_uri":"([^"]*)".*/\1/p')
      test_worker_control_endpoint=$(printf '%s' "$value" | sed -nE 's/.*"worker_control_endpoint":"([^"]*)".*/\1/p')
      test_worker_control_endpoint_service_name=$(printf '%s' "$value" | sed -nE 's/.*"worker_control_endpoint_service_name":"([^"]*)".*/\1/p')
      test_managed_preparation_aws=$(printf '%s' "$value" | sed -nE 's/.*"managed_preparation_aws":"([^"]*)".*/\1/p')
      test_worker_publication_snapshot_file=$(printf '%s' "$value" | sed -nE 's/.*"worker_ami_publication_snapshot_file":"([^"]*)".*/\1/p')
      test_worker_publication_sha256=$(printf '%s' "$value" | sed -nE 's/.*"worker_ami_publication_sha256":"([^"]*)".*/\1/p')
      ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/agent-release.sh"

agent_image_is_immutable "$image"
! agent_image_is_immutable 'registry.example/dirextalk-agent:latest'
! agent_image_is_immutable 'registry.example/dirextalk-agent:v1.0.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
! agent_image_is_immutable $'registry.example/dirextalk-agent:v0.1.0-alpha.1-abcdef1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nINJECTED=true'
agent_instance_id_is_canonical "$instance_id"
! agent_instance_id_is_canonical 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
! agent_instance_id_is_canonical '00000000-0000-0000-0000-000000000000'
! agent_model_profiles_file_is_safe "$unsafe_profiles"
publication_probe="$tmp/publication-probe.json"
worker_publication_sha256=$(json_worker_ami_publication_snapshot "$worker_publication" "$publication_probe")
cmp "$worker_publication" "$publication_probe"
if json_worker_ami_publication_snapshot "$unsafe_worker_publication" "$tmp/unsafe-probe.json" >/dev/null 2>&1 ||
   json_worker_ami_publication_snapshot "$malformed_worker_publication" "$tmp/malformed-probe.json" >/dev/null 2>&1 ||
   json_worker_ami_publication_snapshot "$symlink_worker_publication" "$tmp/symlink-probe.json" >/dev/null 2>&1; then
  echo "strict Worker-AMI publication snapshot accepted unknown credential fields, arbitrary content, or a symlink" >&2
  exit 1
fi
publication_json=$(<"$worker_publication")
duplicate_top_publication="$tmp/worker-ami-publication-duplicate-top.json"
duplicate_nested_publication="$tmp/worker-ami-publication-duplicate-nested.json"
duplicate_escaped_publication="$tmp/worker-ami-publication-duplicate-escaped.json"
printf '{"image_manifest":{"aws_access_key_id":"AKIA0000000000000000"},%s\n' "${publication_json#\{}" > "$duplicate_top_publication"
sed 's/"image_id":"ami-0123456789abcdef0"/"image_id":"AKIA0000000000000000","image_id":"ami-0123456789abcdef0"/' "$worker_publication" > "$duplicate_nested_publication"
sed 's/"image_id":"ami-0123456789abcdef0"/"image\\u005fid":"AKIA0000000000000000","image_id":"ami-0123456789abcdef0"/' "$worker_publication" > "$duplicate_escaped_publication"
grep -F -q '"image\u005fid":"AKIA0000000000000000","image_id":"ami-0123456789abcdef0"' "$duplicate_escaped_publication"
if json_worker_ami_publication_snapshot "$duplicate_top_publication" "$tmp/duplicate-top-probe.json" >/dev/null 2>&1 ||
   json_worker_ami_publication_snapshot "$duplicate_nested_publication" "$tmp/duplicate-nested-probe.json" >/dev/null 2>&1 ||
   json_worker_ami_publication_snapshot "$duplicate_escaped_publication" "$tmp/duplicate-escaped-probe.json" >/dev/null 2>&1; then
  echo "strict Worker-AMI publication snapshot accepted credential-bearing duplicate JSON keys" >&2
  exit 1
fi
[ ! -e "$tmp/duplicate-escaped-probe.json" ]
for credential_field in aws_access_key_id aws_secret_access_key aws_session_token; do
  credential_publication="$tmp/worker-ami-publication-$credential_field.json"
  printf '%s,"%s":"not-a-real-credential"}\n' "${publication_json%?}" "$credential_field" > "$credential_publication"
  if json_worker_ami_publication_snapshot "$credential_publication" "$tmp/$credential_field-probe.json" >/dev/null 2>&1; then
    echo "strict Worker-AMI publication snapshot accepted $credential_field" >&2
    exit 1
  fi
done

# A process interruption after the private same-directory temp is durable but
# before publication must be recoverable without replacing either byte set.
retry_dir="$tmp/publication-retry"
retry_snapshot="$retry_dir/agent-worker-ami-publication.json"
retry_temp="$retry_dir/.agent-worker-ami-publication.json.tmp"
mkdir "$retry_dir"
cp "$worker_publication" "$retry_temp"
chmod 0600 "$retry_temp"
[ "$(json_worker_ami_publication_snapshot "$worker_publication" "$retry_snapshot")" = "$worker_publication_sha256" ]
cmp "$worker_publication" "$retry_snapshot"
[ ! -e "$retry_temp" ]
partial_retry_dir="$tmp/publication-partial-retry"
partial_retry_snapshot="$partial_retry_dir/agent-worker-ami-publication.json"
partial_retry_temp="$partial_retry_dir/.agent-worker-ami-publication.json.tmp"
mkdir "$partial_retry_dir"
printf '%s' '{"schema_version":' > "$partial_retry_temp"
chmod 0600 "$partial_retry_temp"
[ "$(json_worker_ami_publication_snapshot "$worker_publication" "$partial_retry_snapshot")" = "$worker_publication_sha256" ]
cmp "$worker_publication" "$partial_retry_snapshot"
[ ! -e "$partial_retry_temp" ]

# A different valid final snapshot always wins over a stale transaction temp:
# fail closed, preserve its exact bytes, and remove only the owned temp.
conflict_dir="$tmp/publication-conflict"
conflict_snapshot="$conflict_dir/agent-worker-ami-publication.json"
conflict_temp="$conflict_dir/.agent-worker-ami-publication.json.tmp"
different_publication="$tmp/worker-ami-publication-different-valid.json"
mkdir "$conflict_dir"
sed 's/"observed_at":"2026-07-16T08:01:00Z"/"observed_at":"2026-07-16T08:02:00Z"/' "$worker_publication" > "$different_publication"
cp "$different_publication" "$conflict_snapshot"
cp "$worker_publication" "$conflict_temp"
chmod 0600 "$conflict_snapshot" "$conflict_temp"
if json_worker_ami_publication_snapshot "$worker_publication" "$conflict_snapshot" >/dev/null 2>&1; then
  echo "strict Worker-AMI snapshot publication overwrote a different valid final snapshot" >&2
  exit 1
fi
cmp "$different_publication" "$conflict_snapshot"
[ ! -e "$conflict_temp" ]
agent_aws_reaper_image_uri_is_safe 'registry.example/dirextalk-aws-reaper:v0.1.0-alpha.1-abcdef1@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
! agent_worker_control_endpoint_is_safe 'https://worker-control.example.test:443'
! agent_worker_control_endpoint_is_safe 'grpcs://user@worker-control.example.test:443'
agent_worker_control_endpoint_is_safe 'grpcs://worker-control.y1.dirextalk.ai:443'
! agent_worker_control_endpoint_is_safe 'grpcs://worker-control.example.test:443'

# Git Bash/coreutils uses this leading marker when escaping a Windows path.
# Persisting that marker would make the later infrastructure-bound comparison
# fail, even with exactly the same catalog file.
escaped_sha256_digest=$(printf '%064d' 0 | tr 0 a)
sha256sum() {
  printf '\\%s *C:\\model-profiles.json\n' "$escaped_sha256_digest"
}
[ "$(agent_model_profiles_sha256 "$profiles")" = "$escaped_sha256_digest" ]
AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state
[ "$test_profiles_sha256" = "$escaped_sha256_digest" ]
test_infrastructure_id=i-agent-existing
AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state
unset -f sha256sum
test_source= test_enabled= test_image_ref= test_instance_id= test_profiles_sha256= test_infrastructure_id=

AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state
[ "$test_source" = operator_image ]
[ "$test_enabled" = true ]
[ "$test_image_ref" = "$image" ]
[ "$test_instance_id" = "$instance_id" ]
[ "${#test_profiles_sha256}" = 64 ]

# AWS control remains disabled unless deliberately enabled, and its state only
# records public wire values plus a content digest for deterministic resumes.
unset AGENT_ENABLE_AWS_CONTROL AGENT_AWS_REAPER_IMAGE_URI AGENT_WORKER_CONTROL_ENDPOINT AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME AGENT_ENABLE_MANAGED_PREPARATION_AWS AGENT_WORKER_AMI_PUBLICATION_FILE
agent_aws_control_prepare_state
[ "$test_aws_source" = disabled ]
[ "$test_aws_enabled" = false ]
if AGENT_AWS_REAPER_IMAGE_URI='unexpected' agent_aws_control_prepare_state; then
  echo "AWS control inputs without the explicit enable gate must be rejected" >&2
  exit 1
fi
if AGENT_ENABLE_AWS_CONTROL=true agent_aws_control_prepare_state; then
  echo "enabled AWS control without its required public wiring must be rejected" >&2
  exit 1
fi
reaper_image='registry.example/dirextalk-aws-reaper:v0.1.0-alpha.1-abcdef1@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
worker_endpoint='grpcs://worker-control.y1.dirextalk.ai:443'
endpoint_service_name='com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef0'
agent_worker_control_endpoint_service_name_is_safe "$endpoint_service_name"
for unsafe_service_name in \
  'com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef' \
  'com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef01' \
  'com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdeF0' \
  'com.amazonaws.vpce.ap-northeast-1.vpce-svc-0123456789abcdef0'; do
  if agent_worker_control_endpoint_service_name_is_safe "$unsafe_service_name"; then
    echo "accepted unsafe endpoint service name: $unsafe_service_name" >&2
    exit 1
  fi
done
test_aws_source= test_aws_enabled= test_aws_reaper_image_uri= test_worker_control_endpoint= test_managed_preparation_aws=
test_worker_publication_snapshot_file= test_worker_publication_sha256=
AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT="$worker_endpoint" AGENT_ENABLE_MANAGED_PREPARATION_AWS=false agent_aws_control_prepare_state
[ "$test_aws_source" = operator_configuration ]
[ "$test_aws_enabled" = true ]
[ "$test_aws_reaper_image_uri" = "$reaper_image" ]
[ "$test_worker_control_endpoint" = "$worker_endpoint" ]
[ "$test_managed_preparation_aws" = false ]
[ -z "$test_worker_publication_snapshot_file$test_worker_publication_sha256" ]
[ -z "$test_worker_control_endpoint_service_name" ]
agent_aws_control_require_render_inputs
test_infrastructure_id=i-agent-existing
AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT="$worker_endpoint" AGENT_ENABLE_MANAGED_PREPARATION_AWS=false agent_aws_control_prepare_state
if AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT='grpcs://replacement.example.test:443' AGENT_ENABLE_MANAGED_PREPARATION_AWS=false agent_aws_control_prepare_state; then
  echo "existing infrastructure must reject changed AWS control wiring" >&2
  exit 1
fi
if AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT="$worker_endpoint" AGENT_ENABLE_MANAGED_PREPARATION_AWS=true AGENT_WORKER_AMI_PUBLICATION_FILE="$worker_publication" agent_aws_control_prepare_state; then
  echo "normal resume must not bypass the explicit Worker-AMI import transition" >&2
  exit 1
fi

agent_aws_control_record_enabled "$reaper_image" "$worker_endpoint" false "" "" "$endpoint_service_name"
test_producer_status=ready
test_producer_service_name=$endpoint_service_name
AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT="$worker_endpoint" AGENT_ENABLE_MANAGED_PREPARATION_AWS=true AGENT_WORKER_AMI_PUBLICATION_FILE="$worker_publication" agent_aws_control_import_prepare_state
[ "$test_managed_preparation_aws" = false ]
[ "$test_import_status" = prepared ]
[ "$test_import_publication_snapshot_file" = "$DIREXTALK_WORKDIR/agent-worker-ami-publication.json" ]
[ "${#test_import_publication_sha256}" = 64 ]
cmp "$worker_publication" "$test_import_publication_snapshot_file"
agent_aws_control_import_record_applied
[ "$test_managed_preparation_aws" = true ]
[ "$test_worker_publication_snapshot_file" = "$test_import_publication_snapshot_file" ]
[ "$test_worker_publication_sha256" = "$test_import_publication_sha256" ]
[ "$test_import_status" = applied ]
AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT="$worker_endpoint" AGENT_ENABLE_MANAGED_PREPARATION_AWS=true AGENT_WORKER_AMI_PUBLICATION_FILE="$worker_publication" agent_aws_control_prepare_state
changed_worker_publication="$tmp/worker-ami-publication-changed.json"
sed 's/"observed_at":"2026-07-16T08:01:00Z"/"observed_at":"2026-07-16T08:02:00Z"/' "$worker_publication" > "$changed_worker_publication"
if AGENT_ENABLE_AWS_CONTROL=true AGENT_AWS_REAPER_IMAGE_URI="$reaper_image" AGENT_WORKER_CONTROL_ENDPOINT="$worker_endpoint" AGENT_ENABLE_MANAGED_PREPARATION_AWS=true AGENT_WORKER_AMI_PUBLICATION_FILE="$changed_worker_publication" agent_aws_control_import_prepare_state >/dev/null 2>&1; then
  echo "existing infrastructure must reject changed Worker-AMI publication bytes" >&2
  exit 1
fi
cmp "$worker_publication" "$test_worker_publication_snapshot_file"
test_infrastructure_id=
if agent_aws_control_prepare_state; then
  echo "a selected AWS control configuration must not be silently disabled before provisioning" >&2
  exit 1
fi

test_infrastructure_id=i-agent-existing
if AGENT_IMAGE="$changed_image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state; then
  echo "existing infrastructure must reject a replacement Agent image" >&2
  exit 1
fi
if AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$changed_profiles" agent_release_prepare_state; then
  echo "existing infrastructure must reject a changed model-profile catalog" >&2
  exit 1
fi

test_source= test_enabled= test_image_ref= test_instance_id= test_profiles_sha256=
unset AGENT_IMAGE AGENT_INSTANCE_ID AGENT_MODEL_PROFILES_FILE
agent_release_prepare_state
[ "$test_source" = disabled ]
[ "$test_enabled" = false ]

foundation_archive="$tmp/agent-foundation-bundle.tar.gz"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --format bundle \
  --bundle-output "$foundation_archive" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  --agent-enable-aws-control true \
  --agent-aws-reaper-image-uri "$reaper_image" \
  --agent-worker-control-endpoint "$worker_endpoint" \
  --agent-enable-managed-preparation-aws false
mkdir "$tmp/agent-foundation-bundle"
tar -xzf "$foundation_archive" -C "$tmp/agent-foundation-bundle"
grep -q 'AGENT_ENABLE_AWS_CONTROL: "true"' "$tmp/agent-foundation-bundle/docker-compose.yml"
grep -F -q "AGENT_AWS_REAPER_IMAGE_URI: \"$reaper_image\"" "$tmp/agent-foundation-bundle/docker-compose.yml"
grep -F -q "AGENT_WORKER_CONTROL_ENDPOINT: \"$worker_endpoint\"" "$tmp/agent-foundation-bundle/docker-compose.yml"
if grep -q 'AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME' "$tmp/agent-foundation-bundle/docker-compose.yml"; then
  echo "phase-1 Agent AWS-control foundation rendered a service name before producer creation" >&2
  exit 1
fi
grep -q 'AGENT_ENABLE_MANAGED_PREPARATION_AWS: "false"' "$tmp/agent-foundation-bundle/docker-compose.yml"
if tar -tzf "$foundation_archive" | grep -q 'agent-worker-ami-publication.json' \
    || grep -q 'AGENT_WORKER_AMI_PUBLICATION_FILE\|agent-worker-ami-publication.json:/run/dirextalk-agent' "$tmp/agent-foundation-bundle/docker-compose.yml"; then
  echo "phase-1 Agent AWS-control foundation included a Worker-AMI publication or mount" >&2
  exit 1
fi

agent_bundle="$tmp/agent-user-data.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  --agent-enable-aws-control true \
  --agent-aws-reaper-image-uri "$reaper_image" \
  --agent-worker-control-endpoint "$worker_endpoint" \
  --agent-worker-control-endpoint-service-name "$endpoint_service_name" \
  --agent-enable-managed-preparation-aws true \
  --agent-worker-ami-publication-file "$worker_publication" \
  --agent-worker-ami-publication-sha256 "$worker_publication_sha256" \
  > "$agent_bundle"
agent_bundle_second="$tmp/agent-user-data-second.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  --agent-enable-aws-control true \
  --agent-aws-reaper-image-uri "$reaper_image" \
  --agent-worker-control-endpoint "$worker_endpoint" \
  --agent-worker-control-endpoint-service-name "$endpoint_service_name" \
  --agent-enable-managed-preparation-aws true \
  --agent-worker-ami-publication-file "$worker_publication" \
  --agent-worker-ami-publication-sha256 "$worker_publication_sha256" \
  > "$agent_bundle_second"
cmp "$agent_bundle" "$agent_bundle_second"
awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$agent_bundle" | base64 -d > "$tmp/agent-bundle.tar.gz"
mkdir "$tmp/agent-bundle"
tar -xzf "$tmp/agent-bundle.tar.gz" -C "$tmp/agent-bundle"
node --input-type=module - "$tmp/agent-bundle.tar.gz" <<'NODE'
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
const compressed = readFileSync(process.argv[2]);
if (compressed.readUInt32LE(4) !== 0 || compressed[9] !== 255) throw new Error("gzip header is not normalized");
const archive = gunzipSync(compressed);
const entries = [];
for (let offset = 0; offset + 512 <= archive.length; ) {
  const header = archive.subarray(offset, offset + 512);
  if (header.every((byte) => byte === 0)) break;
  const field = (start, length) => header.subarray(start, start + length).toString("utf8").replace(/\0.*$/, "").trim();
  const octal = (start, length) => Number.parseInt(field(start, length) || "0", 8);
  const name = field(0, 100);
  const mode = octal(100, 8);
  const size = octal(124, 12);
  const type = field(156, 1) || "0";
  if (octal(108, 8) !== 0 || octal(116, 8) !== 0 || octal(136, 12) !== 0) throw new Error(`metadata is not normalized: ${name}`);
  if (type === "5" ? mode !== 0o755 : ![0o644, 0o755].includes(mode)) throw new Error(`mode is not normalized: ${name}`);
  entries.push({ name, mode, type });
  offset += 512 + Math.ceil(size / 512) * 512;
}
const names = entries.map((entry) => entry.name);
const sorted = [...names].sort((left, right) => left < right ? -1 : left > right ? 1 : 0);
if (names.join("\n") !== sorted.join("\n")) throw new Error("tar entries are not byte-sorted");
for (const executable of ["agent-db-init.sh", "agent-runtime-init.sh", "init-tokens.sh", "p2p-http-request.sh", "updater/install.sh"]) {
  if (entries.find((entry) => entry.name === executable)?.mode !== 0o755) throw new Error(`executable mode lost: ${executable}`);
}
NODE
printf '%s\n' \
  'DOMAIN=service.example.test' \
  'ACME_EMAIL=ops@example.test' \
  'MESSAGE_SERVER_IMAGE=dirextalk/message-server:test' \
  "AGENT_IMAGE=$image" \
  "AGENT_INSTANCE_ID=$instance_id" \
  'TURN_SECRET=render-test-turn-secret' \
  'P2P_PORTAL_PASSWORD=12345678' \
  'PUBLIC_IP=203.0.113.10' \
  > "$tmp/agent-bundle/.env"
if command -v docker >/dev/null 2>&1; then
  docker compose --env-file "$tmp/agent-bundle/.env" -f "$tmp/agent-bundle/docker-compose.yml" config --quiet
fi

tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-db-init.sh
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-runtime-init.sh
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-model-profiles.json
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-worker-ami-publication.json
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx p2p-http-request.sh
cmp "$worker_publication" "$tmp/agent-bundle/agent-worker-ami-publication.json"
grep -F -q "AGENT_IMAGE=$image" "$agent_bundle"
grep -F -q "AGENT_INSTANCE_ID=$instance_id" "$agent_bundle"

# Lightsail streams this full script over SSH after launch; keep it executable
# as a standalone root bootstrap payload.
lightsail_user_data="$tmp/agent-user-data.sh"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --format shell \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image "$lightsail_message_image" \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  > "$lightsail_user_data"
bash -n "$lightsail_user_data"

grep -q '^  agent-runtime-init:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent-db-init:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent-migrate:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent-bootstrap:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_ENABLED: "true"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_TARGET: dns:///agent:9443' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_CA_FILE: /run/dirextalk-agent/agent-ca.crt' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_SERVER_NAME: agent' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_SERVICE_KEY_FILE: /run/dirextalk-agent/message-server.service-key' "$tmp/agent-bundle/docker-compose.yml"
grep -q "P2P_AGENT_GRPC_INSTANCE_ID: \${AGENT_INSTANCE_ID}" "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_BOOTSTRAP_CLIENT_ID: "dirextalk-project:${DOMAIN}"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_BOOTSTRAP_SCOPES: runtime.read,runtime.write,runtime.chat,knowledge.read,knowledge.write,knowledge.search,cloud.read,cloud.plan.write,cloud.connection.preview,cloud.approve,cloud.connection.write,cloud.destroy,secret.bootstrap,event.read' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_ENABLE_AWS_CONTROL: "true"' "$tmp/agent-bundle/docker-compose.yml"
grep -F -q "AGENT_AWS_REAPER_IMAGE_URI: \"$reaper_image\"" "$tmp/agent-bundle/docker-compose.yml"
grep -F -q "AGENT_WORKER_CONTROL_ENDPOINT: \"$worker_endpoint\"" "$tmp/agent-bundle/docker-compose.yml"
grep -F -q "AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME: \"$endpoint_service_name\"" "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_ENABLE_MANAGED_PREPARATION_AWS: "true"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_WORKER_AMI_PUBLICATION_FILE: /run/dirextalk-agent/worker-ami-publication.json' "$tmp/agent-bundle/docker-compose.yml"
grep -q './agent-worker-ami-publication.json:/run/dirextalk-agent/worker-ami-publication.json:ro' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'user: "65532:65532"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'condition: service_healthy' "$tmp/agent-bundle/docker-compose.yml"
grep -q -- '--server agent' "$ROOT/scripts/cloud-init/agent-runtime-init.sh"
grep -q 'cmp -s "$ca_cert" "$tls_cert"' "$ROOT/scripts/cloud-init/agent-runtime-init.sh"
if grep -Eq -- '--tls-authority-cert|--tls-authority-key' "$ROOT/scripts/cloud-init/agent-runtime-init.sh"; then
  echo "Agent TLS trust must use the exact self-signed leaf, never a pseudo-CA signer" >&2
  exit 1
fi

legacy_agent_bundle="$tmp/legacy-agent-user-data.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  > "$legacy_agent_bundle"
awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$legacy_agent_bundle" | base64 -d > "$tmp/legacy-agent-bundle.tar.gz"
mkdir "$tmp/legacy-agent-bundle"
tar -xzf "$tmp/legacy-agent-bundle.tar.gz" -C "$tmp/legacy-agent-bundle"
grep -q 'AGENT_ENABLE_AWS_CONTROL: "false"' "$tmp/legacy-agent-bundle/docker-compose.yml"
! grep -q '9443:9443' "$tmp/legacy-agent-bundle/docker-compose.yml"
if grep -q 'AGENT_AWS_REAPER_IMAGE_URI\|AGENT_WORKER_CONTROL_ENDPOINT\|worker-ami-publication' "$tmp/legacy-agent-bundle/docker-compose.yml"; then
  echo "legacy Agent render must omit AWS control wiring" >&2
  exit 1
fi
if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image "$image" --agent-instance-id "$instance_id" --agent-model-profiles-file "$profiles" --agent-enable-aws-control true --agent-aws-reaper-image-uri "$reaper_image" --agent-enable-managed-preparation-aws true --agent-worker-ami-publication-file "$worker_publication" --agent-worker-ami-publication-sha256 "$worker_publication_sha256" > /dev/null 2>&1; then
  echo "renderer accepted enabled AWS control without a Worker endpoint" >&2
  exit 1
fi

# The original experimental layout copied a non-CA self-signed certificate as
# a signer and placed its separately signed leaf in the runtime volume. Strict
# TLS clients reject that chain, so a resume must fail closed rather than
# preserving it. This exits before the image-provided generate-keys binary is
# needed, keeping the regression check portable.
legacy_runtime="$tmp/legacy-agent-runtime"
mkdir "$legacy_runtime"
printf '%s\n' 'retired-pseudo-ca' > "$legacy_runtime/agent-ca.crt"
printf '%s\n' 'retired-signed-leaf' > "$legacy_runtime/agent-tls.crt"
printf '%s\n' 'retired-private-key' > "$legacy_runtime/agent-tls.key"
if AGENT_RUNTIME_DIR="$legacy_runtime" AGENT_MODEL_PROFILES_SOURCE="$profiles" sh "$ROOT/scripts/cloud-init/agent-runtime-init.sh" > "$tmp/legacy-agent-runtime.out" 2>&1; then
  echo "retired Agent pseudo-CA runtime layout must be rejected" >&2
  exit 1
fi
grep -q 'retired signer layout' "$tmp/legacy-agent-runtime.out"

if grep -q 'P2P_AGENT_GRPC_SERVICE_KEY:' "$tmp/agent-bundle/docker-compose.yml"; then
  echo "Agent service key must be mounted, never inline" >&2
  exit 1
fi
grep -q '9443:9443' "$tmp/agent-bundle/docker-compose.yml"
grep -q '9443:9443' "$tmp/agent-foundation-bundle/docker-compose.yml"

disabled_bundle="$tmp/disabled-user-data.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  > "$disabled_bundle"
awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$disabled_bundle" | base64 -d > "$tmp/disabled-bundle.tar.gz"
if tar -tzf "$tmp/disabled-bundle.tar.gz" | grep -q 'agent-\|agent-runtime'; then
  echo "disabled render must omit Agent scripts and catalog" >&2
  exit 1
fi
mkdir "$tmp/disabled-bundle"
tar -xzf "$tmp/disabled-bundle.tar.gz" -C "$tmp/disabled-bundle"
if grep -q 'P2P_AGENT_GRPC_' "$tmp/disabled-bundle/docker-compose.yml"; then
  echo "disabled render must omit the remote Agent tuple" >&2
  exit 1
fi
if grep -q 'AGENT_AWS_REAPER_IMAGE_URI\|AGENT_WORKER_CONTROL_ENDPOINT\|worker-ami-publication' "$tmp/disabled-bundle/docker-compose.yml"; then
  echo "disabled render must omit Agent AWS control wiring" >&2
  exit 1
fi

if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image dirextalk-agent:latest --agent-instance-id "$instance_id" --agent-model-profiles-file "$profiles" > /dev/null 2>&1; then
  echo "renderer accepted a mutable Agent tag" >&2
  exit 1
fi
if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image "$image" --agent-instance-id "$instance_id" > /dev/null 2>&1; then
  echo "renderer accepted an Agent without a model-profile catalog" >&2
  exit 1
fi
if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image "$image" --agent-instance-id "$instance_id" --agent-model-profiles-file "$unsafe_profiles" > /dev/null 2>&1; then
  echo "renderer accepted credential-shaped model-profile content" >&2
  exit 1
fi

grep -q 'cloud.deployments.list' "$ROOT/scripts/phases/s5_init_tokens.sh"
grep -q 'p2p-http-request.sh' "$ROOT/scripts/phases/s5_init_tokens.sh"
if grep -Eq -- '--config=|--header.*Authorization' \
  "$ROOT/scripts/cloud-init/init-tokens.sh" \
  "$ROOT/scripts/phases/s5_init_tokens.sh"; then
  echo "Agent acceptance must not pass the bootstrap token in command arguments" >&2
  exit 1
fi
grep -q '/run/dirextalk-ecr-auth' "$ROOT/references/agent-runtime.md"
grep -q 'DIREXTALK_MESSAGE_SERVER_RELEASE_IMAGE' "$ROOT/references/agent-runtime.md"
grep -q "DIREXTALK_CONNECT_AGENT_OPTIONS_TOML='mode = \"default\"'" "$ROOT/references/agent-runtime.md"

# The explicit import command has an atomic local ownership record backed by a
# kernel-released loopback listener whose stdin is held by the actual command.
# Concurrent owners fail, and SIGKILL of that command releases ownership.
lock_service="$tmp/agent-aws-import-lock-service"
lock_file="$lock_service/.agent-aws-import.lock"
mkdir -p "$lock_service"
cat > "$tmp/local-lock-owner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT=$1
export DIREXTALK_WORKDIR=$2
ready=$3
release=$4
export DOMAIN=lock.example.test
export DIREXTALK_ORCHESTRATE_LIB_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/scripts/orchestrate.sh"
unset DIREXTALK_ORCHESTRATE_LIB_ONLY
agent_aws_import_local_lock_acquire
: > "$ready"
while [ ! -e "$release" ]; do sleep 0.1; done
agent_aws_import_local_lock_release
EOF
chmod 0700 "$tmp/local-lock-owner.sh"
"$tmp/local-lock-owner.sh" "$ROOT" "$lock_service" "$tmp/local-lock-ready" "$tmp/local-lock-release" &
local_lock_holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$tmp/local-lock-ready" ] && break
  sleep 0.1
done
[ -e "$tmp/local-lock-ready" ]
if DIREXTALK_WORKDIR="$lock_service" DOMAIN=lock.example.test DIREXTALK_ORCHESTRATE_LIB_ONLY=1 \
    bash -c 'source "$1/scripts/orchestrate.sh"; agent_aws_import_local_lock_acquire || exit $?; agent_aws_import_local_lock_release' \
      bash "$ROOT" > "$tmp/concurrent-local-lock.out" 2>&1; then
  echo "local Agent AWS-control import lock allowed a concurrent owner" >&2
  exit 1
fi
: > "$tmp/local-lock-release"
wait "$local_lock_holder"
[ ! -e "$lock_file" ]

"$tmp/local-lock-owner.sh" "$ROOT" "$lock_service" "$tmp/crashed-lock-ready" "$tmp/crashed-lock-release" &
crashed_lock_owner=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$tmp/crashed-lock-ready" ] && break
  sleep 0.1
done
[ -e "$tmp/crashed-lock-ready" ]
kill -KILL "$crashed_lock_owner"
wait "$crashed_lock_owner" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -e "$lock_file" ] && break
  sleep 0.1
done
[ ! -e "$lock_file" ]
if ! DIREXTALK_WORKDIR="$lock_service" DOMAIN=lock.example.test DIREXTALK_ORCHESTRATE_LIB_ONLY=1 \
    bash -c 'source "$1/scripts/orchestrate.sh"; agent_aws_import_local_lock_acquire || exit $?; agent_aws_import_local_lock_release' \
      bash "$ROOT" > "$tmp/crashed-local-lock-retry.out" 2>&1; then
  cat "$tmp/crashed-local-lock-retry.out" >&2
  exit 1
fi
[ ! -e "$lock_file" ]

wrapper_work="$tmp/agent-aws-import-wrapper-service"
mkdir -p "$wrapper_work"
if DIREXTALK_WORKDIR="$wrapper_work" DOMAIN=wrapper.example.test \
    bash "$ROOT/scripts/orchestrate.sh" agent-aws-import > "$tmp/local-lock-wrapper.out" 2>&1; then
  echo "Agent AWS-control import wrapper accepted missing deployment state" >&2
  exit 1
fi
grep -q 'agent-aws-import requires existing deployment state' "$tmp/local-lock-wrapper.out"
[ ! -e "$wrapper_work/.agent-aws-import.lock" ]

echo "optional Agent runtime contract ok"
