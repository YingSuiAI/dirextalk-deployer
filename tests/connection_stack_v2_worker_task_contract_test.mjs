import assert from "node:assert/strict";
import { createHash } from "node:crypto";

import {
  WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
  WORKER_TASK_CLAIM_V1_SCHEMA,
  WORKER_TASK_DOCUMENT_V1_SCHEMA,
  WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA,
  WORKER_TASK_EVENT_V1_SCHEMA,
  WORKER_TASK_ISSUE_V1_SCHEMA,
  parseWorkerTaskClaim,
  parseWorkerTaskClaimResponse,
  parseWorkerTaskEvent,
  parseWorkerTaskEventReceipt,
  parseWorkerTaskIssue,
  taskEventSHA256,
  validateWorkerTaskDocument,
  validateWorkerTaskSummary,
} from "../scripts/connection-stack-v2/src/worker-task-contract.mjs";

const DEPLOYMENT_ID = "deployment-v2-0001";
const TASK_ID = "task-v2-execution-001";
const DIGEST = (character) => `sha256:${character.repeat(64)}`;

function issue(overrides = {}) {
  return {
    schema: WORKER_TASK_ISSUE_V1_SCHEMA,
    deployment_id: DEPLOYMENT_ID,
    task_id: TASK_ID,
    task_kind: "execution_probe",
    execution_manifest_digest: DIGEST("a"),
    input_digest: DIGEST("b"),
    ...overrides,
  };
}

function taskDocument(overrides = {}) {
  return {
    schema: WORKER_TASK_DOCUMENT_V1_SCHEMA,
    task_id: TASK_ID,
    deployment_id: DEPLOYMENT_ID,
    task_kind: "execution_probe",
    execution_manifest_digest: DIGEST("a"),
    input_digest: DIGEST("b"),
    attempt: 1,
    last_sequence: 0,
    ...overrides,
  };
}

function event(overrides = {}) {
  return {
    schema: WORKER_TASK_EVENT_V1_SCHEMA,
    task_id: TASK_ID,
    attempt: 1,
    lease_epoch: 1,
    sequence: 1,
    status: "running",
    checkpoint: "execution_manifest_received",
    error_code: null,
    evidence_digest: DIGEST("a"),
    occurred_at: "2026-07-15T08:00:00.000Z",
    ...overrides,
  };
}

assert.deepEqual(parseWorkerTaskIssue(JSON.stringify(issue())), issue());
assert.deepEqual(parseWorkerTaskIssue(issue()), issue(), "handler-facing issue parsing accepts a decoded object");
for (const invalid of [
  issue({ task_kind: "shell" }),
  issue({ command: "curl https://example.invalid" }),
  issue({ execution_manifest_digest: "https://example.invalid/manifest" }),
]) {
  assert.throws(
    () => parseWorkerTaskIssue(JSON.stringify(invalid)),
    (error) => error?.code === "invalid_worker_task_issue",
    "the signed issue contract cannot carry a shell, URL, or non-digest artifact",
  );
}
assert.throws(
  () => parseWorkerTaskIssue(`{"schema":"${WORKER_TASK_ISSUE_V1_SCHEMA}","deployment_id":"${DEPLOYMENT_ID}","deployment_id":"shadow","task_id":"${TASK_ID}","task_kind":"execution_probe","execution_manifest_digest":"${DIGEST("a")}","input_digest":"${DIGEST("b")}"}`),
  (error) => error?.code === "invalid_worker_task_issue",
  "duplicate task JSON keys must fail before issue validation",
);

assert.deepEqual(parseWorkerTaskClaim({
  schema: WORKER_TASK_CLAIM_V1_SCHEMA,
  lease_epoch: 1,
}), {
  schema: WORKER_TASK_CLAIM_V1_SCHEMA,
  lease_epoch: 1,
});
assert.throws(
  () => parseWorkerTaskClaim({ schema: WORKER_TASK_CLAIM_V1_SCHEMA, lease_epoch: 1, task_id: TASK_ID }),
  (error) => error?.code === "invalid_worker_task_claim",
  "the active bearer route supplies task scope; claim cannot choose a task or session",
);

