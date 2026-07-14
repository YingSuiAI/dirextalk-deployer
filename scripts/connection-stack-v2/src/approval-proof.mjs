import {
  createHash,
  createPublicKey,
  verify,
} from "node:crypto";

import {
  ConnectionStackV2Error,
} from "./errors.mjs";

export const CLOUD_ORCHESTRATOR_APPROVAL_V1_SCHEMA = "cloud-orchestrator/v1";
export const APPROVAL_SIGNING_PAYLOAD_V1 = "approval-signing-payload/v1";
export const DETERMINISTIC_CBOR_SHA256 = "deterministic-cbor-sha256";

const APPROVAL_FIELDS = [
  "schema_version",
  "approval_id",
  "challenge_id",
  "signer_key_id",
  "plan_id",
  "plan_hash",
  "plan_revision",
  "quote_id",
  "quote_digest",
  "quote_valid_until",
  "cloud_connection_id",
  "recipe_digest",
  "resource_scope",
  "network_scope",
  "secret_scope",
  "integration_scope",
  "expires_at",
  "signature",
];
const RESOURCE_REQUIRED_FIELDS = [
  "region",
  "instance_type",
  "architecture",
  "vcpu",
  "memory_mib",
  "disk_gib",
  "purchase_option",
];
const RESOURCE_OPTIONAL_FIELDS = ["availability_zones", "gpu_count", "gpu_memory_mib", "spot"];
const NETWORK_REQUIRED_FIELDS = ["public_ingress", "entry_point", "tls_required", "authentication_required"];
const NETWORK_OPTIONAL_FIELDS = ["ingress"];
const SECRET_FIELDS = ["secret_ref", "purpose", "delivery"];
const INTEGRATION_FIELDS = ["kind", "name"];
const INGRESS_FIELDS = ["protocol", "port", "purpose"];
const SPOT_FIELDS = ["checkpoint_required", "max_retries"];
const OPAQUE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const BASE64URL_SIGNATURE_PATTERN = /^[A-Za-z0-9_-]{86}$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const AVAILABILITY_ZONE_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/;

function fail(code, message, statusCode = 400) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(record, required, optional, code, label) {
  if (!isRecord(record)) fail(code, `${label} must be an object`);
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(record)) {
    if (!allowed.has(key)) fail(code, `${label}.${key} is not allowed`);
  }
  for (const key of required) {
    if (!Object.hasOwn(record, key)) fail(code, `${label}.${key} is required`);
  }
}

function requireString(record, field, pattern, code) {
  const value = record[field];
  if (typeof value !== "string" || !pattern.test(value)) fail(code, `${field} is invalid`);
  return value;
}

function requireInteger(record, field, minimum, code, maximum = Number.MAX_SAFE_INTEGER) {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) fail(code, `${field} is invalid`);
  return value;
}

function requireBoolean(record, field, code) {
  if (typeof record[field] !== "boolean") fail(code, `${field} is invalid`);
  return record[field];
}

function requireUTCInstant(record, field, code) {
  const value = record[field];
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value)
    || !Number.isFinite(Date.parse(value))) {
    fail(code, `${field} is invalid`);
  }
  return value;
}

function canonicalSet(values, pattern, field, code) {
  if (!Array.isArray(values) || !values.every((value) => typeof value === "string" && pattern.test(value))) {
    fail(code, `${field} is invalid`);
  }
  if (new Set(values).size !== values.length) fail(code, `${field} must be unique`);
  return [...values].sort();
}

