import assert from "node:assert/strict";
import { createHash } from "node:crypto";

import {
  ConnectionStackV2Error,
  WORKER_EVENT_RECEIPT_V1_SCHEMA,
  WORKER_EVENT_V1_SCHEMA,
  WORKER_SESSION_CLAIM_RESPONSE_V1_SCHEMA,
  WORKER_SESSION_CLAIM_V1_SCHEMA,
  parseStrictJSONObject,
  parseWorkerEvent,
  parseWorkerEventReceipt,
  parseWorkerSessionClaim,
  parseWorkerSessionClaimResponse,
  parseWorkerSessionEvent,
  validateWorkerEventReceipt,
  workerEventSHA256,
  workerSessionEventSHA256,
} from "../scripts/connection-stack-v2/src/worker-session-contract.mjs";

const NOW = Date.parse("2026-07-15T07:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const DEPLOYMENT_ID = "deployment-v2-0001";
const SESSION_ID = "worker-session-v2-01";
const DIGEST = (character) => `sha256:${character.repeat(64)}`;
const IDENTITY_DOCUMENT = Buffer.from("instance-identity-document", "utf8").toString("base64");
const IDENTITY_SIGNATURE = Buffer.from("instance-identity-signature", "utf8").toString("base64");

function validClaim(overrides = {}) {
  return {
    schema: WORKER_SESSION_CLAIM_V1_SCHEMA,
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    worker_image_digest: DIGEST("a"),
    artifact_manifest_digest: DIGEST("b"),
    instance_identity_document_b64: IDENTITY_DOCUMENT,
    instance_identity_signature_b64: IDENTITY_SIGNATURE,
    ...overrides,
  };
}

function validEvent(overrides = {}) {
  return {
    schema: WORKER_EVENT_V1_SCHEMA,
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    lease_epoch: 1,
    sequence: 1,
    kind: "heartbeat",
    occurred_at: "2026-07-15T07:00:00.000Z",
    ...overrides,
  };
}

function validReceipt(overrides = {}) {
  return {
    schema: WORKER_EVENT_RECEIPT_V1_SCHEMA,
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    lease_epoch: 1,
    sequence: 1,
    disposition: "accepted",
    ...overrides,
  };
}

const claim = parseWorkerSessionClaim(JSON.stringify(validClaim()));
assert.deepEqual(claim, validClaim(), "the claim contract must preserve the Go wire fields exactly");
assert.deepEqual(parseWorkerSessionClaim(validClaim()), validClaim(), "the handler-facing claim parser accepts an already decoded object");
assert.throws(
  () => parseStrictJSONObject('{"instanceId":"i-01","instanceId":"i-02"}'),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_session_payload",
  "the shared strict parser must also protect IID document consumers from duplicate keys",
);

assert.throws(
  () => parseWorkerSessionClaim(`{"schema":"${WORKER_SESSION_CLAIM_V1_SCHEMA}","connection_id":"${CONNECTION_ID}","connection_id":"${CONNECTION_ID}","deployment_id":"${DEPLOYMENT_ID}","bootstrap_session_id":"${SESSION_ID}","worker_image_digest":"${DIGEST("a")}","artifact_manifest_digest":"${DIGEST("b")}","instance_identity_document_b64":"${IDENTITY_DOCUMENT}","instance_identity_signature_b64":"${IDENTITY_SIGNATURE}"}`),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_session_claim",
  "a claim cannot hide a duplicated identity binding behind JSON duplicate-key semantics",
);
assert.throws(
  () => parseWorkerSessionClaim(JSON.stringify(validClaim({ aws_session_token: "forbidden" }))),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_session_claim",
  "a claim must reject credential-shaped extensions",
);
assert.throws(
  () => parseWorkerSessionClaim(JSON.stringify(validClaim({ instance_identity_document_b64: "YQ" }))),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_session_claim",
  "identity material must use canonical padded base64",
);

const heartbeat = parseWorkerEvent(JSON.stringify(validEvent({ checkpoint: "" })));
assert.deepEqual(heartbeat, validEvent(), "empty optional fields must normalize to the same worker event semantics");
assert.deepEqual(parseWorkerSessionEvent(validEvent()), validEvent(), "the handler-facing event parser accepts an already decoded object");
assert.equal(
  workerEventSHA256(heartbeat),
  workerEventSHA256({
    occurred_at: "2026-07-15T07:00:00.000Z",
    kind: "heartbeat",
    sequence: 1,
    lease_epoch: 1,
    bootstrap_session_id: SESSION_ID,
    deployment_id: DEPLOYMENT_ID,
    connection_id: CONNECTION_ID,
    schema: WORKER_EVENT_V1_SCHEMA,
  }),
  "the event hash must bind semantics, not inbound JSON field order or omitted empty fields",
);
assert.equal(workerSessionEventSHA256(heartbeat), workerEventSHA256(heartbeat));
assert.equal(
  workerEventSHA256(heartbeat),
  createHash("sha256").update(JSON.stringify(heartbeat), "utf8").digest("hex"),
  "event hashing must be stable and inspectable from the canonical event object",
);

assert.deepEqual(
  parseWorkerEvent(JSON.stringify(validEvent({
    kind: "checkpoint",
    checkpoint: "artifact_verified",
    evidence_digest: DIGEST("c"),
  }))),
  validEvent({
    kind: "checkpoint",
    checkpoint: "artifact_verified",
    evidence_digest: DIGEST("c"),
  }),
  "checkpoint events may carry only their bounded checkpoint and evidence digest",
);
assert.deepEqual(
  parseWorkerEvent(JSON.stringify(validEvent({
    kind: "report",
    report_status: "failed",
    error_code: "artifact_fetch_failed",
    evidence_digest: DIGEST("d"),
  }))),
  validEvent({
    kind: "report",
    report_status: "failed",
    error_code: "artifact_fetch_failed",
    evidence_digest: DIGEST("d"),
  }),
  "failed reports must remain bounded to a status, safe code, and evidence digest",
);
for (const invalidEvent of [
  validEvent({ sequence: 0 }),
  validEvent({ lease_epoch: Number.MAX_SAFE_INTEGER + 1 }),
  validEvent({ occurred_at: "2026-07-15T07:00:00Z" }),
  validEvent({ raw_worker_log: "forbidden" }),
  validEvent({ kind: "heartbeat", evidence_digest: DIGEST("e") }),
  validEvent({ kind: "report", report_status: "failed" }),
  validEvent({ kind: "report", report_status: "succeeded", error_code: "unexpected_error" }),
  validEvent({ kind: "checkpoint", checkpoint: "https://logs.example.invalid" }),
]) {
  assert.throws(
    () => parseWorkerEvent(JSON.stringify(invalidEvent)),
    (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_event",
    "worker events must reject unsafe counters, noncanonical instants, and log/URL-like extensions",
  );
}

const receipt = parseWorkerEventReceipt(JSON.stringify(validReceipt()));
assert.deepEqual(validateWorkerEventReceipt(receipt, heartbeat), validReceipt());
assert.throws(
  () => validateWorkerEventReceipt(validReceipt({ sequence: 2 }), heartbeat),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_event_receipt",
  "an event receipt must acknowledge the exact pending epoch and sequence",
);

const claimResponse = parseWorkerSessionClaimResponse(JSON.stringify({
  schema: WORKER_SESSION_CLAIM_RESPONSE_V1_SCHEMA,
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  bootstrap_session_id: SESSION_ID,
  lease_epoch: 1,
  lease_expires_at: "2026-07-15T07:05:00.000Z",
  access_token: "short-lived-worker-token-0123456789",
}), {
  expectedConnectionId: CONNECTION_ID,
  expectedDeploymentId: DEPLOYMENT_ID,
  expectedBootstrapSessionId: SESSION_ID,
  nowMs: NOW,
});
assert.equal(claimResponse.lease_epoch, 1);
assert.throws(
  () => parseWorkerSessionClaimResponse(JSON.stringify({
    ...claimResponse,
    lease_expires_at: "2026-07-15T07:11:00.000Z",
  }), {
    expectedConnectionId: CONNECTION_ID,
    expectedDeploymentId: DEPLOYMENT_ID,
    expectedBootstrapSessionId: SESSION_ID,
    nowMs: NOW,
  }),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_session_claim_response",
  "a claim response cannot issue a lease longer than the Worker protocol allows",
);

console.log("connection stack v2 worker session contract ok");
