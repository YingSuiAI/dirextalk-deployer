import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  validateDeploymentReceipt,
} from "./deployment-contract.mjs";
import {
  WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
  WORKER_TASK_DOCUMENT_V1_SCHEMA,
  WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA,
  parseWorkerTaskClaim,
  parseWorkerTaskEvent,
  validateWorkerTaskDocument,
  validateWorkerTaskIssue,
  validateWorkerTaskSummary,
} from "./worker-task-contract.mjs";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;

function fail(code, message, statusCode = 400) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireString(value, field, pattern, code, statusCode = 409) {
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function knownStoreError(error, unavailableCode, unavailableMessage) {
  if (error instanceof ConnectionStackV2Error) return error;
  return new ConnectionStackV2Error(unavailableCode, unavailableMessage, 503);
}

async function readDeployment(deploymentStore, connectionId, deploymentId) {
  let receipt;
  try {
    receipt = await deploymentStore.getDeployment({
      connection_id: connectionId,
      deployment_id: deploymentId,
    });
  } catch (error) {
    throw knownStoreError(error, "deployment_store_unavailable", "deployment state storage is unavailable");
  }
  if (!receipt) fail("deployment_not_found", "deployment does not exist", 404);
  return validateDeploymentReceipt(receipt, {
    connectionId,
    deploymentId,
  });
}

function validateBootstrapReference(reference, requestSHA256) {
  if (!isRecord(reference)) {
    fail("worker_bootstrap_unavailable", "deployment has no Worker bootstrap session", 409);
  }
  if (reference.request_sha256 !== requestSHA256) {
    fail("worker_bootstrap_unavailable", "deployment Worker bootstrap request is invalid", 409);
  }
  return requireString(
    reference.bootstrap_session_id,
    "bootstrap_session_id",
    ID_PATTERN,
    "worker_bootstrap_unavailable",
    409,
  );
}

function validateBoundWorkerSession(session, {
  bootstrapSessionId,
  connectionId,
  deploymentId,
  requestSHA256,
  instanceId,
}) {
  if (!isRecord(session)
    || requireString(session.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN, "worker_bootstrap_unavailable") !== bootstrapSessionId
    || requireString(session.connection_id, "connection_id", ID_PATTERN, "worker_bootstrap_unavailable") !== connectionId
    || requireString(session.deployment_id, "deployment_id", ID_PATTERN, "worker_bootstrap_unavailable") !== deploymentId
    || requireString(session.request_sha256, "request_sha256", SHA256_PATTERN, "worker_bootstrap_unavailable") !== requestSHA256
    || requireString(session.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN, "worker_bootstrap_unavailable") !== instanceId
    || !new Set(["bound", "active"]).has(session.state)) {
    fail("worker_bootstrap_unavailable", "deployment Worker bootstrap session is not bound", 409);
  }
  return {
    bootstrap_session_id: bootstrapSessionId,
    expected_instance_id: instanceId,
  };
}

function validateAuthenticatedCommand(command, action) {
  if (!isRecord(command) || command.action !== action) {
    fail("worker_task_invalid", "authenticated Worker task command is invalid", 500);
  }
  return {
    connection_id: requireString(command.connection_id, "connection_id", ID_PATTERN, "worker_task_invalid", 500),
    request_sha256: requireString(command.request_sha256, "request_sha256", SHA256_PATTERN, "worker_task_invalid", 500),
    payload: command.payload,
  };
}

function validateAuthenticatedObserve(command) {
  const authenticated = validateAuthenticatedCommand(command, "worker.task.observe");
  const payload = authenticated.payload;
  if (!isRecord(payload) || Object.keys(payload).length !== 2) {
    fail("worker_task_invalid", "authenticated Worker task observe payload is invalid", 500);
  }
  return {
    connection_id: authenticated.connection_id,
    deployment_id: requireString(payload.deployment_id, "deployment_id", ID_PATTERN, "worker_task_invalid", 500),
    task_id: requireString(payload.task_id, "task_id", ID_PATTERN, "worker_task_invalid", 500),
  };
}

function taskDocument(task, { deploymentId } = {}) {
  if (!isRecord(task)) {
    fail("worker_task_store_invalid", "Worker task store returned no claimed task", 500);
  }
  return validateWorkerTaskDocument({
    schema: WORKER_TASK_DOCUMENT_V1_SCHEMA,
    ...task,
  }, { expectedDeploymentId: deploymentId });
}

function taskEventReceipt(event, disposition) {
  if (disposition !== "accepted" && disposition !== "idempotent") {
    fail("worker_task_store_invalid", "Worker task store returned an invalid event disposition", 500);
  }
  return {
    schema: WORKER_TASK_EVENT_RECEIPT_V1_SCHEMA,
    task_id: event.task_id,
    attempt: event.attempt,
    lease_epoch: event.lease_epoch,
    sequence: event.sequence,
    disposition,
  };
}

// WorkerTaskService keeps the task transport strictly downstream of both
// fences: a signed issue first resolves the immutable EC2 receipt plus its
// bound bootstrap session, while Worker delivery first reuses the active IID
// verified bearer gate. The task store never receives bearer material.
export class WorkerTaskService {
  constructor({
    deploymentStore,
    workerSessionStore,
    taskStore,
    sessionAuthorizer,
  }) {
    if (!deploymentStore || typeof deploymentStore.getDeployment !== "function" || typeof deploymentStore.getDeploymentBootstrap !== "function"
      || !workerSessionStore || typeof workerSessionStore.get !== "function"
      || !taskStore || typeof taskStore.ensure !== "function" || typeof taskStore.observe !== "function"
      || typeof taskStore.claim !== "function" || typeof taskStore.recordEvent !== "function"
      || !sessionAuthorizer || typeof sessionAuthorizer.authorize !== "function") {
      throw new TypeError("deployment, Worker session, task stores, and active-session authorizer are required");
    }
    this.deploymentStore = deploymentStore;
    this.workerSessionStore = workerSessionStore;
    this.taskStore = taskStore;
    this.sessionAuthorizer = sessionAuthorizer;
  }

  async issue(authenticatedCommand) {
    const authenticated = validateAuthenticatedCommand(authenticatedCommand, "worker.task.issue");
    const payload = validateWorkerTaskIssue(authenticated.payload, { code: "worker_task_invalid" });
    const receipt = await readDeployment(this.deploymentStore, authenticated.connection_id, payload.deployment_id);

    let bootstrap;
    try {
      bootstrap = await this.deploymentStore.getDeploymentBootstrap({
        connection_id: authenticated.connection_id,
        deployment_id: payload.deployment_id,
        request_sha256: receipt.request_sha256,
      });
    } catch (error) {
      throw knownStoreError(error, "deployment_store_unavailable", "deployment state storage is unavailable");
    }
    const bootstrapSessionId = validateBootstrapReference(bootstrap, receipt.request_sha256);

    let session;
    try {
      session = await this.workerSessionStore.get(bootstrapSessionId);
    } catch (error) {
      throw knownStoreError(error, "worker_session_unavailable", "Worker session storage is unavailable");
    }
    const binding = validateBoundWorkerSession(session, {
      bootstrapSessionId,
      connectionId: authenticated.connection_id,
      deploymentId: payload.deployment_id,
      requestSHA256: receipt.request_sha256,
      instanceId: receipt.instance_id,
    });

    let summary;
    try {
      summary = await this.taskStore.ensure({
        connection_id: authenticated.connection_id,
        deployment_id: payload.deployment_id,
        task_id: payload.task_id,
        task_kind: payload.task_kind,
        execution_manifest_digest: payload.execution_manifest_digest,
        input_digest: payload.input_digest,
        request_sha256: receipt.request_sha256,
        bootstrap_session_id: binding.bootstrap_session_id,
        expected_instance_id: binding.expected_instance_id,
      });
    } catch (error) {
      throw knownStoreError(error, "worker_task_unavailable", "Worker task storage is unavailable");
    }
    return validateWorkerTaskSummary(summary, {
      expectedTaskId: payload.task_id,
      expectedDeploymentId: payload.deployment_id,
    });
  }

  async observe(authenticatedCommand) {
    const command = validateAuthenticatedObserve(authenticatedCommand);
    let summary;
    try {
      summary = await this.taskStore.observe(command);
    } catch (error) {
      throw knownStoreError(error, "worker_task_unavailable", "Worker task storage is unavailable");
    }
    return validateWorkerTaskSummary(summary, {
      expectedTaskId: command.task_id,
      expectedDeploymentId: command.deployment_id,
    });
  }

  async claim(sessionId, authorization, rawClaim) {
    const claim = parseWorkerTaskClaim(rawClaim);
    const authorizationContext = await this.#authorize(sessionId, authorization, claim.lease_epoch);
    let task;
    try {
      task = await this.taskStore.claim({
        connection_id: authorizationContext.session.connection_id,
        deployment_id: authorizationContext.session.deployment_id,
        bootstrap_session_id: authorizationContext.session.bootstrap_session_id,
        expected_instance_id: authorizationContext.session.expected_instance_id,
        lease_epoch: claim.lease_epoch,
      });
    } catch (error) {
      throw knownStoreError(error, "worker_task_unavailable", "Worker task storage is unavailable");
    }
    if (task === undefined || task === null) {
      return {
        schema: WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
        status: "none",
        lease_epoch: claim.lease_epoch,
      };
    }
    return {
      schema: WORKER_TASK_CLAIM_RESPONSE_V1_SCHEMA,
      status: "claimed",
      lease_epoch: claim.lease_epoch,
      task: taskDocument(task, { deploymentId: authorizationContext.session.deployment_id }),
    };
  }

  async event(sessionId, authorization, taskId, rawEvent) {
    const event = parseWorkerTaskEvent(rawEvent);
    const pathTaskId = requireString(taskId, "task_id", ID_PATTERN, "worker_task_invalid");
    if (event.task_id !== pathTaskId) {
      fail("worker_task_invalid", "Worker task event path does not match the task", 409);
    }
    const authorizationContext = await this.#authorize(sessionId, authorization, event.lease_epoch);
    let recorded;
    try {
      recorded = await this.taskStore.recordEvent({
        connection_id: authorizationContext.session.connection_id,
        deployment_id: authorizationContext.session.deployment_id,
        bootstrap_session_id: authorizationContext.session.bootstrap_session_id,
        expected_instance_id: authorizationContext.session.expected_instance_id,
        event,
      });
    } catch (error) {
      throw knownStoreError(error, "worker_task_unavailable", "Worker task storage is unavailable");
    }
    return taskEventReceipt(event, recorded?.disposition);
  }

  async #authorize(sessionId, authorization, leaseEpoch) {
    try {
      const context = await this.sessionAuthorizer.authorize(sessionId, authorization, { leaseEpoch });
      if (!isRecord(context) || !isRecord(context.session) || context.session.lease_epoch !== leaseEpoch) {
        fail("worker_session_invalid", "active Worker session authorization is invalid", 500);
      }
      return context;
    } catch (error) {
      throw knownStoreError(error, "worker_session_unavailable", "Worker session authorization is unavailable");
    }
  }
}