function normalizeResourceScope(value, code) {
  exactKeys(value, RESOURCE_REQUIRED_FIELDS, RESOURCE_OPTIONAL_FIELDS, code, "resource_scope");
  const normalized = {
    region: requireString(value, "region", REGION_PATTERN, code),
    instance_type: requireString(value, "instance_type", /^[a-z0-9][a-z0-9.-]{1,63}$/, code),
    architecture: requireString(value, "architecture", /^(?:amd64|arm64)$/, code),
    vcpu: requireInteger(value, "vcpu", 1, code, 0xffff),
    memory_mib: requireInteger(value, "memory_mib", 1, code, 0xffffffff),
    disk_gib: requireInteger(value, "disk_gib", 8, code, 16384),
    purchase_option: requireString(value, "purchase_option", /^(?:on_demand|spot)$/, code),
  };
  if (value.availability_zones !== undefined) {
    const zones = canonicalSet(value.availability_zones, AVAILABILITY_ZONE_PATTERN, "availability_zones", code);
    if (zones.length > 0) normalized.availability_zones = zones;
  }
  if (value.gpu_count !== undefined || value.gpu_memory_mib !== undefined) {
    const gpuCount = requireInteger(value, "gpu_count", 0, code, 0xffff);
    const gpuMemory = requireInteger(value, "gpu_memory_mib", 0, code, 0xffffffff);
    if ((gpuCount === 0) !== (gpuMemory === 0)) fail(code, "GPU scope is invalid");
    if (gpuCount !== 0) {
      normalized.gpu_count = gpuCount;
      normalized.gpu_memory_mib = gpuMemory;
    }
  }
  if (value.spot !== undefined) {
    exactKeys(value.spot, SPOT_FIELDS, [], code, "resource_scope.spot");
    if (normalized.purchase_option !== "spot") fail(code, "spot scope is invalid");
    normalized.spot = {
      checkpoint_required: requireBoolean(value.spot, "checkpoint_required", code),
      max_retries: requireInteger(value.spot, "max_retries", 1, code, 0xffff),
    };
  }
  if (normalized.purchase_option !== "spot" && value.spot !== undefined) fail(code, "spot scope is invalid");
  return normalized;
}

function normalizeIngress(value, code) {
  exactKeys(value, INGRESS_FIELDS, [], code, "network_scope.ingress");
  return {
    protocol: requireString(value, "protocol", /^(?:tcp|udp|http|https)$/, code),
    port: requireInteger(value, "port", 1, code, 65535),
    purpose: requireString(value, "purpose", /^[\p{L}\p{N} ._:/-]{1,128}$/u, code),
  };
}

function normalizeNetworkScope(value, code) {
  exactKeys(value, NETWORK_REQUIRED_FIELDS, NETWORK_OPTIONAL_FIELDS, code, "network_scope");
  const normalized = {
    public_ingress: requireBoolean(value, "public_ingress", code),
    entry_point: requireString(value, "entry_point", /^(?:none|alb|cloudfront|direct)$/, code),
    tls_required: requireBoolean(value, "tls_required", code),
    authentication_required: requireBoolean(value, "authentication_required", code),
  };
  if (value.ingress !== undefined) {
    if (!Array.isArray(value.ingress)) fail(code, "network_scope.ingress is invalid");
    const ingress = value.ingress.map((entry) => normalizeIngress(entry, code))
      .sort((left, right) => left.protocol.localeCompare(right.protocol)
        || left.port - right.port || left.purpose.localeCompare(right.purpose));
    if (ingress.length > 0) normalized.ingress = ingress;
  }
  return normalized;
}

