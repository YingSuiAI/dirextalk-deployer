#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-connection-stack-v2-deploy-test.XXXXXX")
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

bin="$tmp/bin"
mkdir -p "$bin"
request="$tmp/request.json"
identity="$tmp/identity.json"
stack="$tmp/stack.json"
bucket_public_access="$tmp/bucket-public-access.json"
bucket_encryption="$tmp/bucket-encryption.json"
bucket_location="$tmp/bucket-location.json"
manifest="$tmp/registration-manifest.json"
aws_log="$tmp/aws.log"
sam_log="$tmp/sam.log"
node_bin=$(json_node)

request_node=$(json_native_file_path "$request")
identity_node=$(json_native_file_path "$identity")
stack_node=$(json_native_file_path "$stack")
bucket_public_access_node=$(json_native_file_path "$bucket_public_access")
bucket_encryption_node=$(json_native_file_path "$bucket_encryption")
bucket_location_node=$(json_native_file_path "$bucket_location")
template_node=$(json_native_file_path "$ROOT/scripts/connection-stack-v2/template.json")
stack_dir_node=$(json_native_file_path "$ROOT/scripts/connection-stack-v2")
helper_node=$(json_native_file_path "$ROOT/scripts/connection-stack-v2/src/deploy-helper.mjs")

REQUEST_NODE="$request_node" IDENTITY_NODE="$identity_node" STACK_NODE="$stack_node" BUCKET_PUBLIC_ACCESS_NODE="$bucket_public_access_node" BUCKET_ENCRYPTION_NODE="$bucket_encryption_node" BUCKET_LOCATION_NODE="$bucket_location_node" TEMPLATE_NODE="$template_node" STACK_DIR_NODE="$stack_dir_node" HELPER_NODE="$helper_node" "$node_bin" --input-type=module <<'NODE'
import { createHash, generateKeyPairSync } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { connectionStackSourceTreeDigest } = await import(pathToFileURL(process.env.HELPER_NODE).href);

const { publicKey } = generateKeyPairSync("ed25519");
const spki = publicKey.export({ type: "spki", format: "der" }).toString("base64");
const stackArn = "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef";
const request = {
  schema: "dirextalk.aws.connection-stack-deploy-request/v1",
  bootstrap_id: "bootstrap-v2-0001",
  stack_name: "DirextalkConnectionStackV2-001",
  connection_id: "connection-v2-0001",
  connection_generation: 3,
  requested_region: "ap-south-1",
  node_key_id: "node-key-v2",
  node_public_key_spki_b64: spki,
  device_approval_key_id: "device-key-v2",
  device_approval_public_key_spki_b64: spki,
  stage_name: "prod",
  worker_base_ami_id: "ami-0123456789abcdef0",
  worker_vpc_id: "vpc-0123456789abcdef0",
  worker_subnet_id: "subnet-0123456789abcdef0",
  worker_availability_zone: "ap-south-1a",
  worker_resource_manifest_digest: `sha256:${"c".repeat(64)}`,
  template_sha256: `sha256:${createHash("sha256").update(readFileSync(process.env.TEMPLATE_NODE)).digest("hex")}`,
  source_tree_sha256: connectionStackSourceTreeDigest(process.env.STACK_DIR_NODE),
};
writeFileSync(process.env.REQUEST_NODE, `${JSON.stringify(request)}\n`);
writeFileSync(process.env.IDENTITY_NODE, `${JSON.stringify({
  Account: "123456789012",
  Arn: "arn:aws:sts::123456789012:assumed-role/DirextalkConnectionStackBootstrap/session-001",
  UserId: "AROAXXXXXXXXXXXXX:session-001",
})}\n`);
writeFileSync(process.env.STACK_NODE, `${JSON.stringify({
  Stacks: [{
    StackId: stackArn,
    Outputs: [
      { OutputKey: "ConnectionId", OutputValue: request.connection_id },
      { OutputKey: "ConnectionGeneration", OutputValue: "3" },
      { OutputKey: "AccountId", OutputValue: "123456789012" },
      { OutputKey: "Region", OutputValue: request.requested_region },
      { OutputKey: "NodeKeyId", OutputValue: request.node_key_id },
      { OutputKey: "WorkerBaseAmiId", OutputValue: request.worker_base_ami_id },
      { OutputKey: "WorkerVpcId", OutputValue: request.worker_vpc_id },
      { OutputKey: "WorkerSubnetId", OutputValue: request.worker_subnet_id },
      { OutputKey: "WorkerAvailabilityZone", OutputValue: request.worker_availability_zone },
      { OutputKey: "WorkerResourceManifestDigest", OutputValue: request.worker_resource_manifest_digest },
      { OutputKey: "BrokerCommandUrl", OutputValue: "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands" },
      { OutputKey: "StackArn", OutputValue: stackArn },
    ],
  }],
})}\n`);
writeFileSync(process.env.BUCKET_PUBLIC_ACCESS_NODE, `${JSON.stringify({
  PublicAccessBlockConfiguration: {
    BlockPublicAcls: true,
    IgnorePublicAcls: true,
    BlockPublicPolicy: true,
    RestrictPublicBuckets: true,
  },
})}\n`);
writeFileSync(process.env.BUCKET_ENCRYPTION_NODE, `${JSON.stringify({
  ServerSideEncryptionConfiguration: {
    Rules: [{ ApplyServerSideEncryptionByDefault: { SSEAlgorithm: "AES256" } }],
  },
})}\n`);
writeFileSync(process.env.BUCKET_LOCATION_NODE, `${JSON.stringify({ LocationConstraint: "ap-south-1" })}\n`);
NODE

