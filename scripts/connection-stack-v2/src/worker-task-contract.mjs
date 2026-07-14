import {
  createHash,
} from "node:crypto";

import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  parseStrictJSONObject,
} from "./worker-session-contract.mjs";

export const WORKER_TASK_ISSUE_V1_SCHEMA = "dirextalk.worker-task-issue/v1";
export const WORKER_TASK_CLAIM_V1_SCHEMA = "dirextalk.worker-task-claim/v1";
export const WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA = "dirextalk.worker-task-claim-response/v1";
export const WORKER_TASK_DOCUMENT_V1_SCHEMA = "dirextalk.worker-task/v1";
export const WORKER_TASK_EVENT_V1_SCHEMA = "dirextalk.worker-task-event/v1";
export const WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA = "dirextalk.worker-task-event-receipt/v1";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const SAFE_CODE_PATTERN = /^[a-z][a-z0-9_]{0,95}$/;
const CANONICAL_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const EXECUTION_PROBE_RECEIVED_CHECKPOINT = "execution_manifest_received";
const EXECUTION_PROBE_VERIFIED_CHECKPOINT = "task_transport_verified";

const ISSUE_FIELDS = [
  "schema",
  "deployment_id",
  "task_id",
  "task_kind",
  "execution_manifest_digest",
  "input_digest",
];
const CLAIM_FIELDS = ["schema", "lease_epoch"];
const CLAIM_RESPONSE_BASE_FIELDS = ["schema", "status", "lease_epoch"];
const TASK_DOCUMENT_FIELDS = [
  "schema",
  "task_id",
  "deployment_id",
  "task_kind",
  "execution_manifest_digest",
  "input_digest",
  "attempt",
  "last_sequence",
];
const TASK_EVENT_FIELDS = [
  "schema",
  "task_id",
  "attempt",
  "lease_epoch",
  "sequence",
  "status",
  "checkpoint",
  "error_code",
  "evidence_digest",
  "occurred_at",
];
const TASK_EVENT_RECEIPT_FIELDS = [
  "schema",
  "task_id",
  "attempt",
  "lease_epoch",
  "sequence",
  "disposition",
];
const TASK_SUMMARY_FIELDS = [
  "task_id",
  "deployment_id",
  "status",
  "attempt",
  "last_sequence",
  "checkpoint",
  "error_code",
  "evidence_digest",
  "updated_at",
];

function fail(code, message, statusCode = 400) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireRecord(value, code, label) {
  if (!isRecord(value)) fail(code, `${label} must be an object`);
  return value;
}

function requireExactFields(record, fields, code, label, optional = []) {
  requireRecord(record, code, label);
  const allowed = new Set([...fields, ...optional]);
  for (const field of fields) {
    if (!Object.hasOwn(record, field)) fail(code, `${label}.${field} is required`);
  }
  for (const field of Object.keys(record)) {
    if (!allowed.has(field)) fail(code, `${label}.${field} is not allowed`);
  }
}