function normalizeSecrets(value, code) {
  if (value === null) return null;
  if (!Array.isArray(value)) fail(code, "secret_scope is invalid");
  const secrets = value.map((item) => {
    exactKeys(item, SECRET_FIELDS, [], code, "secret_scope item");
    return {
      secret_ref: requireString(item, "secret_ref", /^secret_ref:[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/, code),
      purpose: requireString(item, "purpose", /^[\p{L}\p{N} ._:/-]{1,128}$/u, code),
      delivery: requireString(item, "delivery", /^(?:file|environment)$/, code),
    };
  }).sort((left, right) => left.secret_ref.localeCompare(right.secret_ref)
    || left.purpose.localeCompare(right.purpose) || left.delivery.localeCompare(right.delivery));
  return secrets.length === 0 ? null : secrets;
}

function normalizeIntegrations(value, code) {
  if (value === null) return null;
  if (!Array.isArray(value)) fail(code, "integration_scope is invalid");
  const integrations = value.map((item) => {
    exactKeys(item, INTEGRATION_FIELDS, [], code, "integration_scope item");
    return {
      kind: requireString(item, "kind", /^(?:mcp|acp|dirextalk_connector|web)$/, code),
      name: requireString(item, "name", /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/, code),
    };
  }).sort((left, right) => left.kind.localeCompare(right.kind) || left.name.localeCompare(right.name));
  return integrations.length === 0 ? null : integrations;
}

function normalizedApproval(proof, code = "invalid_approval_proof", { requireSignature = true } = {}) {
  exactKeys(proof, APPROVAL_FIELDS, [], code, "approval_proof");
  if (proof.schema_version !== CLOUD_ORCHESTRATOR_APPROVAL_V1_SCHEMA) fail(code, "approval_proof schema is invalid");
  const normalized = {
    schema_version: CLOUD_ORCHESTRATOR_APPROVAL_V1_SCHEMA,
    approval_id: requireString(proof, "approval_id", OPAQUE_ID_PATTERN, code),
    challenge_id: requireString(proof, "challenge_id", OPAQUE_ID_PATTERN, code),
    signer_key_id: requireString(proof, "signer_key_id", KEY_ID_PATTERN, code),
    plan_id: requireString(proof, "plan_id", OPAQUE_ID_PATTERN, code),
    plan_hash: requireString(proof, "plan_hash", NAMED_SHA256_PATTERN, code),
    plan_revision: requireInteger(proof, "plan_revision", 1, code),
    quote_id: requireString(proof, "quote_id", OPAQUE_ID_PATTERN, code),
    quote_digest: requireString(proof, "quote_digest", NAMED_SHA256_PATTERN, code),
    quote_valid_until: requireUTCInstant(proof, "quote_valid_until", code),
    cloud_connection_id: requireString(proof, "cloud_connection_id", OPAQUE_ID_PATTERN, code),
    recipe_digest: requireString(proof, "recipe_digest", NAMED_SHA256_PATTERN, code),
    resource_scope: normalizeResourceScope(proof.resource_scope, code),
    network_scope: normalizeNetworkScope(proof.network_scope, code),
    secret_scope: normalizeSecrets(proof.secret_scope, code),
    integration_scope: normalizeIntegrations(proof.integration_scope, code),
    expires_at: requireUTCInstant(proof, "expires_at", code),
    signature: requireSignature
      ? requireString(proof, "signature", BASE64URL_SIGNATURE_PATTERN, code)
      : typeof proof.signature === "string" ? proof.signature : "",
  };
  if (Date.parse(normalized.quote_valid_until) <= Date.parse(normalized.expires_at)) {
    // Quote is expected to remain valid through user confirmation and command
    // execution. A proof outliving its quote cannot authorize a purchase.
    fail(code, "approval proof expiry exceeds quote validity");
  }
  return normalized;
}

function encodeHead(major, value) {
  const numeric = typeof value === "bigint" ? value : BigInt(value);
  if (numeric < 0n) throw new TypeError("CBOR head cannot be negative");
  if (numeric < 24n) return Buffer.from([Number((BigInt(major) << 5n) | numeric)]);
  if (numeric <= 0xffn) return Buffer.from([major << 5 | 24, Number(numeric)]);
  if (numeric <= 0xffffn) return Buffer.from([major << 5 | 25, Number(numeric >> 8n), Number(numeric & 0xffn)]);
  if (numeric <= 0xffffffffn) return Buffer.from([
    major << 5 | 26,
    Number(numeric >> 24n), Number((numeric >> 16n) & 0xffn), Number((numeric >> 8n) & 0xffn), Number(numeric & 0xffn),
  ]);
  if (numeric <= 0xffffffffffffffffn) {
    const result = Buffer.alloc(9);
    result[0] = major << 5 | 27;
    for (let index = 0; index < 8; index += 1) result[8 - index] = Number((numeric >> BigInt(index * 8)) & 0xffn);
    return result;
  }
  throw new TypeError("CBOR integer is too large");
}

export function canonicalDeterministicCBOR(value) {
  if (value === null) return Buffer.from([0xf6]);
  if (value === false) return Buffer.from([0xf4]);
  if (value === true) return Buffer.from([0xf5]);
  if (typeof value === "string") {
    const bytes = Buffer.from(value, "utf8");
    return Buffer.concat([encodeHead(3, bytes.length), bytes]);
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new TypeError("CBOR approval values must be safe integers");
    return value >= 0 ? encodeHead(0, value) : encodeHead(1, -1 - value);
  }
  if (Array.isArray(value)) return Buffer.concat([encodeHead(4, value.length), ...value.map(canonicalDeterministicCBOR)]);
  if (isRecord(value)) {
    const entries = Object.entries(value).filter(([, item]) => item !== undefined)
      .map(([key, item]) => ({ encodedKey: canonicalDeterministicCBOR(key), item }));
    entries.sort((left, right) => left.encodedKey.length - right.encodedKey.length || Buffer.compare(left.encodedKey, right.encodedKey));
    return Buffer.concat([encodeHead(5, entries.length), ...entries.flatMap(({ encodedKey, item }) => [encodedKey, canonicalDeterministicCBOR(item)])]);
  }
  throw new TypeError(`unsupported deterministic CBOR value ${typeof value}`);
}

function signingPayloadObject(normalized) {
  return {
    schema_version: normalized.schema_version,
    payload_version: APPROVAL_SIGNING_PAYLOAD_V1,
    hash_algorithm: DETERMINISTIC_CBOR_SHA256,
    approval_id: normalized.approval_id,
    challenge_id: normalized.challenge_id,
    signer_key_id: normalized.signer_key_id,
    plan_id: normalized.plan_id,
    plan_hash: normalized.plan_hash,
    plan_revision: normalized.plan_revision,
    quote_id: normalized.quote_id,
    quote_digest: normalized.quote_digest,
    quote_valid_until: normalized.quote_valid_until,
    cloud_connection_id: normalized.cloud_connection_id,
    recipe_digest: normalized.recipe_digest,
    resource_scope: normalized.resource_scope,
    network_scope: normalized.network_scope,
    secret_scope: normalized.secret_scope,
    integration_scope: normalized.integration_scope,
    expires_at: normalized.expires_at,
  };
}

export function canonicalApprovalProofPayload(proof) {
  const normalized = normalizedApproval(proof, "invalid_approval_proof", { requireSignature: false });
  return canonicalDeterministicCBOR(signingPayloadObject(normalized));
}

export function approvalProofPayloadSHA256(proof) {
  return createHash("sha256").update(canonicalApprovalProofPayload(proof)).digest("hex");
}

export function validateApprovalProof(proof, {
  deviceKeyId,
  devicePublicKeySpkiBase64,
  nowMs,
  allowExpiredReplay = false,
} = {}) {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) fail("invalid_approval_proof", "verification clock is invalid", 500);
  const normalized = normalizedApproval(proof);
  if (normalized.signer_key_id !== deviceKeyId) fail("unknown_device_key", "approval signer key is not active", 401);
  if (!allowExpiredReplay && (Date.parse(normalized.expires_at) <= nowMs || Date.parse(normalized.quote_valid_until) <= nowMs)) {
    fail("approval_expired", "approval proof or quote has expired", 401);
  }
  let deviceKey;
  try {
    deviceKey = createPublicKey({
      key: Buffer.from(devicePublicKeySpkiBase64, "base64"),
      format: "der",
      type: "spki",
    });
  } catch {
    fail("invalid_stack_device_key", "configured device public key is invalid", 500);
  }
  if (deviceKey.asymmetricKeyType !== "ed25519") fail("invalid_stack_device_key", "configured device key is not Ed25519", 500);
  const signature = Buffer.from(normalized.signature, "base64url");
  if (signature.length !== 64 || signature.toString("base64url") !== normalized.signature
    || !verify(null, canonicalDeterministicCBOR(signingPayloadObject(normalized)), deviceKey, signature)) {
    fail("invalid_approval_proof_signature", "approval proof signature is invalid", 401);
  }
  return normalized;
}

