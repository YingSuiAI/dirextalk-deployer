import assert from "node:assert/strict";
import {
  generateKeyPairSync,
} from "node:crypto";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import {
  tmpdir,
} from "node:os";
import {
  join,
} from "node:path";

import {
  buildConnectionStackRegistrationManifest,
  connectionStackSourceTreeDigest,
  connectionStackTemplateDigest,
  validateConnectionStackArtifactBucket,
  validateConnectionStackBootstrapIdentityFile,
  validateConnectionStackDeploymentRequestFile,
} from "../scripts/connection-stack-v2/src/deploy-helper.mjs";

const root = new URL("../", import.meta.url);
const templatePath = new URL("scripts/connection-stack-v2/template.json", root);
const stackArn = "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef";
const brokerURL = "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands";
const temporary = mkdtempSync(join(tmpdir(), "dirextalk-connection-stack-v2-test-"));

function write(name, value) {
  const path = join(temporary, name);
  writeFileSync(path, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  return path;
}

try {
  const { publicKey } = generateKeyPairSync("ed25519");
  const publicKeySpkiBase64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");
  const request = {
    schema: "dirextalk.aws.connection-stack-deploy-request/v1",
    bootstrap_id: "bootstrap-v2-0001",
    stack_name: "DirextalkConnectionStackV2-001",
    connection_id: "connection-v2-0001",
    connection_generation: 3,
    requested_region: "ap-south-1",
    node_key_id: "node-key-v2",
    node_public_key_spki_b64: publicKeySpkiBase64,
    device_approval_key_id: "device-key-v2",
    device_approval_public_key_spki_b64: publicKeySpkiBase64,
    stage_name: "prod",
    worker_base_ami_id: "ami-0123456789abcdef0",
    worker_vpc_id: "vpc-0123456789abcdef0",
    worker_subnet_id: "subnet-0123456789abcdef0",
    worker_availability_zone: "ap-south-1a",
    worker_resource_manifest_digest: `sha256:${"c".repeat(64)}`,
    template_sha256: connectionStackTemplateDigest(templatePath),
    source_tree_sha256: connectionStackSourceTreeDigest(new URL("scripts/connection-stack-v2/", root)),
  };
  const identity = {
    Account: "123456789012",
    Arn: "arn:aws:sts::123456789012:assumed-role/DirextalkConnectionStackBootstrap/session-001",
    UserId: "AROAXXXXXXXXXXXXX:session-001",
  };
  const description = {
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
        { OutputKey: "BrokerCommandUrl", OutputValue: brokerURL },
        { OutputKey: "StackArn", OutputValue: stackArn },
      ],
    }],
  };
  const requestPath = write("request.json", request);
  const identityPath = write("identity.json", identity);
  const descriptionPath = write("stack.json", description);

  assert.deepEqual(
    validateConnectionStackDeploymentRequestFile(requestPath, templatePath),
    request,
    "the helper must require an exact digest-pinned deployment request",
  );
  assert.deepEqual(validateConnectionStackBootstrapIdentityFile(identityPath), {
    account_id: "123456789012",
    principal_type: "assumed_role",
  });
  const manifest = buildConnectionStackRegistrationManifest(requestPath, identityPath, descriptionPath);
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
  assert.deepEqual(manifest, {
    schema: "dirextalk.aws.connection-registration-manifest/v1",
    bootstrap_id: request.bootstrap_id,
    connection_id: request.connection_id,
    account_id: "123456789012",
    region: request.requested_region,
    broker_command_url: brokerURL,
    node_key_id: request.node_key_id,
    connection_generation: 3,
    worker_artifact: { kind: "fixed_ami", ami_id: request.worker_base_ami_id },
    worker_network: {
      vpc_id: request.worker_vpc_id,
      subnet_id: request.worker_subnet_id,
      availability_zone: request.worker_availability_zone,
    },
    worker_resource_manifest_digest: request.worker_resource_manifest_digest,
    stack_arn: stackArn,
  });
  assert.doesNotMatch(JSON.stringify(manifest), /public_key|approval_key|template_sha256|secret|token/i);

  assert.doesNotThrow(() => validateConnectionStackArtifactBucket(
    {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        IgnorePublicAcls: true,
        BlockPublicPolicy: true,
        RestrictPublicBuckets: true,
      },
    },
    {
      ServerSideEncryptionConfiguration: {
        Rules: [{ ApplyServerSideEncryptionByDefault: { SSEAlgorithm: "AES256" } }],
      },
    },
    { LocationConstraint: "ap-south-1" },
    "ap-south-1",
  ));
  assert.throws(
    () => validateConnectionStackArtifactBucket(
      { PublicAccessBlockConfiguration: {} },
      { ServerSideEncryptionConfiguration: { Rules: [] } },
      { LocationConstraint: "us-east-1" },
      "ap-south-1",
    ),
    /public-access block/,
    "the helper must fail closed rather than package a Lambda through a public artifact bucket",
  );

  const rootIdentityPath = write("root.json", {
    Account: "123456789012",
    Arn: "arn:aws:iam::123456789012:root",
    UserId: "123456789012",
  });
  assert.throws(
    () => validateConnectionStackBootstrapIdentityFile(rootIdentityPath),
    (error) => error?.code === "root_bootstrap_forbidden",
    "the deployment helper must refuse a root credential even when it can describe the account",
  );

  const mismatchedDescriptionPath = write("mismatched-stack.json", {
    Stacks: [{
      ...description.Stacks[0],
      Outputs: description.Stacks[0].Outputs.map((output) => output.OutputKey === "BrokerCommandUrl"
        ? { ...output, OutputValue: "https://abcde12345.execute-api.us-east-1.amazonaws.com/prod/v2/commands" }
        : output),
    }],
  });
  assert.throws(
    () => buildConnectionStackRegistrationManifest(requestPath, identityPath, mismatchedDescriptionPath),
    (error) => error?.code === "invalid_connection_stack_output",
    "a manifest must not accept a Broker endpoint outside the requested Stack region",
  );

  const wrongDigestPath = write("wrong-digest.json", { ...request, template_sha256: `sha256:${"0".repeat(64)}` });
  assert.throws(
    () => validateConnectionStackDeploymentRequestFile(wrongDigestPath, templatePath),
    (error) => error?.code === "connection_stack_template_digest_mismatch",
    "the helper must not deploy an unpinned or altered template",
  );

  const wrongSourceDigestPath = write("wrong-source-digest.json", { ...request, source_tree_sha256: `sha256:${"0".repeat(64)}` });
  assert.throws(
    () => validateConnectionStackDeploymentRequestFile(wrongSourceDigestPath, templatePath),
    (error) => error?.code === "connection_stack_source_digest_mismatch",
    "the helper must not build a locally altered Lambda source tree under a matching template",
  );
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

console.log("connection stack v2 deploy helper contract ok");
