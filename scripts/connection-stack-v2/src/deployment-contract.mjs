import {
  ConnectionStackV2Error,
} from "./errors.mjs";

export {
  ConnectionStackV2Error,
} from "./errors.mjs";

export const DEPLOYMENT_CREATE_V1_SCHEMA = "dirextalk.aws.deployment-create/v1";
export const DEPLOYMENT_RECEIPT_V1_SCHEMA = "dirextalk.aws.deployment-receipt/v1";

const CREATE_FIELDS = [
  "schema",
  "deployment_id",
  "connection_generation",
  "plan_hash",
  "plan_revision",
  "quote_id",
  "quote_digest",
  "candidate_id",
  "resource_manifest_digest",
  "worker_artifact",
  "network",
];
const WORKER_ARTIFACT_FIELDS = ["kind", "ami_id"];
const NETWORK_FIELDS = ["vpc_id", "subnet_id", "availability_zone"];
const RECEIPT_FIELDS = [
  "schema",
  "connection_id",
  "deployment_id",
  "request_sha256",
  "resource_status",
  "instance_id",
  "volume_ids",
  "network_interface_ids",
];
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const AMI_ID_PATTERN = /^ami-[0-9a-f]{8,17}$/;
const VPC_ID_PATTERN = /^vpc-[0-9a-f]{8,17}$/;
const SUBNET_ID_PATTERN = /^subnet-[0-9a-f]{8,17}$/;
const AVAILABILITY_ZONE_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;
const VOLUME_ID_PATTERN = /^vol-[0-9a-f]{8,17}$/;
const NETWORK_INTERFACE_ID_PATTERN = /^eni-[0-9a-f]{8,17}$/;
const RESOURCE_STATUSES = new Set(["provisioning", "active", "degraded", "destroying", "destroy_blocked", "verified_destroyed"]);

function fail(code, message, statusCode = 400) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(record, fields, code, label) {
  if (!isRecord(record)) fail(code, `${label} must be an object`);
  for (const key of Object.keys(record)) {
    if (!fields.includes(key)) fail(code, `${label}.${key} is not allowed`);
  }
  for (const key of fields) {
    if (!Object.hasOwn(record, key)) fail(code, `${label}.${key} is required`);
  }
}