export function validateApprovalProofAgainstDeployment(proof, {
  connectionId,
  payload,
  nowMs,
  allowExpiredReplay = false,
} = {}) {
  const normalized = normalizedApproval(proof);
  if (!isRecord(payload) || typeof connectionId !== "string" || !Number.isSafeInteger(nowMs)) {
    fail("approval_proof_mismatch", "deployment approval context is invalid", 500);
  }
  if (normalized.cloud_connection_id !== connectionId
    || normalized.plan_hash !== payload.plan_hash
    || normalized.plan_revision !== payload.plan_revision
    || normalized.quote_id !== payload.quote_id
    || normalized.quote_digest !== payload.quote_digest
    || (!allowExpiredReplay && (Date.parse(normalized.expires_at) <= nowMs
      || Date.parse(normalized.quote_valid_until) <= nowMs))) {
    fail("approval_proof_mismatch", "approval proof does not bind this deployment", 409);
  }
  if (normalized.network_scope.public_ingress || normalized.network_scope.entry_point !== "none"
    || normalized.network_scope.tls_required || normalized.network_scope.authentication_required
    || (normalized.network_scope.ingress?.length ?? 0) !== 0) {
    fail("approval_proof_mismatch", "isolated Worker creation requires the approved no-public-ingress network scope", 409);
  }
  return normalized;
}