assert.deepEqual(validateWorkerTaskDocument(taskDocument()), taskDocument());
assert.throws(
  () => validateWorkerTaskDocument(taskDocument({ command: "forbidden" })),
  (error) => error?.code === "invalid_worker_task_document",
  "a claimed document must remain a digest-only execution probe",
);

const claimed = {
  schema: WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
  status: "claimed",
  lease_epoch: 1,
  task: taskDocument(),
};
assert.deepEqual(parseWorkerTaskClaimResponse(claimed), claimed);
assert.deepEqual(parseWorkerTaskClaimResponse({
  schema: WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
  status: "none",
  lease_epoch: 1,
}), {
  schema: WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
  status: "none",
  lease_epoch: 1,
});
assert.throws(
  () => parseWorkerTaskClaimResponse({ ...claimed, task: taskDocument({ last_sequence: -1 }) }),
  (error) => error?.code === "invalid_worker_task_claim_response",
  "a resume response must expose a nonnegative durable sequence only",
);

assert.deepEqual(parseWorkerTaskEvent(JSON.stringify(event())), event());
assert.equal(
  taskEventSHA256(event()),
  createHash("sha256").update(JSON.stringify(event()), "utf8").digest("hex"),
  "task event hashes bind the canonical strict event object",
);
for (const invalid of [
  event({ status: "running", checkpoint: null }),
  event({ status: "running", checkpoint: "probe_started" }),
  event({ status: "succeeded", evidence_digest: null }),
  event({ status: "succeeded", checkpoint: "probe_started" }),
  event({ status: "failed", checkpoint: "execution_manifest_received", error_code: "probe_failed", evidence_digest: DIGEST("d") }),
  event({ status: "interrupted", checkpoint: null, error_code: null, evidence_digest: null }),
  event({ raw_log: "forbidden" }),
]) {
  assert.throws(
    () => parseWorkerTaskEvent(JSON.stringify(invalid)),
    (error) => error?.code === "invalid_worker_task_event",
    "task events must be terminally typed metadata rather than free-form Worker output",
  );
}

const receipt = {
  schema: WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA,
  task_id: TASK_ID,
  attempt: 1,
  lease_epoch: 1,
  sequence: 1,
  disposition: "accepted",
};
assert.deepEqual(parseWorkerTaskEventReceipt(receipt, event()), receipt);

const queued = {
  task_id: TASK_ID,
  deployment_id: DEPLOYMENT_ID,
  status: "queued",
  attempt: 1,
  last_sequence: 0,
  checkpoint: null,
  error_code: null,
  evidence_digest: null,
  updated_at: "2026-07-15T08:00:00.000Z",
};
assert.deepEqual(validateWorkerTaskSummary(queued), queued);
assert.deepEqual(validateWorkerTaskSummary({
  ...queued,
  status: "running",
  last_sequence: 1,
  checkpoint: "execution_manifest_received",
  evidence_digest: DIGEST("e"),
}), {
  ...queued,
  status: "running",
  last_sequence: 1,
  checkpoint: "execution_manifest_received",
  evidence_digest: DIGEST("e"),
});
assert.deepEqual(validateWorkerTaskSummary({
  ...queued,
  status: "failed",
  last_sequence: 2,
  error_code: "probe_failed",
}), {
  ...queued,
  status: "failed",
  last_sequence: 2,
  error_code: "probe_failed",
});
assert.throws(
  () => validateWorkerTaskSummary({ ...queued, status: "succeeded", last_sequence: 1 }),
  (error) => error?.code === "invalid_worker_task_summary",
  "task summaries must not claim success without a bounded checkpoint and evidence digest",
);

console.log("connection stack v2 worker task contract boundary ok");
