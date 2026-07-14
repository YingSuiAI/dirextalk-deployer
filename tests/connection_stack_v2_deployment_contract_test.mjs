import assert from "node:assert/strict";

import {
  ConnectionStackV2Error,
  validateDeploymentCreatePayload,
  validateDeploymentReceipt,
} from "../scripts/connection-stack-v2/src/deployment-contract.mjs";

const DIGEST = (character) => `sha256:${character.repeat(64)}`;

const binding = {
  plan_hash: DIGEST("a"),
  plan_revision: 7,
  quote_id: "quote-v2-00001",
  manifest_digest: DIGEST("c"),
};

const payload = {
  schema: "dirextalk.aws.deployment-create/v1",
  deployment_id: "deployment-v2-001",
  connection_generation: 3,
  plan_hash: binding.plan_hash,
  plan_revision: binding.plan_revision,
  quote_id: binding.quote_id,
  quote_digest: DIGEST("d"),
  candidate_id: "candidate-recommended-01",
  resource_manifest_digest: binding.manifest_digest,
  worker_artifact: {
    kind: "fixed_ami",
    ami_id: "ami-0123456789abcdef0",
  },
  network: {
    vpc_id: "vpc-0123456789abcdef0",
    subnet_id: "subnet-0123456789abcdef0",
    availability_zone: "ap-south-1a",
  },
};

assert.deepEqual(validateDeploymentCreatePayload(payload, {
  approvalBinding: binding,
  expectedGeneration: 3,
}), payload);

for (const [field, value] of [
  ["plan_hash", DIGEST("f")],
  ["plan_revision", 8],
  ["quote_id", "quote-v2-other"],
  ["resource_manifest_digest", DIGEST("f")],
  ["connection_generation", 4],
]) {
  assert.throws(
    () => validateDeploymentCreatePayload({ ...payload, [field]: value }, {
      approvalBinding: binding,
      expectedGeneration: 3,
    }),
    (error) => error instanceof ConnectionStackV2Error && error.code === "approval_binding_mismatch",
    `${field} must bind the approved immutable scope`,
  );
}

for (const forbidden of [
  "instance_type",
  "user_data",
  "key_name",
  "iam_instance_profile",
  "security_group_id",
  "public_ip",
  "worker_token",
]) {
  assert.throws(
    () => validateDeploymentCreatePayload({ ...payload, [forbidden]: "attacker-controlled" }, {
      approvalBinding: binding,
      expectedGeneration: 3,
    }),
    (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_payload",
    `${forbidden} must never be caller-controlled deployment input`,
  );
}

const receipt = {
  schema: "dirextalk.aws.deployment-receipt/v1",
  connection_id: "connection-v2-0001",
  deployment_id: payload.deployment_id,
  request_sha256: "b".repeat(64),
  resource_status: "provisioning",
  instance_id: "i-0123456789abcdef0",
  volume_ids: ["vol-0123456789abcdef0"],
  network_interface_ids: ["eni-0123456789abcdef0"],
};
assert.deepEqual(validateDeploymentReceipt(receipt, {
  connectionId: "connection-v2-0001",
  deploymentId: payload.deployment_id,
  requestSHA256: "b".repeat(64),
}), receipt);

for (const forbidden of ["worker_token", "user_data", "bootstrap_session_id", "secret_ref"]) {
  assert.throws(
    () => validateDeploymentReceipt({ ...receipt, [forbidden]: "must-not-leak" }),
    (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_deployment_receipt",
    `${forbidden} must never appear in a deployment receipt`,
  );
}

console.log("connection stack v2 deployment contract boundary ok");