function requireString(record, field, pattern, code, label) {
  const value = record[field];
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${label}.${field} is invalid`);
  }
  return value;
}

function requirePositiveInteger(record, field, code, label) {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < 1) {
    fail(code, `${label}.${field} must be a positive safe integer`);
  }
  return value;
}

function requireNonnegativeInteger(record, field, code, label) {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(code, `${label}.${field} must be a nonnegative safe integer`);
  }
  return value;
}

function requireNullableSafeCode(record, field, code, label) {
  const value = record[field];
  if (value === null) return null;
  if (typeof value !== "string" || !SAFE_CODE_PATTERN.test(value)) {
    fail(code, `${label}.${field} is invalid`);
  }
  return value;
}

function requireNullableDigest(record, field, code, label) {
  const value = record[field];
  if (value === null) return null;
  if (typeof value !== "string" || !NAMED_SHA256_PATTERN.test(value)) {
    fail(code, `${label}.${field} is invalid`);
  }
  return value;
}

function requireCanonicalInstant(record, field, code, label) {
  const value = requireString(record, field, CANONICAL_INSTANT_PATTERN, code, label);
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) {
    fail(code, `${label}.${field} is invalid`);
  }
  return value;
}

function parseTaskValue(rawOrObject, code, label) {
  if (isRecord(rawOrObject)) return rawOrObject;
  return parseStrictJSONObject(rawOrObject, { code, label });
}

function canonicalIssue({
  deployment_id: deploymentId,
  task_id: taskId,
  execution_manifest_digest: executionManifestDigest,
  input_digest: inputDigest,
}) {
  return {
    schema: WORKER_TASK_ISSUE_V1_SCHEMA,
    deployment_id: deploymentId,
    task_id: taskId,
    task_kind: "execution_probe",
    execution_manifest_digest: executionManifestDigest,
    input_digest: inputDigest,
  };
}

// The issue payload has no command, URL, secret, AWS API, image tag, or
// arbitrary task kind. It is only a digest-pinned execution-probe reference;
// the later Worker executor remains a separate, deliberately closed boundary.
export function validateWorkerTaskIssue(issue, { code = "invalid_worker_task_issue" } = {}) {
  requireExactFields(issue, ISSUE_FIELDS, code, "worker task issue");
  if (issue.schema !== WORKER_TASK_ISSUE_V1_SCHEMA) {
    fail(code, "worker task issue.schema is invalid");
  }
  if (issue.task_kind !== "execution_probe") {
    fail(code, "worker task issue.task_kind is invalid");
  }
  return canonicalIssue({
    deployment_id: requireString(issue, "deployment_id", ID_PATTERN, code, "worker task issue"),
    task_id: requireString(issue, "task_id", ID_PATTERN, code, "worker task issue"),
    execution_manifest_digest: requireString(issue, "execution_manifest_digest", NAMED_SHA256_PATTERN, code, "worker task issue"),
    input_digest: requireString(issue, "input_digest", NAMED_SHA256_PATTERN, code, "worker task issue"),
  });
}

export function parseWorkerTaskIssue(rawOrObject) {
  return validateWorkerTaskIssue(parseTaskValue(
    rawOrObject,
    "invalid_worker_task_issue",
    "worker task issue",
  ));
}

export function validateWorkerTaskClaim(claim) {
  const code = "invalid_worker_task_claim";
  requireExactFields(claim, CLAIM_FIELDS, code, "worker task claim");
  if (claim.schema !== WORKER_TASK_CLAIM_V1_SCHEMA) {
    fail(code, "worker task claim.schema is invalid");
  }
  return {
    schema: WORKER_TASK_CLAIM_V1_SCHEMA,
    lease_epoch: requirePositiveInteger(claim, "lease_epoch", code, "worker task claim"),
  };
}

export function parseWorkerTaskClaim(rawOrObject) {
  return validateWorkerTaskClaim(parseTaskValue(
    rawOrObject,
    "invalid_worker_task_claim",
    "worker task claim",
  ));
}

export function validateWorkerTaskDocument(document, {
  expectedTaskId,
  expectedDeploymentId,
} = {}) {
  const code = "invalid_worker_task_document";
  requireExactFields(document, TASK_DOCUMENT_FIELDS, code, "worker task document");
  if (document.schema !== WORKER_TASK_DOCUMENT_V1_SCHEMA || document.task_kind !== "execution_probe") {
    fail(code, "worker task document schema or kind is invalid");
  }
  const normalized = {
    schema: WORKER_TASK_DOCUMENT_V1_SCHEMA,
    task_id: requireString(document, "task_id", ID_PATTERN, code, "worker task document"),
    deployment_id: requireString(document, "deployment_id", ID_PATTERN, code, "worker task document"),
    task_kind: "execution_probe",
    execution_manifest_digest: requireString(document, "execution_manifest_digest", NAMED_SHA256_PATTERN, code, "worker task document"),
    input_digest: requireString(document, "input_digest", NAMED_SHA256_PATTERN, code, "worker task document"),
    attempt: requirePositiveInteger(document, "attempt", code, "worker task document"),
    last_sequence: requireNonnegativeInteger(document, "last_sequence", code, "worker task document"),
  };
  if (expectedTaskId !== undefined && normalized.task_id !== expectedTaskId) {
    fail(code, "worker task document does not match its task");
  }
  if (expectedDeploymentId !== undefined && normalized.deployment_id !== expectedDeploymentId) {
    fail(code, "worker task document does not match its deployment");
  }
  return normalized;
}

function validateTaskOutcome({
  status,
  checkpoint,
  errorCode,
  evidenceDigest,
  lastSequence,
  code,
  label,
}) {
  if (status === "queued") {
    if (lastSequence !== 0 || checkpoint !== null || errorCode !== null || evidenceDigest !== null) {
      fail(code, `${label} queued state is invalid`);
    }
    return;
  }
  if (status === "running") {
    if (lastSequence < 1 || checkpoint === null || evidenceDigest === null || errorCode !== null) {
      fail(code, `${label} running state is invalid`);
    }
    if (checkpoint !== EXECUTION_PROBE_RECEIVED_CHECKPOINT) {
      fail(code, `${label} running checkpoint is invalid`);
    }
    return;
  }
  if (status === "succeeded") {
    if (lastSequence < 1 || checkpoint === null || evidenceDigest === null || errorCode !== null) {
      fail(code, `${label} succeeded state is invalid`);
    }
    if (checkpoint !== EXECUTION_PROBE_VERIFIED_CHECKPOINT) {
      fail(code, `${label} succeeded checkpoint is invalid`);
    }
    return;
  }
  if (status === "failed" || status === "interrupted") {
    if (lastSequence < 1 || checkpoint !== null || evidenceDigest !== null || errorCode === null) {
      fail(code, `${label} failed/interrupted state is invalid`);
    }
    return;
  }
  fail(code, `${label}.status is invalid`);
}

export function validateWorkerTaskSummary(summary, {
  expectedTaskId,
  expectedDeploymentId,
} = {}) {
  const code = "invalid_worker_task_summary";
  requireExactFields(summary, TASK_SUMMARY_FIELDS, code, "worker task summary");
  const normalized = {
    task_id: requireString(summary, "task_id", ID_PATTERN, code, "worker task summary"),
    deployment_id: requireString(summary, "deployment_id", ID_PATTERN, code, "worker task summary"),
    status: requireString(summary, "status", /^(?:queued|running|succeeded|failed|interrupted)$/, code, "worker task summary"),
    attempt: requirePositiveInteger(summary, "attempt", code, "worker task summary"),
    last_sequence: requireNonnegativeInteger(summary, "last_sequence", code, "worker task summary"),
    checkpoint: requireNullableSafeCode(summary, "checkpoint", code, "worker task summary"),
    error_code: requireNullableSafeCode(summary, "error_code", code, "worker task summary"),
    evidence_digest: requireNullableDigest(summary, "evidence_digest", code, "worker task summary"),
    updated_at: requireCanonicalInstant(summary, "updated_at", code, "worker task summary"),
  };
  validateTaskOutcome({
    status: normalized.status,
    checkpoint: normalized.checkpoint,
    errorCode: normalized.error_code,
    evidenceDigest: normalized.evidence_digest,
    lastSequence: normalized.last_sequence,
    code,
    label: "worker task summary",
  });
  if (expectedTaskId !== undefined && normalized.task_id !== expectedTaskId) {
    fail(code, "worker task summary does not match its task");
  }
  if (expectedDeploymentId !== undefined && normalized.deployment_id !== expectedDeploymentId) {
    fail(code, "worker task summary does not match its deployment");
  }
  return normalized;
}

export function validateWorkerTaskClaimResponse(response) {
  const code = "invalid_worker_task_claim_response";
  requireRecord(response, code, "worker task claim response");
  const status = response.status;
  if (status !== "none" && status !== "claimed") {
    fail(code, "worker task claim response.status is invalid");
  }
  requireExactFields(
    response,
    CLAIM_RESPONSE_BASE_FIELDS,
    code,
    "worker task claim response",
    status === "claimed" ? ["task"] : [],
  );
  if (response.schema !== WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA) {
    fail(code, "worker task claim response.schema is invalid");
  }
  const normalized = {
    schema: WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
    status,
    lease_epoch: requirePositiveInteger(response, "lease_epoch", code, "worker task claim response"),
  };
  if (status === "claimed") {
    if (!Object.hasOwn(response, "task")) fail(code, "worker task claim response.task is required");
    try {
      normalized.task = validateWorkerTaskDocument(response.task);
    } catch (error) {
      if (error instanceof ConnectionStackV2Error) {
        fail(code, "worker task claim response.task is invalid");
      }
      throw error;
    }
  }
  return normalized;
}

export function parseWorkerTaskClaimResponse(rawOrObject) {
  return validateWorkerTaskClaimResponse(parseTaskValue(
    rawOrObject,
    "invalid_worker_task_claim_response",
    "worker task claim response",
  ));
}

export function validateWorkerTaskEvent(event) {
  const code = "invalid_worker_task_event";
  requireExactFields(event, TASK_EVENT_FIELDS, code, "worker task event");
  if (event.schema !== WORKER_TASK_EVENT_V1_SCHEMA) {
    fail(code, "worker task event.schema is invalid");
  }
  const normalized = {
    schema: WORKER_TASK_EVENT_V1_SCHEMA,
    task_id: requireString(event, "task_id", ID_PATTERN, code, "worker task event"),
    attempt: requirePositiveInteger(event, "attempt", code, "worker task event"),
    lease_epoch: requirePositiveInteger(event, "lease_epoch", code, "worker task event"),
    sequence: requirePositiveInteger(event, "sequence", code, "worker task event"),
    status: requireString(event, "status", /^(?:running|succeeded|failed|interrupted)$/, code, "worker task event"),
    checkpoint: requireNullableSafeCode(event, "checkpoint", code, "worker task event"),
    error_code: requireNullableSafeCode(event, "error_code", code, "worker task event"),
    evidence_digest: requireNullableDigest(event, "evidence_digest", code, "worker task event"),
    occurred_at: requireCanonicalInstant(event, "occurred_at", code, "worker task event"),
  };
  validateTaskOutcome({
    status: normalized.status,
    checkpoint: normalized.checkpoint,
    errorCode: normalized.error_code,
    evidenceDigest: normalized.evidence_digest,
    lastSequence: normalized.sequence,
    code,
    label: "worker task event",
  });
  return normalized;
}

export function parseWorkerTaskEvent(rawOrObject) {
  return validateWorkerTaskEvent(parseTaskValue(
    rawOrObject,
    "invalid_worker_task_event",
    "worker task event",
  ));
}

export function taskEventSHA256(event) {
  const canonical = validateWorkerTaskEvent(event);
  return createHash("sha256").update(JSON.stringify(canonical), "utf8").digest("hex");
}

export function validateWorkerTaskEventReceipt(receipt, event) {
  const code = "invalid_worker_task_event_receipt";
  requireExactFields(receipt, TASK_EVENT_RECEIPT_FIELDS, code, "worker task event receipt");
  if (receipt.schema !== WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA) {
    fail(code, "worker task event receipt.schema is invalid");
  }
  const normalized = {
    schema: WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA,
    task_id: requireString(receipt, "task_id", ID_PATTERN, code, "worker task event receipt"),
    attempt: requirePositiveInteger(receipt, "attempt", code, "worker task event receipt"),
    lease_epoch: requirePositiveInteger(receipt, "lease_epoch", code, "worker task event receipt"),
    sequence: requirePositiveInteger(receipt, "sequence", code, "worker task event receipt"),
    disposition: requireString(receipt, "disposition", /^(?:accepted|idempotent)$/, code, "worker task event receipt"),
  };
  if (event !== undefined) {
    const expected = validateWorkerTaskEvent(event);
    if (normalized.task_id !== expected.task_id || normalized.attempt !== expected.attempt
      || normalized.lease_epoch !== expected.lease_epoch || normalized.sequence !== expected.sequence) {
      fail(code, "worker task event receipt does not match its event");
    }
  }
  return normalized;
}

export function parseWorkerTaskEventReceipt(rawOrObject, event) {
  return validateWorkerTaskEventReceipt(parseTaskValue(
    rawOrObject,
    "invalid_worker_task_event_receipt",
    "worker task event receipt",
  ), event);
}
