#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STACK_DIR="$ROOT/scripts/connection-stack-v2"
TEMPLATE="$STACK_DIR/template.json"
HELPER="$STACK_DIR/src/deploy-helper.mjs"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/git-bash.sh"

filesystem_path() {
  local value=${1:-}
  case "$(uname -s 2>/dev/null || printf unknown)" in
    *MINGW*|*MSYS*|*CYGWIN*) cygpath -u "$value" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/connection-stack-v2/deploy.sh --apply \
    --request <connection-stack-deploy-request.json> \
    --artifact-bucket <existing-private-sam-artifact-bucket> \
    --output <connection-registration-manifest.json>

The request must be a pinned, nonsecret V2 deployment request from ProductCore.
This command rejects AWS root and IAM-user credentials; it requires an active
STS assumed-role identity. It never accepts AWS credentials in arguments or
request JSON, and the output contains only the registration manifest needed for
the subsequent signed Broker verification.
EOF
}

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

apply=0
request_file=""
artifact_bucket=""
output_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      apply=1
      ;;
    --request)
      shift
      [ "$#" -gt 0 ] || fail "--request requires a file"
      request_file=$1
      ;;
    --artifact-bucket)
      shift
      [ "$#" -gt 0 ] || fail "--artifact-bucket requires a bucket name"
      artifact_bucket=$1
      ;;
    --output)
      shift
      [ "$#" -gt 0 ] || fail "--output requires a file"
      output_file=$1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