function requireString(record, field, pattern, code) {
  const value = record[field];
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`);
  }
  return value;
}

function requirePositiveInteger(record, field, code) {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < 1) fail(code, `${field} is invalid`);
  return value;
}

function canonicalIDs(value, field, pattern, code) {
  if (!Array.isArray(value) || value.length === 0) fail(code, `${field} is invalid`);
  let previous = "";
  for (const id of value) {
    if (typeof id !== "string" || !pattern.test(id) || (previous && previous >= id)) {
      fail(code, `${field} must be sorted and unique`);
    }
    previous = id;
  }
  return [...value];
}

function approvalBindingField(approvalBinding, field) {
  if (!isRecord(approvalBinding)) fail("invalid_approval_binding", "approval binding is required", 500);
  return approvalBinding[field];
}

// validateDeploymentCreatePayload intentionally has no instance type, disk,
// security-group, key pair, instance profile, user-data, bootstrap URL, or
// secret field. The Broker derives those from a durable quote and its own
// immutable Connection Stack configuration after this signed boundary.
export function validateDeploymentCreatePayload(payload, {
  approvalBinding,
  expectedGeneration,
} = {}) {
  exactKeys(payload, CREATE_FIELDS, "invalid_payload", "deployment create payload");
  if (payload.schema !== DEPLOYMENT_CREATE_V1_SCHEMA) {
    fail("invalid_payload", "deployment create payload schema is invalid");
  }
  const deploymentId = requireString(payload, "deployment_id", ID_PATTERN, "invalid_payload");
  const generation = requirePositiveInteger(payload, "connection_generation", "invalid_payload");
  const planHash = requireString(payload, "plan_hash", NAMED_SHA256_PATTERN, "invalid_payload");
  const planRevision = requirePositiveInteger(payload, "plan_revision", "invalid_payload");
  const quoteId = requireString(payload, "quote_id", ID_PATTERN, "invalid_payload");
  const quoteDigest = requireString(payload, "quote_digest", NAMED_SHA256_PATTERN, "invalid_payload");
  const candidateId = requireString(payload, "candidate_id", ID_PATTERN, "invalid_payload");
  const resourceManifestDigest = requireString(payload, "resource_manifest_digest", NAMED_SHA256_PATTERN, "invalid_payload");

  exactKeys(payload.worker_artifact, WORKER_ARTIFACT_FIELDS, "invalid_payload", "worker_artifact");
  if (payload.worker_artifact.kind !== "fixed_ami") {
    fail("invalid_payload", "worker_artifact.kind is invalid");
  }
  const workerArtifact = {
    kind: "fixed_ami",
    ami_id: requireString(payload.worker_artifact, "ami_id", AMI_ID_PATTERN, "invalid_payload"),
  };

  exactKeys(payload.network, NETWORK_FIELDS, "invalid_payload", "network");
  const network = {
    vpc_id: requireString(payload.network, "vpc_id", VPC_ID_PATTERN, "invalid_payload"),
    subnet_id: requireString(payload.network, "subnet_id", SUBNET_ID_PATTERN, "invalid_payload"),
    availability_zone: requireString(payload.network, "availability_zone", AVAILABILITY_ZONE_PATTERN, "invalid_payload"),
  };

  if (expectedGeneration !== undefined && generation !== expectedGeneration) {
    fail("approval_binding_mismatch", "connection_generation does not match this stack", 409);
  }
  if (approvalBinding !== undefined && (planHash !== approvalBindingField(approvalBinding, "plan_hash")
    || planRevision !== approvalBindingField(approvalBinding, "plan_revision")
    || quoteId !== approvalBindingField(approvalBinding, "quote_id")
    || resourceManifestDigest !== approvalBindingField(approvalBinding, "manifest_digest"))) {
    fail("approval_binding_mismatch", "deployment create payload does not match the approved scope", 409);
  }
  return {
    schema: DEPLOYMENT_CREATE_V1_SCHEMA,
    deployment_id: deploymentId,
    connection_generation: generation,
    plan_hash: planHash,
    plan_revision: planRevision,
    quote_id: quoteId,
    quote_digest: quoteDigest,
    candidate_id: candidateId,
    resource_manifest_digest: resourceManifestDigest,
    worker_artifact: workerArtifact,
    network,
  };
}

// Deployment receipts are private Broker-to-Orchestrator evidence. They may
// identify AWS resources for lifecycle accounting, but never contain worker
// credentials, user data, pairing material, or service secrets.
export function validateDeploymentReceipt(receipt, {
  connectionId,
  deploymentId,
  requestSHA256,
} = {}) {
  exactKeys(receipt, RECEIPT_FIELDS, "invalid_deployment_receipt", "deployment receipt");
  if (receipt.schema !== DEPLOYMENT_RECEIPT_V1_SCHEMA) {
    fail("invalid_deployment_receipt", "deployment receipt schema is invalid");
  }
  const normalized = {
    schema: DEPLOYMENT_RECEIPT_V1_SCHEMA,
    connection_id: requireString(receipt, "connection_id", ID_PATTERN, "invalid_deployment_receipt"),
    deployment_id: requireString(receipt, "deployment_id", ID_PATTERN, "invalid_deployment_receipt"),
    request_sha256: requireString(receipt, "request_sha256", SHA256_PATTERN, "invalid_deployment_receipt"),
    resource_status: requireString(receipt, "resource_status", /^[a-z_]+$/, "invalid_deployment_receipt"),
    instance_id: requireString(receipt, "instance_id", INSTANCE_ID_PATTERN, "invalid_deployment_receipt"),
    volume_ids: canonicalIDs(receipt.volume_ids, "volume_ids", VOLUME_ID_PATTERN, "invalid_deployment_receipt"),
    network_interface_ids: canonicalIDs(receipt.network_interface_ids, "network_interface_ids", NETWORK_INTERFACE_ID_PATTERN, "invalid_deployment_receipt"),
  };
  if (!RESOURCE_STATUSES.has(normalized.resource_status)) {
    fail("invalid_deployment_receipt", "resource_status is invalid");
  }
  if (connectionId !== undefined && normalized.connection_id !== connectionId) {
    fail("invalid_deployment_receipt", "connection_id does not match the deployment", 500);
  }
  if (deploymentId !== undefined && normalized.deployment_id !== deploymentId) {
    fail("invalid_deployment_receipt", "deployment_id does not match the deployment", 500);
  }
  if (requestSHA256 !== undefined && normalized.request_sha256 !== requestSHA256) {
    fail("invalid_deployment_receipt", "request_sha256 does not match the deployment", 500);
  }
  return normalized;
}
