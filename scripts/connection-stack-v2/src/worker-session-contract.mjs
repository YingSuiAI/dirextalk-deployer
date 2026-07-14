import { createHash } from "node:crypto";

import { ConnectionStackV2Error } from "./errors.mjs";

export { ConnectionStackV2Error };

export const WORKER_SESSION_CLAIM_V1_SCHEMA = "dirextalk.worker-session-claim/v1";
export const WORKER_SESSION_CLAIM_RESPONSE_V1_SCHEMA = "dirextalk.worker-session-claim-response/v1";
export const WORKER_EVENT_V1_SCHEMA = "dirextalk.worker-event/v1";
export const WORKER_EVENT_RECEIPT_V1_SCHEMA = "dirextalk.worker-event-receipt/v1";
export const WORKER_SESSION_MAX_LEASE_LIFETIME_MS = 10 * 60 * 1000;

const MAX_IDENTITY_DOCUMENT_BYTES = 64 * 1024;
const MAX_IDENTITY_SIGNATURE_BYTES = 32 * 1024;
const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const CANONICAL_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const CANONICAL_BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const SAFE_CODE_PATTERN = /^[a-z][a-z0-9_]{0,95}$/;

const CLAIM_FIELDS = [
  "schema",
  "connection_id",
  "deployment_id",
  "bootstrap_session_id",
  "worker_image_digest",
  "artifact_manifest_digest",
  "instance_identity_document_b64",
  "instance_identity_signature_b64",
];
const EVENT_REQUIRED_FIELDS = [
  "schema",
  "connection_id",
  "deployment_id",
  "bootstrap_session_id",
  "lease_epoch",
  "sequence",
  "kind",
  "occurred_at",
];
const EVENT_OPTIONAL_FIELDS = [
  "checkpoint",
  "report_status",
  "error_code",
  "evidence_digest",
];
const EVENT_RECEIPT_FIELDS = [
  "schema",
  "connection_id",
  "deployment_id",
  "bootstrap_session_id",
  "lease_epoch",
  "sequence",
  "disposition",
];
const CLAIM_RESPONSE_FIELDS = [
  "schema",
  "connection_id",
  "deployment_id",
  "bootstrap_session_id",
  "lease_epoch",
  "lease_expires_at",
  "access_token",
];
const REPORT_STATUSES = new Set([
  "installing",
  "waiting_user",
  "local_ready_unverified",
  "succeeded",
  "failed",
  "interrupted",
]);

