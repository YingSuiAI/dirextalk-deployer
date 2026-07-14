import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  taskEventSHA256,
  validateWorkerTaskEvent,
  validateWorkerTaskSummary,
} from "./worker-task-contract.mjs";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const TASK_STATUSES = new Set(["queued", "running", "succeeded", "failed", "interrupted"]);
const CLAIMABLE_STATUSES = new Set(["queued", "running"]);
const TERMINAL_STATUSES = new Set(["succeeded", "failed", "interrupted"]);
const CLAIM_RETRY_LIMIT = 4;

const STORED_TASK_BASE_FIELDS = new Set([
  "deployment_id",
  "task_id",
  "connection_id",
  "request_sha256",
  "bootstrap_session_id",
  "expected_instance_id",
  "task_kind",
  "execution_manifest_digest",
  "input_digest",
  "status",
  "attempt",
  "lease_epoch",
  "last_sequence",
  "created_at",
  "updated_at",
]);
const STORED_TASK_OPTIONAL_FIELDS = new Set([
  "checkpoint",
  "error_code",
  "evidence_digest",
  "last_event_sha256",
]);

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireString(value, field, pattern, code = "worker_task_store_invalid", statusCode = 500) {
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requirePositiveInteger(value, field, code = "worker_task_store_invalid", statusCode = 500) {
  if (!Number.isSafeInteger(value) || value < 1) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requireNonnegativeInteger(value, field, code = "worker_task_store_invalid", statusCode = 500) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function parseCanonicalInstant(value, field, code = "worker_task_store_invalid", statusCode = 500) {
  requireString(value, field, ISO_INSTANT_PATTERN, code, statusCode);
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function conditionalFailure(error) {
  return error?.name === "ConditionalCheckFailedException";
}

function taskKey(deploymentId, taskId) {
  return {
    deployment_id: { S: deploymentId },
    task_id: { S: taskId },
  };
}

function storedString(item, field, pattern) {
  return requireString(item?.[field]?.S, field, pattern);
}

function storedOptionalString(item, field, pattern) {
  if (item?.[field] === undefined) return null;
  return storedString(item, field, pattern);
}

function storedNonnegativeInteger(item, field) {
  const value = item?.[field]?.N;
  if (typeof value !== "string" || !/^(?:0|[1-9]\d*)$/.test(value)) {
    fail("worker_task_store_invalid", `${field} is invalid`, 500);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || String(parsed) !== value) {
    fail("worker_task_store_invalid", `${field} is invalid`, 500);
  }
  return parsed;
}

function storedPositiveInteger(item, field) {
  const value = storedNonnegativeInteger(item, field);
  if (value < 1) fail("worker_task_store_invalid", `${field} is invalid`, 500);
  return value;
}

function storedInstant(item, field) {
  return parseCanonicalInstant(storedString(item, field, ISO_INSTANT_PATTERN), field);
}

function hasForbiddenSecretField(item) {
  return item?.access_token !== undefined
    || item?.token_sha256 !== undefined
    || item?.worker_token !== undefined
    || item?.secret_ref !== undefined
    || item?.event_json !== undefined
    || item?.last_event_json !== undefined;
}

function taskSummary(task) {
  return {
    task_id: task.task_id,
    deployment_id: task.deployment_id,
    status: task.status,
    attempt: task.attempt,
    last_sequence: task.last_sequence,
    checkpoint: task.checkpoint,
    error_code: task.error_code,
    evidence_digest: task.evidence_digest,
    updated_at: task.updated_at,
  };
}

function taskDocument(task) {
  return {
    task_id: task.task_id,
    deployment_id: task.deployment_id,
    task_kind: task.task_kind,
    execution_manifest_digest: task.execution_manifest_digest,
    input_digest: task.input_digest,
    attempt: task.attempt,
    last_sequence: task.last_sequence,
  };
}

function parseStoredTask(item, { deploymentId, taskId } = {}) {
  if (!isRecord(item) || hasForbiddenSecretField(item)) {
    fail("worker_task_store_invalid", "stored Worker task is invalid", 500);
  }
  for (const field of Object.keys(item)) {
    if (!STORED_TASK_BASE_FIELDS.has(field) && !STORED_TASK_OPTIONAL_FIELDS.has(field)) {
      fail("worker_task_store_invalid", "stored Worker task has an unexpected field", 500);
    }
  }
  for (const field of STORED_TASK_BASE_FIELDS) {
    if (!Object.hasOwn(item, field)) {
      fail("worker_task_store_invalid", `stored Worker task.${field} is required`, 500);
    }
  }
  const task = {
    deployment_id: storedString(item, "deployment_id", ID_PATTERN),
    task_id: storedString(item, "task_id", ID_PATTERN),
    connection_id: storedString(item, "connection_id", ID_PATTERN),
    request_sha256: storedString(item, "request_sha256", SHA256_PATTERN),
    bootstrap_session_id: storedString(item, "bootstrap_session_id", ID_PATTERN),
    expected_instance_id: storedString(item, "expected_instance_id", INSTANCE_ID_PATTERN),
    task_kind: storedString(item, "task_kind", /^execution_probe$/),
    execution_manifest_digest: storedString(item, "execution_manifest_digest", NAMED_SHA256_PATTERN),
    input_digest: storedString(item, "input_digest", NAMED_SHA256_PATTERN),
    status: storedString(item, "status", /^(?:queued|running|succeeded|failed|interrupted)$/),
    attempt: storedPositiveInteger(item, "attempt"),
    lease_epoch: storedNonnegativeInteger(item, "lease_epoch"),
    last_sequence: storedNonnegativeInteger(item, "last_sequence"),
    checkpoint: storedOptionalString(item, "checkpoint", /^[a-z][a-z0-9_]{0,95}$/),
    error_code: storedOptionalString(item, "error_code", /^[a-z][a-z0-9_]{0,95}$/),
    evidence_digest: storedOptionalString(item, "evidence_digest", NAMED_SHA256_PATTERN),
    last_event_sha256: storedOptionalString(item, "last_event_sha256", SHA256_PATTERN),
    created_at: storedInstant(item, "created_at"),
    updated_at: storedInstant(item, "updated_at"),
  };
  if (!TASK_STATUSES.has(task.status) || (task.last_sequence === 0 && task.last_event_sha256 !== null)
    || (task.last_sequence > 0 && task.last_event_sha256 === null)) {
    fail("worker_task_store_invalid", "stored Worker task event state is invalid", 500);
  }
  try {
    validateWorkerTaskSummary(taskSummary(task), {
      expectedTaskId: taskId,
      expectedDeploymentId: deploymentId,
    });
  } catch (error) {
    if (error instanceof ConnectionStackV2Error) {
      fail("worker_task_store_invalid", "stored Worker task summary is invalid", 500);
    }
    throw error;
  }
  if (deploymentId !== undefined && task.deployment_id !== deploymentId) {
    fail("worker_task_store_invalid", "stored Worker task deployment key is invalid", 500);
  }
  if (taskId !== undefined && task.task_id !== taskId) {
    fail("worker_task_store_invalid", "stored Worker task key is invalid", 500);
  }
  return task;
}

function validateEnsureInput(input) {
  if (!isRecord(input)) fail("worker_task_invalid", "Worker task issue is invalid", 500);
  const normalized = {
    connection_id: requireString(input.connection_id, "connection_id", ID_PATTERN, "worker_task_invalid", 500),
    deployment_id: requireString(input.deployment_id, "deployment_id", ID_PATTERN, "worker_task_invalid", 500),
    task_id: requireString(input.task_id, "task_id", ID_PATTERN, "worker_task_invalid", 500),
    task_kind: requireString(input.task_kind, "task_kind", /^execution_probe$/, "worker_task_invalid", 500),
    execution_manifest_digest: requireString(input.execution_manifest_digest, "execution_manifest_digest", NAMED_SHA256_PATTERN, "worker_task_invalid", 500),
    input_digest: requireString(input.input_digest, "input_digest", NAMED_SHA256_PATTERN, "worker_task_invalid", 500),
    request_sha256: requireString(input.request_sha256, "request_sha256", SHA256_PATTERN, "worker_task_invalid", 500),
    bootstrap_session_id: requireString(input.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN, "worker_task_invalid", 500),
    expected_instance_id: requireString(input.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN, "worker_task_invalid", 500),
  };
  if (Object.keys(input).length !== Object.keys(normalized).length) {
    fail("worker_task_invalid", "Worker task issue has an unexpected field", 500);
  }
  return normalized;
}

function validateObserveInput(input) {
  if (!isRecord(input)) fail("worker_task_invalid", "Worker task observation is invalid", 500);
  const normalized = {
    connection_id: requireString(input.connection_id, "connection_id", ID_PATTERN, "worker_task_invalid", 500),
    deployment_id: requireString(input.deployment_id, "deployment_id", ID_PATTERN, "worker_task_invalid", 500),
    task_id: requireString(input.task_id, "task_id", ID_PATTERN, "worker_task_invalid", 500),
  };
  if (Object.keys(input).length !== Object.keys(normalized).length) {
    fail("worker_task_invalid", "Worker task observation has an unexpected field", 500);
  }
  return normalized;
}

function validateClaimInput(input) {
  if (!isRecord(input)) fail("worker_task_invalid", "Worker task claim is invalid", 500);
  const normalized = {
    connection_id: requireString(input.connection_id, "connection_id", ID_PATTERN, "worker_task_invalid", 500),
    deployment_id: requireString(input.deployment_id, "deployment_id", ID_PATTERN, "worker_task_invalid", 500),
    bootstrap_session_id: requireString(input.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN, "worker_task_invalid", 500),
    expected_instance_id: requireString(input.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN, "worker_task_invalid", 500),
    lease_epoch: requirePositiveInteger(input.lease_epoch, "lease_epoch", "worker_task_invalid", 500),
  };
  if (Object.keys(input).length !== Object.keys(normalized).length) {
    fail("worker_task_invalid", "Worker task claim has an unexpected field", 500);
  }
  return normalized;
}

function validateEventInput(input) {
  if (!isRecord(input)) fail("worker_task_invalid", "Worker task event is invalid", 500);
  const required = ["connection_id", "deployment_id", "bootstrap_session_id", "expected_instance_id", "event"];
  if (Object.keys(input).length !== required.length || required.some((field) => !Object.hasOwn(input, field))) {
    fail("worker_task_invalid", "Worker task event has an unexpected field", 500);
  }
  return {
    connection_id: requireString(input.connection_id, "connection_id", ID_PATTERN, "worker_task_invalid", 500),
    deployment_id: requireString(input.deployment_id, "deployment_id", ID_PATTERN, "worker_task_invalid", 500),
    bootstrap_session_id: requireString(input.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN, "worker_task_invalid", 500),
    expected_instance_id: requireString(input.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN, "worker_task_invalid", 500),
    event: validateWorkerTaskEvent(input.event),
  };
}

function sameTaskBinding(task, input) {
  return task.connection_id === input.connection_id
    && task.deployment_id === input.deployment_id
    && task.task_id === input.task_id
    && task.task_kind === input.task_kind
    && task.execution_manifest_digest === input.execution_manifest_digest
    && task.input_digest === input.input_digest
    && task.request_sha256 === input.request_sha256
    && task.bootstrap_session_id === input.bootstrap_session_id
    && task.expected_instance_id === input.expected_instance_id;
}

function sameWorkerBinding(task, input) {
  return task.connection_id === input.connection_id
    && task.deployment_id === input.deployment_id
    && task.bootstrap_session_id === input.bootstrap_session_id
    && task.expected_instance_id === input.expected_instance_id;
}

function taskNow(nowMs) {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
    fail("worker_task_store_invalid", "clock is invalid", 500);
  }
  return parseCanonicalInstant(new Date(nowMs).toISOString(), "clock");
}

function taskItem(input, now) {
  return {
    deployment_id: { S: input.deployment_id },
    task_id: { S: input.task_id },
    connection_id: { S: input.connection_id },
    request_sha256: { S: input.request_sha256 },
    bootstrap_session_id: { S: input.bootstrap_session_id },
    expected_instance_id: { S: input.expected_instance_id },
    task_kind: { S: input.task_kind },
    execution_manifest_digest: { S: input.execution_manifest_digest },
    input_digest: { S: input.input_digest },
    status: { S: "queued" },
    attempt: { N: "1" },
    lease_epoch: { N: "0" },
    last_sequence: { N: "0" },
    created_at: { S: now },
    updated_at: { S: now },
  };
}

// DynamoWorkerTaskStore deliberately owns only digest-pinned task metadata.
// It never stores a Worker bearer, raw Worker event/log, or arbitrary task
// body. A partitioned Query is the minimum read primitive needed because the
// active Worker claim is intentionally task-id-free.
export class DynamoWorkerTaskStore {
  constructor({
    client,
    workerTasksTableName,
    GetItemCommand,
    PutItemCommand,
    UpdateItemCommand,
    QueryCommand,
    nowMs,
  }) {
    if (!client?.send || typeof workerTasksTableName !== "string" || workerTasksTableName.length === 0
      || !GetItemCommand || !PutItemCommand || !UpdateItemCommand || !QueryCommand || typeof nowMs !== "function") {
      throw new TypeError("DynamoDB client, Worker task table, commands, and clock are required");
    }
    this.client = client;
    this.workerTasksTableName = workerTasksTableName;
    this.GetItemCommand = GetItemCommand;
    this.PutItemCommand = PutItemCommand;
    this.UpdateItemCommand = UpdateItemCommand;
    this.QueryCommand = QueryCommand;
    this.nowMs = nowMs;
  }

  async ensure(input) {
    const normalized = validateEnsureInput(input);
    const now = taskNow(this.nowMs());
    try {
      await this.client.send(new this.PutItemCommand({
        TableName: this.workerTasksTableName,
        Item: taskItem(normalized, now),
        ConditionExpression: "attribute_not_exists(deployment_id) AND attribute_not_exists(task_id)",
      }));
      return taskSummary(parseStoredTask(taskItem(normalized, now), {
        deploymentId: normalized.deployment_id,
        taskId: normalized.task_id,
      }));
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("worker_task_unavailable", "Worker task storage is unavailable", 503);
      }
    }
    const existing = await this.#read(normalized.deployment_id, normalized.task_id);
    if (!existing) fail("worker_task_unavailable", "Worker task storage could not reconcile its conditional write", 503);
    if (!sameTaskBinding(existing, normalized)) {
      fail("worker_task_conflict", "task id is already bound to another immutable execution probe", 409);
    }
    return taskSummary(existing);
  }

  async observe(input) {
    const normalized = validateObserveInput(input);
    const task = await this.#read(normalized.deployment_id, normalized.task_id);
    if (!task) fail("worker_task_not_found", "Worker task does not exist", 404);
    if (task.connection_id !== normalized.connection_id) {
      fail("worker_task_not_found", "Worker task does not exist", 404);
    }
    return taskSummary(task);
  }

  async claim(input) {
    const normalized = validateClaimInput(input);
    for (let attempt = 0; attempt < CLAIM_RETRY_LIMIT; attempt += 1) {
      const candidates = await this.#claimableTasks(normalized.deployment_id);
      const task = candidates.find((candidate) => CLAIMABLE_STATUSES.has(candidate.status));
      if (!task) return undefined;
      if (!sameWorkerBinding(task, normalized)) {
        fail("worker_task_unauthorized", "Worker task does not bind this active Worker", 401);
      }
      if (task.lease_epoch > normalized.lease_epoch) {
        fail("worker_task_unauthorized", "Worker task is leased by a newer Worker session", 401);
      }
      if (task.lease_epoch === normalized.lease_epoch) {
        return taskDocument(task);
      }
      try {
        return taskDocument(await this.#advanceClaim(task, normalized));
      } catch (error) {
        if (!conditionalFailure(error)) throw error;
      }
    }
    fail("worker_task_unavailable", "Worker task claim could not reconcile its conditional write", 503);
  }

  async recordEvent(input) {
    const normalized = validateEventInput(input);
    const { event } = normalized;
    const now = taskNow(this.nowMs());
    const previousSequence = event.sequence - 1;
    const eventSHA256 = taskEventSHA256(event);
    const stateCondition = event.status === "running"
      ? "#status = :queued"
      : event.status === "succeeded"
        ? "#status = :running"
        : "(#status = :queued OR #status = :running)";
    const digestCondition = event.status === "running" || event.status === "succeeded"
      ? " AND execution_manifest_digest = :evidence_digest"
      : "";
    const updateParts = [
      "#status = :event_status",
      "last_sequence = :sequence",
      "last_event_sha256 = :event_sha256",
      "updated_at = :now",
    ];
    const removeParts = [];
    const values = {
      ":connection_id": { S: normalized.connection_id },
      ":bootstrap_session_id": { S: normalized.bootstrap_session_id },
      ":expected_instance_id": { S: normalized.expected_instance_id },
      ":queued": { S: "queued" },
      ":running": { S: "running" },
      ":attempt": { N: String(event.attempt) },
      ":lease_epoch": { N: String(event.lease_epoch) },
      ":previous_sequence": { N: String(previousSequence) },
      ":sequence": { N: String(event.sequence) },
      ":event_status": { S: event.status },
      ":event_sha256": { S: eventSHA256 },
      ":now": { S: now },
    };
    for (const [field, value] of [
      ["checkpoint", event.checkpoint],
      ["error_code", event.error_code],
      ["evidence_digest", event.evidence_digest],
    ]) {
      if (value === null) {
        removeParts.push(field);
      } else {
        updateParts.push(`${field} = :${field}`);
        values[`:${field}`] = { S: value };
      }
    }
    try {
      await this.client.send(new this.UpdateItemCommand({
        TableName: this.workerTasksTableName,
        Key: taskKey(normalized.deployment_id, event.task_id),
        ConditionExpression: `connection_id = :connection_id AND bootstrap_session_id = :bootstrap_session_id AND expected_instance_id = :expected_instance_id AND ${stateCondition} AND attempt = :attempt AND lease_epoch = :lease_epoch AND last_sequence = :previous_sequence${digestCondition}`,
        UpdateExpression: `SET ${updateParts.join(", ")}${removeParts.length > 0 ? ` REMOVE ${removeParts.join(", ")}` : ""}`,
        ExpressionAttributeNames: { "#status": "status" },
        ExpressionAttributeValues: values,
      }));
      return { disposition: "accepted" };
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("worker_task_unavailable", "Worker task storage is unavailable", 503);
      }
    }
    const existing = await this.#read(normalized.deployment_id, event.task_id);
    if (!existing) fail("worker_task_unavailable", "Worker task storage could not reconcile its conditional write", 503);
    if (!sameWorkerBinding(existing, normalized) || existing.attempt !== event.attempt || existing.lease_epoch !== event.lease_epoch) {
      fail("worker_task_unauthorized", "Worker task event does not bind the active Worker lease", 401);
    }
    if (existing.last_sequence === event.sequence && existing.last_event_sha256 === eventSHA256) {
      return { disposition: "idempotent" };
    }
    fail("worker_task_event_conflict", "Worker task event sequence is not the next durable event", 409);
  }

  async #advanceClaim(task, input) {
    const now = taskNow(this.nowMs());
    const firstLease = task.lease_epoch === 0;
    const updateExpression = firstLease
      ? "SET lease_epoch = :lease_epoch, updated_at = :now"
      : "SET attempt = attempt + :one, lease_epoch = :lease_epoch, updated_at = :now";
    const output = await this.client.send(new this.UpdateItemCommand({
      TableName: this.workerTasksTableName,
      Key: taskKey(task.deployment_id, task.task_id),
      ConditionExpression: "connection_id = :connection_id AND bootstrap_session_id = :bootstrap_session_id AND expected_instance_id = :expected_instance_id AND #status = :status AND attempt = :attempt AND lease_epoch = :previous_lease_epoch",
      UpdateExpression: updateExpression,
      ExpressionAttributeNames: { "#status": "status" },
      ExpressionAttributeValues: {
        ":connection_id": { S: input.connection_id },
        ":bootstrap_session_id": { S: input.bootstrap_session_id },
        ":expected_instance_id": { S: input.expected_instance_id },
        ":status": { S: task.status },
        ":attempt": { N: String(task.attempt) },
        ":previous_lease_epoch": { N: String(task.lease_epoch) },
        ":lease_epoch": { N: String(input.lease_epoch) },
        ":one": { N: "1" },
        ":now": { S: now },
      },
      ReturnValues: "ALL_NEW",
    }));
    return parseStoredTask(output?.Attributes, {
      deploymentId: task.deployment_id,
      taskId: task.task_id,
    });
  }

  async #claimableTasks(deploymentId) {
    let exclusiveStartKey;
    const tasks = [];
    do {
      let output;
      try {
        output = await this.client.send(new this.QueryCommand({
          TableName: this.workerTasksTableName,
          ConsistentRead: true,
          KeyConditionExpression: "deployment_id = :deployment_id",
          ExpressionAttributeValues: {
            ":deployment_id": { S: deploymentId },
          },
          ...(exclusiveStartKey ? { ExclusiveStartKey: exclusiveStartKey } : {}),
        }));
      } catch {
        fail("worker_task_unavailable", "Worker task storage is unavailable", 503);
      }
      if (output?.Items !== undefined && !Array.isArray(output.Items)) {
        fail("worker_task_store_invalid", "Worker task query response is invalid", 500);
      }
      for (const item of output?.Items ?? []) {
        tasks.push(parseStoredTask(item, { deploymentId }));
      }
      exclusiveStartKey = output?.LastEvaluatedKey;
      if (exclusiveStartKey !== undefined && !isRecord(exclusiveStartKey)) {
        fail("worker_task_store_invalid", "Worker task query cursor is invalid", 500);
      }
    } while (exclusiveStartKey !== undefined);
    return tasks.sort((left, right) => left.task_id.localeCompare(right.task_id));
  }

  async #read(deploymentId, taskId) {
    let output;
    try {
      output = await this.client.send(new this.GetItemCommand({
        TableName: this.workerTasksTableName,
        ConsistentRead: true,
        Key: taskKey(deploymentId, taskId),
      }));
    } catch {
      fail("worker_task_unavailable", "Worker task storage is unavailable", 503);
    }
    if (!output?.Item) return undefined;
    return parseStoredTask(output.Item, { deploymentId, taskId });
  }
}
