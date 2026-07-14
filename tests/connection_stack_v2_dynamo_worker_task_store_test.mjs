import assert from "node:assert/strict";

import {
  DynamoWorkerTaskStore,
} from "../scripts/connection-stack-v2/src/dynamo-worker-task-store.mjs";

class GetItemCommand {
  constructor(input) { this.input = input; }
}

class PutItemCommand {
  constructor(input) { this.input = input; }
}

class UpdateItemCommand {
  constructor(input) { this.input = input; }
}

class QueryCommand {
  constructor(input) { this.input = input; }
}

const NOW = Date.parse("2026-07-15T08:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const DEPLOYMENT_ID = "deployment-v2-0001";
const SESSION_ID = "worker-session-v2-001";
const TASK_ID = "task-v2-execution-001";
const REQUEST_SHA256 = "a".repeat(64);
const DIGEST = (character) => `sha256:${character.repeat(64)}`;

function conditionalFailure() {
  return Object.assign(new Error("conditional write failed"), { name: "ConditionalCheckFailedException" });
}

function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

function taskInput(overrides = {}) {
  return {
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    task_id: TASK_ID,
    task_kind: "execution_probe",
    execution_manifest_digest: DIGEST("a"),
    input_digest: DIGEST("b"),
    request_sha256: REQUEST_SHA256,
    bootstrap_session_id: SESSION_ID,
    expected_instance_id: "i-0123456789abcdef0",
    ...overrides,
  };
}

function event(sequence, overrides = {}) {
  return {
    schema: "dirextalk.worker-task-event/v1",
    task_id: TASK_ID,
    attempt: 1,
    lease_epoch: 1,
    sequence,
    status: "running",
    checkpoint: "execution_manifest_received",
    error_code: null,
    evidence_digest: DIGEST("a"),
    occurred_at: "2026-07-15T08:00:00.000Z",
    ...overrides,
  };
}

class TaskDynamo {
  constructor() {
    this.items = new Map();
    this.gets = [];
    this.puts = [];
    this.queries = [];
    this.updates = [];
  }

  key(deploymentId, taskId) {
    return `${deploymentId}\0${taskId}`;
  }

  async send(command) {
    if (command instanceof GetItemCommand) {
      this.gets.push(clone(command.input));
      const key = this.key(command.input.Key.deployment_id.S, command.input.Key.task_id.S);
      return { Item: clone(this.items.get(key)) };
    }
    if (command instanceof PutItemCommand) {
      this.puts.push(clone(command.input));
      const item = command.input.Item;
      const key = this.key(item.deployment_id.S, item.task_id.S);
      if (this.items.has(key)) throw conditionalFailure();
      this.items.set(key, clone(item));
      return {};
    }
    if (command instanceof QueryCommand) {
      this.queries.push(clone(command.input));
      const deploymentId = command.input.ExpressionAttributeValues[":deployment_id"].S;
      return {
        Items: [...this.items.values()]
          .filter((item) => item.deployment_id.S === deploymentId)
          .sort((left, right) => left.task_id.S.localeCompare(right.task_id.S))
          .map(clone),
      };
    }
    if (!(command instanceof UpdateItemCommand)) throw new Error("unexpected Dynamo command");
    this.updates.push(clone(command.input));
    const key = this.key(command.input.Key.deployment_id.S, command.input.Key.task_id.S);
    const item = this.items.get(key);
    if (!item) throw conditionalFailure();
    const values = command.input.ExpressionAttributeValues;
    if (command.input.UpdateExpression.includes("last_event_sha256")) {
      const allowsQueued = command.input.ConditionExpression.includes("#status = :queued");
      const allowsRunning = command.input.ConditionExpression.includes("#status = :running");
      if (item.connection_id.S !== values[":connection_id"].S
        || item.bootstrap_session_id.S !== values[":bootstrap_session_id"].S
        || item.expected_instance_id.S !== values[":expected_instance_id"].S
        || !((allowsQueued && item.status.S === values[":queued"].S)
          || (allowsRunning && item.status.S === values[":running"].S))
        || item.attempt.N !== values[":attempt"].N
        || item.lease_epoch.N !== values[":lease_epoch"].N
        || item.last_sequence.N !== values[":previous_sequence"].N
        || (command.input.ConditionExpression.includes("execution_manifest_digest = :evidence_digest")
          && item.execution_manifest_digest.S !== values[":evidence_digest"]?.S)) throw conditionalFailure();
      item.status = values[":event_status"];
      item.last_sequence = values[":sequence"];
      item.last_event_sha256 = values[":event_sha256"];
      item.updated_at = values[":now"];
      for (const field of ["checkpoint", "error_code", "evidence_digest"]) {
        if (values[`:${field}`] === undefined) delete item[field];
        else item[field] = values[`:${field}`];
      }
      return {};
    }
    if (item.connection_id.S !== values[":connection_id"].S
      || item.bootstrap_session_id.S !== values[":bootstrap_session_id"].S
      || item.expected_instance_id.S !== values[":expected_instance_id"].S
      || item.status.S !== values[":status"].S
      || item.attempt.N !== values[":attempt"].N
      || item.lease_epoch.N !== values[":previous_lease_epoch"].N) throw conditionalFailure();
    if (command.input.UpdateExpression.includes("attempt = attempt + :one")) {
      item.attempt = { N: String(Number(item.attempt.N) + 1) };
    }
    item.lease_epoch = values[":lease_epoch"];
    item.updated_at = values[":now"];
    return { Attributes: clone(item) };
  }
}

function store(client, nowMs = () => NOW) {
  return new DynamoWorkerTaskStore({
    client,
    workerTasksTableName: "worker-tasks",
    GetItemCommand,
    PutItemCommand,
    UpdateItemCommand,
    QueryCommand,
    nowMs,
  });
}

const client = new TaskDynamo();
let currentNow = NOW;
const tasks = store(client, () => currentNow);
const issued = await tasks.ensure(taskInput());
assert.deepEqual(issued, {
  task_id: TASK_ID,
  deployment_id: DEPLOYMENT_ID,
  status: "queued",
  attempt: 1,
  last_sequence: 0,
  checkpoint: null,
  error_code: null,
  evidence_digest: null,
  updated_at: "2026-07-15T08:00:00.000Z",
});
assert.equal(client.puts[0].ConditionExpression, "attribute_not_exists(deployment_id) AND attribute_not_exists(task_id)");
for (const field of ["access_token", "token_sha256", "worker_token", "secret_ref", "event_json", "last_event_json"]) {
  assert.equal(Object.hasOwn(client.puts[0].Item, field), false, `${field} must never enter the independent Worker task table`);
}

const firstClaim = await tasks.claim({
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  bootstrap_session_id: SESSION_ID,
  expected_instance_id: "i-0123456789abcdef0",
  lease_epoch: 1,
});
assert.deepEqual(firstClaim, {
  task_id: TASK_ID,
  deployment_id: DEPLOYMENT_ID,
  task_kind: "execution_probe",
  execution_manifest_digest: DIGEST("a"),
  input_digest: DIGEST("b"),
  attempt: 1,
  last_sequence: 0,
});
assert.equal(client.queries.at(-1).ConsistentRead, true, "task-id-free Worker claims use only a partitioned consistent Query");
assert.match(client.updates.at(-1).ConditionExpression, /lease_epoch = :previous_lease_epoch/);
assert.deepEqual(
  await tasks.claim({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    expected_instance_id: "i-0123456789abcdef0",
    lease_epoch: 1,
  }),
  firstClaim,
  "a repeated claim on the same active session epoch is an idempotent resume",
);

const eventBinding = {
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  bootstrap_session_id: SESSION_ID,
  expected_instance_id: "i-0123456789abcdef0",
};
await assert.rejects(
  () => tasks.recordEvent({ ...eventBinding, event: event(1, { evidence_digest: DIGEST("c") }) }),
  (error) => error?.code === "worker_task_event_conflict",
  "a probe event cannot substitute evidence for another execution manifest",
);
await assert.rejects(
  () => tasks.recordEvent({
    ...eventBinding,
    event: event(1, {
      status: "succeeded",
      checkpoint: "task_transport_verified",
      evidence_digest: DIGEST("a"),
    }),
  }),
  (error) => error?.code === "worker_task_event_conflict",
  "a probe cannot claim transport success before its fixed running receipt",
);
assert.deepEqual(await tasks.recordEvent({ ...eventBinding, event: event(1) }), { disposition: "accepted" });
assert.match(client.updates.at(-1).ConditionExpression, /last_sequence = :previous_sequence/);
assert.match(client.updates.at(-1).ConditionExpression, /execution_manifest_digest = :evidence_digest/);
assert.deepEqual(
  await tasks.recordEvent({ ...eventBinding, event: event(1) }),
  { disposition: "idempotent" },
  "the exact task event retry is safe after a response loss",
);
await assert.rejects(
  () => tasks.recordEvent({ ...eventBinding, event: event(1, { occurred_at: "2026-07-15T08:00:01.000Z" }) }),
  (error) => error?.code === "worker_task_event_conflict",
  "a repeated sequence with another body must fail rather than overwrite durable evidence",
);
await assert.rejects(
  () => tasks.recordEvent({ ...eventBinding, event: event(3) }),
  (error) => error?.code === "worker_task_event_conflict",
  "a sequence gap cannot skip Worker task progress",
);

currentNow += 5_000;
const reclaimed = await tasks.claim({
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  bootstrap_session_id: SESSION_ID,
  expected_instance_id: "i-0123456789abcdef0",
  lease_epoch: 2,
});
assert.equal(reclaimed.attempt, 2, "a new verified Worker lease creates a distinct resumable attempt");
assert.equal(reclaimed.last_sequence, 1, "a recovered Worker resumes from the durable task sequence");
await assert.rejects(
  () => tasks.recordEvent({ ...eventBinding, event: event(2) }),
  (error) => error?.code === "worker_task_unauthorized",
  "an old lease cannot write after the Worker reauthenticates",
);
assert.deepEqual(
  await tasks.recordEvent({
    ...eventBinding,
    event: event(2, {
      attempt: 2,
      lease_epoch: 2,
      sequence: 2,
      status: "succeeded",
      checkpoint: "task_transport_verified",
      evidence_digest: DIGEST("a"),
    }),
  }),
  { disposition: "accepted" },
);
assert.equal(
  await tasks.claim({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    expected_instance_id: "i-0123456789abcdef0",
    lease_epoch: 2,
  }),
  undefined,
  "terminal tasks are never redelivered",
);
const observed = await tasks.observe({
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  task_id: TASK_ID,
});
assert.deepEqual(observed, {
  task_id: TASK_ID,
  deployment_id: DEPLOYMENT_ID,
  status: "succeeded",
  attempt: 2,
  last_sequence: 2,
  checkpoint: "task_transport_verified",
  error_code: null,
  evidence_digest: DIGEST("a"),
  updated_at: "2026-07-15T08:00:05.000Z",
});
assert.deepEqual(await tasks.ensure(taskInput()), observed, "an exact signed issue replay retains current task progress");
await assert.rejects(
  () => tasks.ensure(taskInput({ execution_manifest_digest: DIGEST("f") })),
  (error) => error?.code === "worker_task_conflict",
  "a task id cannot be rebound to another execution manifest after its receipt fence commits",
);

console.log("connection stack v2 Dynamo Worker task store boundary ok");