cat > "$bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_AWS_LOG"
printf '\n' >> "$FAKE_AWS_LOG"
case "${1:-}:${2:-}" in
  sts:get-caller-identity) cat "$FAKE_IDENTITY" ;;
  cloudformation:describe-stacks) cat "$FAKE_STACK" ;;
  s3api:get-public-access-block) cat "$FAKE_BUCKET_PUBLIC_ACCESS" ;;
  s3api:get-bucket-encryption) cat "$FAKE_BUCKET_ENCRYPTION" ;;
  s3api:get-bucket-location) cat "$FAKE_BUCKET_LOCATION" ;;
  *) exit 64 ;;
esac
EOF
cat > "$bin/sam" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_SAM_LOG"
printf '\n' >> "$FAKE_SAM_LOG"
case "${1:-}" in
  build)
    template=""
    build_dir=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --template-file) shift; template=$1 ;;
        --build-dir) shift; build_dir=$1 ;;
      esac
      shift
    done
    [ -n "$template" ] && [ -n "$build_dir" ]
    mkdir -p "$build_dir"
    cp "$template" "$build_dir/template.yaml"
    ;;
  deploy) ;;
  *) exit 64 ;;
esac
EOF
chmod 700 "$bin/aws" "$bin/sam"

PATH="$bin:$PATH" \
FAKE_AWS_LOG="$aws_log" \
FAKE_SAM_LOG="$sam_log" \
FAKE_IDENTITY="$identity" \
FAKE_STACK="$stack" \
FAKE_BUCKET_PUBLIC_ACCESS="$bucket_public_access" \
FAKE_BUCKET_ENCRYPTION="$bucket_encryption" \
FAKE_BUCKET_LOCATION="$bucket_location" \
bash "$ROOT/scripts/connection-stack-v2/deploy.sh" \
  --apply \
  --request "$request" \
  --artifact-bucket dirextalk-connection-artifacts \
  --output "$manifest"

MANIFEST_NODE=$(json_native_file_path "$manifest") "$node_bin" --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const manifest = JSON.parse(readFileSync(process.env.MANIFEST_NODE, "utf8"));
assert.deepEqual(Object.keys(manifest), [
  "schema",
  "bootstrap_id",
  "connection_id",
  "account_id",
  "region",
  "broker_command_url",
  "node_key_id",
  "connection_generation",
  "worker_artifact",
  "worker_network",
  "worker_resource_manifest_digest",
  "stack_arn",
]);
assert.equal(manifest.schema, "dirextalk.aws.connection-registration-manifest/v1");
assert.equal(manifest.broker_command_url, "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands");
assert.doesNotMatch(JSON.stringify(manifest), /secret|token|public_key|approval_key|template_sha256/i);
NODE

grep -F -- "sts get-caller-identity" "$aws_log" >/dev/null
grep -F -- "s3api get-public-access-block" "$aws_log" >/dev/null
grep -F -- "s3api get-bucket-encryption" "$aws_log" >/dev/null
grep -F -- "s3api get-bucket-location" "$aws_log" >/dev/null
grep -F -- "cloudformation describe-stacks" "$aws_log" >/dev/null
grep -F -- "--s3-bucket dirextalk-connection-artifacts" "$sam_log" >/dev/null
grep -F -- "--no-confirm-changeset" "$sam_log" >/dev/null
grep -F -- "--capabilities CAPABILITY_IAM" "$sam_log" >/dev/null
if grep -F -- "--resolve-s3" "$sam_log" >/dev/null; then
  echo "deploy helper must not create a hidden SAM managed bucket" >&2
  exit 1
fi

sam_calls_before_root=$(wc -l < "$sam_log")
cat > "$identity" <<'EOF'
{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:root","UserId":"123456789012"}
EOF
if PATH="$bin:$PATH" \
  FAKE_AWS_LOG="$aws_log" \
  FAKE_SAM_LOG="$sam_log" \
  FAKE_IDENTITY="$identity" \
  FAKE_STACK="$stack" \
  FAKE_BUCKET_PUBLIC_ACCESS="$bucket_public_access" \
  FAKE_BUCKET_ENCRYPTION="$bucket_encryption" \
  FAKE_BUCKET_LOCATION="$bucket_location" \
  bash "$ROOT/scripts/connection-stack-v2/deploy.sh" \
    --apply \
    --request "$request" \
    --artifact-bucket dirextalk-connection-artifacts \
    --output "$tmp/root-must-not-write.json" >/dev/null 2>&1; then
  echo "deploy helper must reject a root STS identity" >&2
  exit 1
fi
test "$(wc -l < "$sam_log")" = "$sam_calls_before_root"

echo "connection stack v2 deploy script boundary ok"