[ "$apply" -eq 1 ] || fail "refusing to create or update a Connection Stack without --apply"
[ -n "$request_file" ] || fail "--request is required"
[ -n "$artifact_bucket" ] || fail "--artifact-bucket is required"
[ -n "$output_file" ] || fail "--output is required"
dirextalk_require_git_bash_on_windows || exit 1
request_file=$(filesystem_path "$request_file")
output_file=$(filesystem_path "$output_file")
[ -f "$request_file" ] || fail "request file does not exist"
[ -f "$TEMPLATE" ] || fail "Connection Stack template is unavailable"
[ -f "$HELPER" ] || fail "Connection Stack deployment helper is unavailable"
[[ "$artifact_bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "artifact bucket name is invalid"

command -v aws >/dev/null 2>&1 || fail "aws CLI is required"
command -v sam >/dev/null 2>&1 || fail "AWS SAM CLI is required"

umask 077
node_bin=$(json_node) || exit 1
request_node_path=$(json_native_file_path "$request_file")
template_node_path=$(json_native_file_path "$TEMPLATE")
helper_node_path=$(json_native_file_path "$HELPER")

# This validates the exact request fields, both Ed25519 public keys, and the
# caller-supplied immutable template digest before any AWS control-plane call.
"$node_bin" "$helper_node_path" validate-request "$request_node_path" "$template_node_path"

stack_name=$(json_get "$request_file" stack_name)
connection_id=$(json_get "$request_file" connection_id)
connection_generation=$(json_get "$request_file" connection_generation)
requested_region=$(json_get "$request_file" requested_region)
node_key_id=$(json_get "$request_file" node_key_id)
node_public_key_spki_b64=$(json_get "$request_file" node_public_key_spki_b64)
device_approval_key_id=$(json_get "$request_file" device_approval_key_id)
device_approval_public_key_spki_b64=$(json_get "$request_file" device_approval_public_key_spki_b64)
stage_name=$(json_get "$request_file" stage_name)
worker_base_ami_id=$(json_get "$request_file" worker_base_ami_id)
worker_vpc_id=$(json_get "$request_file" worker_vpc_id)
worker_subnet_id=$(json_get "$request_file" worker_subnet_id)
worker_availability_zone=$(json_get "$request_file" worker_availability_zone)
worker_resource_manifest_digest=$(json_get "$request_file" worker_resource_manifest_digest)

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-connection-stack-v2.XXXXXX")
identity_file="$tmp_dir/identity.json"
stack_file="$tmp_dir/stack.json"
artifact_bucket_public_access_file="$tmp_dir/artifact-bucket-public-access.json"
artifact_bucket_encryption_file="$tmp_dir/artifact-bucket-encryption.json"
artifact_bucket_location_file="$tmp_dir/artifact-bucket-location.json"
build_dir="$tmp_dir/build"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

# Do not query a profile name or inspect local credential files. STS is the
# source of truth, and the helper rejects both root and IAM-user identities.
aws sts get-caller-identity --output json > "$identity_file"
identity_node_path=$(json_native_file_path "$identity_file")
"$node_bin" "$helper_node_path" validate-identity "$identity_node_path"

# The packaging bucket is not part of the Connection Stack. Verify it is a
# same-Region encrypted bucket with every public-access block enabled before
# SAM uploads an artifact to it.
aws s3api get-public-access-block \
  --bucket "$artifact_bucket" \
  --region "$requested_region" \
  --output json > "$artifact_bucket_public_access_file"
aws s3api get-bucket-encryption \
  --bucket "$artifact_bucket" \
  --region "$requested_region" \
  --output json > "$artifact_bucket_encryption_file"
aws s3api get-bucket-location \
  --bucket "$artifact_bucket" \
  --region "$requested_region" \
  --output json > "$artifact_bucket_location_file"
artifact_bucket_public_access_node_path=$(json_native_file_path "$artifact_bucket_public_access_file")
artifact_bucket_encryption_node_path=$(json_native_file_path "$artifact_bucket_encryption_file")
artifact_bucket_location_node_path=$(json_native_file_path "$artifact_bucket_location_file")
"$node_bin" "$helper_node_path" validate-artifact-bucket \
  "$artifact_bucket_public_access_node_path" \
  "$artifact_bucket_encryption_node_path" \
  "$artifact_bucket_location_node_path" \
  "$requested_region"

sam build \
  --template-file "$TEMPLATE" \
  --build-dir "$build_dir"

# An explicitly supplied, validated bucket keeps SAM from creating a hidden
# managed packaging bucket. The stack itself still contains no executor or
# cloud-resource mutation capability beyond its own durable control plane.
sam deploy \
  --template-file "$build_dir/template.yaml" \
  --stack-name "$stack_name" \
  --region "$requested_region" \
  --capabilities CAPABILITY_IAM \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --s3-bucket "$artifact_bucket" \
  --s3-prefix "dirextalk/connection-stack-v2/${connection_id}" \
  --parameter-overrides \
  "ParameterKey=ConnectionId,ParameterValue=${connection_id}" \
  "ParameterKey=ConnectionGeneration,ParameterValue=${connection_generation}" \
  "ParameterKey=NodeKeyId,ParameterValue=${node_key_id}" \
  "ParameterKey=NodePublicKeySpkiBase64,ParameterValue=${node_public_key_spki_b64}" \
  "ParameterKey=DeviceApprovalKeyId,ParameterValue=${device_approval_key_id}" \
  "ParameterKey=DeviceApprovalPublicKeySpkiBase64,ParameterValue=${device_approval_public_key_spki_b64}" \
  "ParameterKey=StageName,ParameterValue=${stage_name}" \
  "ParameterKey=WorkerBaseAmiId,ParameterValue=${worker_base_ami_id}" \
  "ParameterKey=WorkerVpcId,ParameterValue=${worker_vpc_id}" \
  "ParameterKey=WorkerSubnetId,ParameterValue=${worker_subnet_id}" \
  "ParameterKey=WorkerAvailabilityZone,ParameterValue=${worker_availability_zone}" \
  "ParameterKey=WorkerResourceManifestDigest,ParameterValue=${worker_resource_manifest_digest}"

aws cloudformation describe-stacks \
  --stack-name "$stack_name" \
  --region "$requested_region" \
  --output json > "$stack_file"

output_dir=$(dirname "$output_file")
output_base=$(basename "$output_file")
mkdir -p "$output_dir"
manifest_tmp=$(mktemp "$output_dir/.${output_base}.tmp.XXXXXX")
stack_node_path=$(json_native_file_path "$stack_file")

# build-manifest emits only the de-secretsed registration schema. It verifies
# every Stack output against the request and live STS account before atomically
# replacing the requested output path.
"$node_bin" "$helper_node_path" build-manifest \
  "$request_node_path" "$identity_node_path" "$stack_node_path" > "$manifest_tmp"
chmod 600 "$manifest_tmp"
mv -f "$manifest_tmp" "$output_file"