function fail(code, message) {
  throw new ConnectionStackV2Error(code, message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireRecord(value, code, label) {
  if (!isRecord(value)) fail(code, `${label} must be an object`);
  return value;
}

function requireExactFields(record, requiredFields, optionalFields, code, label) {
  requireRecord(record, code, label);
  const allowed = new Set([...requiredFields, ...optionalFields]);
  for (const key of requiredFields) {
    if (!Object.hasOwn(record, key)) fail(code, `${label}.${key} is required`);
  }
  for (const key of Object.keys(record)) {
    if (!allowed.has(key)) fail(code, `${label}.${key} is not allowed`);
  }
}

function requireString(record, key, pattern, code, label) {
  const value = record[key];
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${label}.${key} is invalid`);
  }
  return value;
}

function requirePositiveSafeInteger(record, key, code, label) {
  const value = record[key];
  if (!Number.isSafeInteger(value) || value <= 0) {
    fail(code, `${label}.${key} must be a positive safe integer`);
  }
  return value;
}

function requireOptionalString(record, key, code, label) {
  if (!Object.hasOwn(record, key)) return "";
  if (typeof record[key] !== "string") fail(code, `${label}.${key} is invalid`);
  return record[key];
}

function parseCanonicalInstant(value, code, label) {
  if (typeof value !== "string" || !CANONICAL_INSTANT_PATTERN.test(value)) {
    fail(code, `${label} is not a canonical UTC timestamp`);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) {
    fail(code, `${label} is not a canonical UTC timestamp`);
  }
  return milliseconds;
}

function requireCanonicalBase64(record, key, maximumBytes, code, label) {
  const value = record[key];
  if (typeof value !== "string" || value.length === 0 || value.length > maximumBytes * 2 ||
      value.trim() !== value || value.length % 4 !== 0 || !CANONICAL_BASE64_PATTERN.test(value)) {
    fail(code, `${label}.${key} must be canonical padded base64`);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.length === 0 || decoded.length > maximumBytes || decoded.toString("base64") !== value) {
    fail(code, `${label}.${key} must be canonical padded base64`);
  }
  return value;
}

function requireOpaqueToken(record, key, code, label) {
  const value = record[key];
  if (typeof value !== "string" || value.length < 16 || value.length > 4096 || value.trim() !== value) {
    fail(code, `${label}.${key} is invalid`);
  }
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint < 0x21 || codePoint > 0x7e || character === '"' || character === "\\") {
      fail(code, `${label}.${key} is invalid`);
    }
  }
  return value;
}

// parseStrictJSONObject is intentionally exported for the IID verifier as
// well as session routes. Native JSON.parse silently uses the final duplicate
// property, which is unsafe for identity documents and binding payloads.
export function parseStrictJSONObject(raw, {
  code = "invalid_worker_session_payload",
  label = "worker session payload",
} = {}) {
  let text;
  if (typeof raw === "string") {
    text = raw;
  } else if (Buffer.isBuffer(raw) || raw instanceof Uint8Array) {
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(raw);
    } catch {
      fail(code, `${label} must be UTF-8 JSON`);
    }
  } else {
    fail(code, `${label} must be UTF-8 JSON`);
  }
  if (text.length === 0) fail(code, `${label} must be a JSON object`);
  try {
    rejectDuplicateJSONKeys(text);
    const parsed = JSON.parse(text);
    requireRecord(parsed, code, label);
    return parsed;
  } catch (error) {
    if (error instanceof ConnectionStackV2Error) throw error;
    fail(code, `${label} must be valid JSON without duplicate keys`);
  }
}

function parseWorkerValue(rawOrObject, code, label) {
  if (isRecord(rawOrObject)) return rawOrObject;
  return parseStrictJSONObject(rawOrObject, { code, label });
}

// JSON.parse intentionally applies last-key-wins semantics. The Worker
// protocol must not: an attacker must not be able to hide a bound identity or
// sequence beneath a duplicate JSON property. This scanner sees decoded keys
// before JSON.parse materializes the object and checks nested objects too.
function rejectDuplicateJSONKeys(text) {
  let index = 0;

  function skipWhitespace() {
    while (index < text.length && (text[index] === " " || text[index] === "\n" || text[index] === "\r" || text[index] === "\t")) {
      index += 1;
    }
  }

  function readString() {
    const start = index;
    if (text[index] !== '"') throw new Error("JSON string expected");
    index += 1;
    while (index < text.length) {
      const character = text[index];
      if (character === '"') {
        index += 1;
        return JSON.parse(text.slice(start, index));
      }
      if (character === "\\") {
        index += 2;
      } else {
        index += 1;
      }
    }
    throw new Error("unterminated JSON string");
  }

  function readPrimitive() {
    const start = index;
    while (index < text.length && ![",", "]", "}", " ", "\n", "\r", "\t"].includes(text[index])) {
      index += 1;
    }
    if (start === index) throw new Error("JSON primitive expected");
  }

  function readArray() {
    index += 1;
    skipWhitespace();
    if (text[index] === "]") {
      index += 1;
      return;
    }
    while (true) {
      readValue();
      skipWhitespace();
      if (text[index] === ",") {
        index += 1;
        skipWhitespace();
        continue;
      }
      if (text[index] === "]") {
        index += 1;
        return;
      }
      throw new Error("JSON array is invalid");
    }
  }

  function readObject() {
    index += 1;
    skipWhitespace();
    const keys = new Set();
    if (text[index] === "}") {
      index += 1;
      return;
    }
    while (true) {
      const key = readString();
      if (keys.has(key)) throw new Error("JSON object contains duplicate keys");
      keys.add(key);
      skipWhitespace();
      if (text[index] !== ":") throw new Error("JSON object is invalid");
      index += 1;
      readValue();
      skipWhitespace();
      if (text[index] === ",") {
        index += 1;
        skipWhitespace();
        continue;
      }
      if (text[index] === "}") {
        index += 1;
        return;
      }
      throw new Error("JSON object is invalid");
    }
  }

  function readValue() {
    skipWhitespace();
    switch (text[index]) {
      case "{":
        readObject();
        return;
      case "[":
        readArray();
        return;
      case '"':
        readString();
        return;
      default:
        readPrimitive();
    }
  }

  skipWhitespace();
  readValue();
  skipWhitespace();
  if (index !== text.length) throw new Error("trailing JSON data");
}

function canonicalClaim(record) {
  return Object.fromEntries(CLAIM_FIELDS.map((field) => [field, record[field]]));
}

function canonicalEvent({
  schema,
  connection_id: connectionId,
  deployment_id: deploymentId,
  bootstrap_session_id: bootstrapSessionId,
  lease_epoch: leaseEpoch,
  sequence,
  kind,
  checkpoint,
  report_status: reportStatus,
  error_code: errorCode,
  evidence_digest: evidenceDigest,
  occurred_at: occurredAt,
}) {
  const event = {
    schema,
    connection_id: connectionId,
    deployment_id: deploymentId,
    bootstrap_session_id: bootstrapSessionId,
    lease_epoch: leaseEpoch,
    sequence,
    kind,
  };
  if (checkpoint !== "") event.checkpoint = checkpoint;
  if (reportStatus !== "") event.report_status = reportStatus;
  if (errorCode !== "") event.error_code = errorCode;
  if (evidenceDigest !== "") event.evidence_digest = evidenceDigest;
  event.occurred_at = occurredAt;
  return event;
}

function canonicalEventReceipt(record) {
  return Object.fromEntries(EVENT_RECEIPT_FIELDS.map((field) => [field, record[field]]));
}

function canonicalClaimResponse(record) {
  return Object.fromEntries(CLAIM_RESPONSE_FIELDS.map((field) => [field, record[field]]));
}

export function validateWorkerSessionClaim(claim) {
  const code = "invalid_worker_session_claim";
  requireExactFields(claim, CLAIM_FIELDS, [], code, "worker session claim");
  if (claim.schema !== WORKER_SESSION_CLAIM_V1_SCHEMA) fail(code, "worker session claim.schema is invalid");
  requireString(claim, "connection_id", IDENTIFIER_PATTERN, code, "worker session claim");
  requireString(claim, "deployment_id", IDENTIFIER_PATTERN, code, "worker session claim");
  requireString(claim, "bootstrap_session_id", IDENTIFIER_PATTERN, code, "worker session claim");
  requireString(claim, "worker_image_digest", NAMED_SHA256_PATTERN, code, "worker session claim");
  requireString(claim, "artifact_manifest_digest", NAMED_SHA256_PATTERN, code, "worker session claim");
  requireCanonicalBase64(claim, "instance_identity_document_b64", MAX_IDENTITY_DOCUMENT_BYTES, code, "worker session claim");
  requireCanonicalBase64(claim, "instance_identity_signature_b64", MAX_IDENTITY_SIGNATURE_BYTES, code, "worker session claim");
  return canonicalClaim(claim);
}

export function parseWorkerSessionClaim(rawOrObject) {
  return validateWorkerSessionClaim(parseWorkerValue(
    rawOrObject,
    "invalid_worker_session_claim",
    "worker session claim",
  ));
}

export function validateWorkerEvent(event) {
  const code = "invalid_worker_event";
  requireExactFields(event, EVENT_REQUIRED_FIELDS, EVENT_OPTIONAL_FIELDS, code, "worker event");
  if (event.schema !== WORKER_EVENT_V1_SCHEMA) fail(code, "worker event.schema is invalid");
  const schema = event.schema;
  const connectionId = requireString(event, "connection_id", IDENTIFIER_PATTERN, code, "worker event");
  const deploymentId = requireString(event, "deployment_id", IDENTIFIER_PATTERN, code, "worker event");
  const bootstrapSessionId = requireString(event, "bootstrap_session_id", IDENTIFIER_PATTERN, code, "worker event");
  const leaseEpoch = requirePositiveSafeInteger(event, "lease_epoch", code, "worker event");
  const sequence = requirePositiveSafeInteger(event, "sequence", code, "worker event");
  const kind = event.kind;
  if (typeof kind !== "string") fail(code, "worker event.kind is invalid");
  const checkpoint = requireOptionalString(event, "checkpoint", code, "worker event");
  const reportStatus = requireOptionalString(event, "report_status", code, "worker event");
  const errorCode = requireOptionalString(event, "error_code", code, "worker event");
  const evidenceDigest = requireOptionalString(event, "evidence_digest", code, "worker event");
  const occurredAt = requireString(event, "occurred_at", CANONICAL_INSTANT_PATTERN, code, "worker event");
  parseCanonicalInstant(occurredAt, code, "worker event.occurred_at");

  if (checkpoint !== "" && !SAFE_CODE_PATTERN.test(checkpoint)) fail(code, "worker event.checkpoint is invalid");
  if (errorCode !== "" && !SAFE_CODE_PATTERN.test(errorCode)) fail(code, "worker event.error_code is invalid");
  if (evidenceDigest !== "" && !NAMED_SHA256_PATTERN.test(evidenceDigest)) fail(code, "worker event.evidence_digest is invalid");

  switch (kind) {
    case "heartbeat":
      if (checkpoint !== "" || reportStatus !== "" || errorCode !== "" || evidenceDigest !== "") {
        fail(code, "worker heartbeat is invalid");
      }
      break;
    case "checkpoint":
      if (checkpoint === "" || reportStatus !== "" || errorCode !== "") {
        fail(code, "worker checkpoint is invalid");
      }
      break;
    case "report":
      if (!REPORT_STATUSES.has(reportStatus) || checkpoint !== "") {
        fail(code, "worker report is invalid");
      }
      if (reportStatus === "failed" && errorCode === "") fail(code, "worker failed report is invalid");
      if (reportStatus !== "failed" && errorCode !== "") fail(code, "worker report is invalid");
      break;
    default:
      fail(code, "worker event.kind is invalid");
  }

  return canonicalEvent({
    schema,
    connection_id: connectionId,
    deployment_id: deploymentId,
    bootstrap_session_id: bootstrapSessionId,
    lease_epoch: leaseEpoch,
    sequence,
    kind,
    checkpoint,
    report_status: reportStatus,
    error_code: errorCode,
    evidence_digest: evidenceDigest,
    occurred_at: occurredAt,
  });
}

export function parseWorkerSessionEvent(rawOrObject) {
  return validateWorkerEvent(parseWorkerValue(
    rawOrObject,
    "invalid_worker_event",
    "worker event",
  ));
}

// Keep the shorter name for the first test-only consumer while preferring the
// session-qualified export in all Stack routes and stores.
export const parseWorkerEvent = parseWorkerSessionEvent;

export function workerSessionEventSHA256(event) {
  const canonical = validateWorkerEvent(event);
  return createHash("sha256").update(JSON.stringify(canonical), "utf8").digest("hex");
}

export const workerEventSHA256 = workerSessionEventSHA256;

export function validateWorkerEventReceipt(receipt, event) {
  const code = "invalid_worker_event_receipt";
  requireExactFields(receipt, EVENT_RECEIPT_FIELDS, [], code, "worker event receipt");
  if (receipt.schema !== WORKER_EVENT_RECEIPT_V1_SCHEMA) fail(code, "worker event receipt.schema is invalid");
  const expectedEvent = validateWorkerEvent(event);
  const connectionId = requireString(receipt, "connection_id", IDENTIFIER_PATTERN, code, "worker event receipt");
  const deploymentId = requireString(receipt, "deployment_id", IDENTIFIER_PATTERN, code, "worker event receipt");
  const bootstrapSessionId = requireString(receipt, "bootstrap_session_id", IDENTIFIER_PATTERN, code, "worker event receipt");
  const leaseEpoch = requirePositiveSafeInteger(receipt, "lease_epoch", code, "worker event receipt");
  const sequence = requirePositiveSafeInteger(receipt, "sequence", code, "worker event receipt");
  if (receipt.disposition !== "accepted" && receipt.disposition !== "idempotent") {
    fail(code, "worker event receipt.disposition is invalid");
  }
  if (connectionId !== expectedEvent.connection_id || deploymentId !== expectedEvent.deployment_id ||
      bootstrapSessionId !== expectedEvent.bootstrap_session_id || leaseEpoch !== expectedEvent.lease_epoch ||
      sequence !== expectedEvent.sequence) {
    fail(code, "worker event receipt does not match its event");
  }
  return canonicalEventReceipt(receipt);
}

export function parseWorkerEventReceipt(rawOrObject, event) {
  const receipt = parseWorkerValue(
    rawOrObject,
    "invalid_worker_event_receipt",
    "worker event receipt",
  );
  if (event === undefined) {
    // A generic parser is useful for a broker response builder, while the
    // client-side path must use validateWorkerEventReceipt to bind a pending event.
    requireExactFields(receipt, EVENT_RECEIPT_FIELDS, [], "invalid_worker_event_receipt", "worker event receipt");
    if (receipt.schema !== WORKER_EVENT_RECEIPT_V1_SCHEMA) {
      fail("invalid_worker_event_receipt", "worker event receipt.schema is invalid");
    }
    requireString(receipt, "connection_id", IDENTIFIER_PATTERN, "invalid_worker_event_receipt", "worker event receipt");
    requireString(receipt, "deployment_id", IDENTIFIER_PATTERN, "invalid_worker_event_receipt", "worker event receipt");
    requireString(receipt, "bootstrap_session_id", IDENTIFIER_PATTERN, "invalid_worker_event_receipt", "worker event receipt");
    requirePositiveSafeInteger(receipt, "lease_epoch", "invalid_worker_event_receipt", "worker event receipt");
    requirePositiveSafeInteger(receipt, "sequence", "invalid_worker_event_receipt", "worker event receipt");
    if (receipt.disposition !== "accepted" && receipt.disposition !== "idempotent") {
      fail("invalid_worker_event_receipt", "worker event receipt.disposition is invalid");
    }
    return canonicalEventReceipt(receipt);
  }
  return validateWorkerEventReceipt(receipt, event);
}

function validateClaimResponseContext(context) {
  const code = "invalid_worker_session_claim_response";
  requireRecord(context, code, "worker session claim response context");
  const expectedConnectionId = requireString(context, "expectedConnectionId", IDENTIFIER_PATTERN, code, "worker session claim response context");
  const expectedDeploymentId = requireString(context, "expectedDeploymentId", IDENTIFIER_PATTERN, code, "worker session claim response context");
  const expectedBootstrapSessionId = requireString(context, "expectedBootstrapSessionId", IDENTIFIER_PATTERN, code, "worker session claim response context");
  if (!Number.isSafeInteger(context.nowMs) || context.nowMs < 0) {
    fail(code, "worker session claim response context.nowMs is invalid");
  }
  const maxLeaseLifetimeMs = context.maxLeaseLifetimeMs ?? WORKER_SESSION_MAX_LEASE_LIFETIME_MS;
  if (!Number.isSafeInteger(maxLeaseLifetimeMs) || maxLeaseLifetimeMs < 1 || maxLeaseLifetimeMs > WORKER_SESSION_MAX_LEASE_LIFETIME_MS) {
    fail(code, "worker session claim response context.maxLeaseLifetimeMs is invalid");
  }
  return {
    expectedConnectionId,
    expectedDeploymentId,
    expectedBootstrapSessionId,
    nowMs: context.nowMs,
    maxLeaseLifetimeMs,
  };
}

export function validateWorkerSessionClaimResponse(response, context) {
  const code = "invalid_worker_session_claim_response";
  const expected = validateClaimResponseContext(context);
  requireExactFields(response, CLAIM_RESPONSE_FIELDS, [], code, "worker session claim response");
  if (response.schema !== WORKER_SESSION_CLAIM_RESPONSE_V1_SCHEMA) {
    fail(code, "worker session claim response.schema is invalid");
  }
  const connectionId = requireString(response, "connection_id", IDENTIFIER_PATTERN, code, "worker session claim response");
  const deploymentId = requireString(response, "deployment_id", IDENTIFIER_PATTERN, code, "worker session claim response");
  const bootstrapSessionId = requireString(response, "bootstrap_session_id", IDENTIFIER_PATTERN, code, "worker session claim response");
  if (connectionId !== expected.expectedConnectionId || deploymentId !== expected.expectedDeploymentId ||
      bootstrapSessionId !== expected.expectedBootstrapSessionId) {
    fail(code, "worker session claim response does not match its session");
  }
  requirePositiveSafeInteger(response, "lease_epoch", code, "worker session claim response");
  const expiresAtMs = parseCanonicalInstant(response.lease_expires_at, code, "worker session claim response.lease_expires_at");
  if (expiresAtMs <= expected.nowMs || expiresAtMs - expected.nowMs > expected.maxLeaseLifetimeMs) {
    fail(code, "worker session claim response lease is invalid");
  }
  requireOpaqueToken(response, "access_token", code, "worker session claim response");
  return canonicalClaimResponse(response);
}

export function parseWorkerSessionClaimResponse(rawOrObject, context) {
  return validateWorkerSessionClaimResponse(
    parseWorkerValue(
      rawOrObject,
      "invalid_worker_session_claim_response",
      "worker session claim response",
    ),
    context,
  );
}
