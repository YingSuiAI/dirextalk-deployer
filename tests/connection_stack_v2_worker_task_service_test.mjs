import assert from "node:assert/strict";

import {
  WorkerTaskService,
} from "../scripts/connection-stack-v2/src/worker-task-service.mjs";

const NOW = Date.parse("2026-07-15T08:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const DEPLOYMENT_ID = "deployment-v2-0001";
const SESSION_ID = "worker-session-v2-001";
const TASK_ID = "task-v2-execution-001";
const REQUEST_SHA256 = "a".repeat(64);
const DIGEST = (character) => `sha256:${character.repeat(64)}`;

function authenticated(action, payload) {
  return {
    action,
    connection_id: CONNECTION_ID,
    request_sha256: REQUEST_SHA256,
    payload,
  };
}

function issuePayload(overrides = {}) {
  return {
    schema: "dirextalk.worker-task-issue/v1",
    deployment_id: DEPLOYMENT_ID,
    task_id: TASK_ID,
    task_kind: "execution_probe",
    execution_manifest_digest: DIGEST("a"),
    input_digest: DIGEST("b"),
    ...overrides,
  };
}

function event(overrides = {}) {
  return {
    schema: "dirextalk.worker-task-event/v1",
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

const deploymentReceipt = {
  schema: "dirextalk.aws.deployment-receipt/v1",
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: REQUEST_SHA256,
  resource_status: "provisioning",
  instance_id: "i-0123456789abcdef0",
  volume_ids: ["vol-0123456789abcdef0"],
  network_interface_ids: ["eni-0123456789abcdef0"],
};
const bootstrap = {
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: REQUEST_SHA256,
  bootstrap_session_id: SESSION_ID,
};
const boundSession = {
  bootstrap_session_id: SESSION_ID,
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: REQUEST_SHA256,
  expected_instance_id: deploymentReceipt.instance_id,
  state: "bound",
  lease_epoch: 0,
  last_sequence: 0,
};

function summary(overrides = {}) {
  return {
    task_id: TASK_ID,
    deployment_id: DEPLOYMENT_ID,
    status: "queued",
    attempt: 1,
    last_sequence: 0,
    checkpoint: null,
    error_code: null,
    evidence_digest: null,
    updated_at: "2026-07-15T08:00:00.000Z",
    ...overrides,
  };
}

const calls = [];
const taskStore = {
  async ensure(input) {
    calls.push({ kind: "ensure", input: structuredClone(input) });
    return summary();
  },
  async observe(input) {
    calls.push({ kind: "observe", input: structuredClone(input) });
    return summary({ status: "running", last_sequence: 1, checkpoint: "execution_manifest_received", evidence_digest: DIGEST("a") });
  },
  async claim(input) {
    calls.push({ kind: "claim", input: structuredClone(input) });
    return {
      task_id: TASK_ID,
      deployment_id: DEPLOYMENT_ID,
      task_kind: "execution_probe",
      execution_manifest_digest: DIGEST("a"),
      input_digest: DIGEST("b"),
      attempt: 1,
      last_sequence: 0,
    };
  },
  async recordEvent(input) {
    calls.push({ kind: "event", input: structuredClone(input) });
    return { disposition: "accepted" };
  },
};
const authorizer = {
  async authorize(sessionId, authorization, { leaseEpoch }) {
    calls.push({ kind: "authorize", sessionId, authorization, leaseEpoch });
    if (sessionId !== SESSION_ID || authorization !== "Bearer worker-task-test-token" || leaseEpoch !== 1) {
      throw Object.assign(new Error("unauthorized"), { code: "worker_session_unauthorized" });
    }
    return {
      now_ms: NOW,
      token_sha256: "d".repeat(64),
      session: {
        ...boundSession,
        state: "active",
        lease_epoch: 1,
        lease_expires_at: "2026-07-15T08:05:00.000Z",
      },
    };
  },
};
const service = new WorkerTaskService({
  deploymentStore: {
    async getDeployment(input) {
      calls.push({ kind: "getDeployment", input: structuredClone(input) });
      return input.deployment_id === DEPLOYMENT_ID ? deploymentReceipt : undefined;
    },
    async getDeploymentBootstrap(input) {
      calls.push({ kind: "getDeploymentBootstrap", input: structuredClone(input) });
      return bootstrap;
    },
  },
  workerSessionStore: {
    async get(sessionId) {
      calls.push({ kind: "getSession", sessionId });
      return boundSession;
    },
  },
  taskStore,
  sessionAuthorizer: authorizer,
  nowMs: () => NOW,
});

const issued = await service.issue(authenticated("worker.task.issue", issuePayload()));
assert.deepEqual(issued, summary());
assert.deepEqual(calls.slice(0, 4), [
  { kind: "getDeployment", input: { connection_id: CONNECTION_ID, deployment_id: DEPLOYMENT_ID } },
  { kind: "getDeploymentBootstrap", input: { connection_id: CONNECTION_ID, deployment_id: DEPLOYMENT_ID, request_sha256: REQUEST_SHA256 } },
  { kind: "getSession", sessionId: SESSION_ID },
  {
    kind: "ensure",
    input: {
      connection_id: CONNECTION_ID,
      deployment_id: DEPLOYMENT_ID,
      task_id: TASK_ID,
      task_kind: "execution_probe",
      execution_manifest_digest: DIGEST("a"),
      input_digest: DIGEST("b"),
      request_sha256: REQUEST_SHA256,
      bootstrap_session_id: SESSION_ID,
      expected_instance_id: deploymentReceipt.instance_id,
    },
  },
], "a task is issued only after the durable EC2 receipt and bound bootstrap session agree");

const observed = await service.observe(authenticated("worker.task.observe", {
  deployment_id: DEPLOYMENT_ID,
  task_id: TASK_ID,
}));
assert.equal(observed.status, "running");
assert.deepEqual(calls.at(-1), {
  kind: "observe",
  input: { connection_id: CONNECTION_ID, deployment_id: DEPLOYMENT_ID, task_id: TASK_ID },
});

const claimed = await service.claim(SESSION_ID, "Bearer worker-task-test-token", {
  schema: "dirextalk.worker-task-claim/v1",
  lease_epoch: 1,
});
assert.deepEqual(claimed, {
  schema: "dirextalk.worker-task-claim-response/v1",
  status: "claimed",
  lease_epoch: 1,
  task: {
    schema: "dirextalk.worker-task/v1",
    task_id: TASK_ID,
    deployment_id: DEPLOYMENT_ID,
    task_kind: "execution_probe",
    execution_manifest_digest: DIGEST("a"),
    input_digest: DIGEST("b"),
    attempt: 1,
    last_sequence: 0,
  },
});
assert.deepEqual(calls.at(-1), {
  kind: "claim",
  input: {
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    expected_instance_id: deploymentReceipt.instance_id,
    lease_epoch: 1,
  },
}, "the task store never receives a bearer; it receives only the independently scoped active session binding");

const eventReceipt = await service.event(SESSION_ID, "Bearer worker-task-test-token", TASK_ID, event());
assert.deepEqual(eventReceipt, {
  schema: "dirextalk.worker-task-event-receipt/v1",
  task_id: TASK_ID,
  attempt: 1,
  lease_epoch: 1,
  sequence: 1,
  disposition: "accepted",
});
assert.equal(calls.at(-1).kind, "event");
assert.equal(calls.at(-1).input.event.status, "running");
assert.equal(calls.at(-1).input.token_sha256, undefined, "the task table must not become a second bearer-token store");

await assert.rejects(
  () => service.event(SESSION_ID, "Bearer worker-task-test-token", "task-v2-other-001", event()),
  (error) => error?.code === "worker_task_invalid",
  "an event path cannot be rebound to another task id",
);
await assert.rejects(
  () => service.issue(authenticated("worker.task.issue", issuePayload({ deployment_id: "deployment-v2-other" }))),
  (error) => error?.code === "deployment_not_found",
  "a signed task cannot be issued before a matching durable deployment receipt exists",
);

console.log("connection stack v2 worker task service boundary ok");
