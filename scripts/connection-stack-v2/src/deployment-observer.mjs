import {
  ConnectionStackV2Error,
  validateDeploymentReceipt,
} from "./deployment-contract.mjs";

export const DEPLOYMENT_OBSERVATION_V1_SCHEMA = "dirextalk.aws.deployment-observation/v1";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const WORKER_SESSION_STATES = new Set(["bound", "active"]);
const OBSERVABLE_RESOURCE_STATUS = "provisioning";

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireExactKeys(value, keys, code, label) {
  if (!isRecord(value) || Object.keys(value).length !== keys.length || keys.some((key) => !Object.hasOwn(value, key))) {
    fail(code, `${label} is invalid`, 500);
  }
}

function requireString(value, field, pattern, code = "deployment_observation_invalid", statusCode = 500) {
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requireNonnegativeInteger(value, field, code = "deployment_observation_invalid", statusCode = 500) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function canonicalInstant(value, field, code = "deployment_observation_invalid", statusCode = 500) {
  const instant = requireString(value, field, ISO_INSTANT_PATTERN, code, statusCode);
  const milliseconds = Date.parse(instant);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== instant) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return { instant, milliseconds };
}

function canonicalNow(nowMs) {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
    fail("deployment_observation_invalid", "clock is invalid", 500);
  }
  try {
    return canonicalInstant(new Date(nowMs).toISOString(), "clock").instant;
  } catch (error) {
    if (error instanceof ConnectionStackV2Error) throw error;
    fail("deployment_observation_invalid", "clock is invalid", 500);
  }
}

function validateAuthenticatedObserveCommand(command) {
  if (!isRecord(command) || command.action !== "deployment.observe") {
    fail("deployment_observation_invalid", "authenticated observe command is invalid", 500);
  }
  if (!isRecord(command.payload) || Object.keys(command.payload).length !== 1 || !Object.hasOwn(command.payload, "deployment_id")) {
    fail("deployment_observation_invalid", "authenticated observe payload is invalid", 500);
  }
  return {
    connection_id: requireString(command.connection_id, "connection_id", ID_PATTERN),
    request_sha256: requireString(command.request_sha256, "request_sha256", SHA256_PATTERN),
    deployment_id: requireString(command.payload.deployment_id, "deployment_id", ID_PATTERN),
  };
}

function nullableInstant(value, field, code = "deployment_observation_invalid", statusCode = 500) {
  if (value === undefined || value === null) return null;
  return canonicalInstant(value, field, code, statusCode).instant;
}

function nullableProjectionInstant(value, field) {
  if (value === null) return null;
  return canonicalInstant(value, field).instant;
}

function validateWorkerProjection(session, {
  bootstrapSessionId,
  connectionId,
  deploymentId,
  requestSHA256,
  instanceId,
  nowMs,
}) {
  if (!isRecord(session)) {
    fail("worker_bootstrap_unavailable", "Worker bootstrap session is unavailable", 409);
  }
  const state = requireString(session.state, "worker bootstrap state", /^(?:bound|active)$/, "worker_session_invalid");
  if (!WORKER_SESSION_STATES.has(state)) {
    fail("worker_session_invalid", "worker bootstrap state is invalid", 500);
  }
  if (requireString(session.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN, "worker_session_invalid") !== bootstrapSessionId
    || requireString(session.connection_id, "connection_id", ID_PATTERN, "worker_session_invalid") !== connectionId
    || requireString(session.deployment_id, "deployment_id", ID_PATTERN, "worker_session_invalid") !== deploymentId
    || requireString(session.request_sha256, "request_sha256", SHA256_PATTERN, "worker_session_invalid") !== requestSHA256
    || requireString(session.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN, "worker_session_invalid") !== instanceId) {
    fail("worker_session_invalid", "Worker bootstrap session does not match deployment evidence", 500);
  }
  const leaseEpoch = requireNonnegativeInteger(session.lease_epoch, "lease_epoch", "worker_session_invalid");
  const lastSequence = requireNonnegativeInteger(session.last_sequence, "last_sequence", "worker_session_invalid");
  const leaseExpiresAt = nullableInstant(session.lease_expires_at, "lease_expires_at", "worker_session_invalid");
  const lastEventAt = nullableInstant(session.last_event_at, "last_event_at", "worker_session_invalid");

  if (state === "bound") {
    if (leaseEpoch !== 0 || leaseExpiresAt !== null || lastSequence !== 0 || lastEventAt !== null) {
      fail("worker_session_invalid", "bound Worker bootstrap session has active lease state", 500);
    }
  } else {
    if (leaseEpoch < 1 || leaseExpiresAt === null
      || (lastSequence === 0 && lastEventAt !== null) || (lastSequence > 0 && lastEventAt === null)) {
      fail("worker_session_invalid", "active Worker bootstrap session is invalid", 500);
    }
    if (Date.parse(leaseExpiresAt) <= nowMs) {
      fail("worker_session_expired", "active Worker bootstrap lease has expired", 409);
    }
  }

  return {
    bootstrap_session_state: state,
    lease_epoch: leaseEpoch,
    lease_expires_at: leaseExpiresAt,
    last_sequence: lastSequence,
    last_event_at: lastEventAt,
  };
}

// validateDeploymentObservation is intentionally exact: the response is a
// private Broker-to-Orchestrator projection, not a Worker session or raw event
// export. Callers cannot accidentally extend it with an endpoint, session id,
// bearer hash, identity document, or telemetry body.
export function validateDeploymentObservation(observation, { nowMs } = {}) {
  requireExactKeys(observation, ["schema", "deployment_id", "resource", "worker", "observed_at"], "deployment_observation_invalid", "deployment observation");
  if (observation.schema !== DEPLOYMENT_OBSERVATION_V1_SCHEMA) {
    fail("deployment_observation_invalid", "deployment observation schema is invalid", 500);
  }
  const deploymentId = requireString(observation.deployment_id, "deployment_id", ID_PATTERN);
  requireExactKeys(observation.resource, ["status", "instance_id"], "deployment_observation_invalid", "deployment observation resource");
  const resource = {
    status: requireString(observation.resource.status, "resource.status", /^[a-z_]+$/),
    instance_id: requireString(observation.resource.instance_id, "resource.instance_id", INSTANCE_ID_PATTERN),
  };
  if (resource.status !== OBSERVABLE_RESOURCE_STATUS) {
    fail("deployment_observation_invalid", "resource.status is invalid", 500);
  }
  requireExactKeys(
    observation.worker,
    ["bootstrap_session_state", "lease_epoch", "lease_expires_at", "last_sequence", "last_event_at"],
    "deployment_observation_invalid",
    "deployment observation worker",
  );
  const state = requireString(
    observation.worker.bootstrap_session_state,
    "worker.bootstrap_session_state",
    /^(?:bound|active)$/,
  );
  const leaseEpoch = requireNonnegativeInteger(observation.worker.lease_epoch, "worker.lease_epoch");
  const leaseExpiresAt = nullableProjectionInstant(observation.worker.lease_expires_at, "worker.lease_expires_at");
  const lastSequence = requireNonnegativeInteger(observation.worker.last_sequence, "worker.last_sequence");
  const lastEventAt = nullableProjectionInstant(observation.worker.last_event_at, "worker.last_event_at");
  const observedAt = canonicalInstant(observation.observed_at, "observed_at").instant;
  if (state === "bound") {
    if (leaseEpoch !== 0 || leaseExpiresAt !== null || lastSequence !== 0 || lastEventAt !== null) {
      fail("deployment_observation_invalid", "bound Worker observation has active lease state", 500);
    }
  } else if (leaseEpoch < 1 || leaseExpiresAt === null
    || (lastSequence === 0 && lastEventAt !== null) || (lastSequence > 0 && lastEventAt === null)
    || (nowMs !== undefined && (!Number.isSafeInteger(nowMs) || nowMs < 0 || Date.parse(leaseExpiresAt) <= nowMs))) {
    fail("deployment_observation_invalid", "active Worker observation is invalid", 500);
  }
  return {
    schema: DEPLOYMENT_OBSERVATION_V1_SCHEMA,
    deployment_id: deploymentId,
    resource,
    worker: {
      bootstrap_session_state: state,
      lease_epoch: leaseEpoch,
      lease_expires_at: leaseExpiresAt,
      last_sequence: lastSequence,
      last_event_at: lastEventAt,
    },
    observed_at: observedAt,
  };
}

function knownStoreError(error, unavailableCode, unavailableMessage) {
  if (error instanceof ConnectionStackV2Error) {
    if (error.code === "deployment_bootstrap_unavailable") {
      return new ConnectionStackV2Error("worker_bootstrap_unavailable", "deployment has no Worker bootstrap session", 409);
    }
    return error;
  }
  return new ConnectionStackV2Error(unavailableCode, unavailableMessage, 503);
}

// DeploymentWorkerBootstrapObserver is read-only evidence composition. It
// reads the EC2 receipt first, then the receipt-bound Worker session, and does
// not expose or invoke either Worker bearer capability or provider mutation.
export class DeploymentWorkerBootstrapObserver {
  constructor({ deploymentStore, workerSessionStore, nowMs = Date.now }) {
    if (!deploymentStore || typeof deploymentStore.getDeployment !== "function" || typeof deploymentStore.getDeploymentBootstrap !== "function"
      || !workerSessionStore || typeof workerSessionStore.get !== "function" || typeof nowMs !== "function") {
      throw new TypeError("deployment and Worker session stores plus a clock are required");
    }
    this.deploymentStore = deploymentStore;
    this.workerSessionStore = workerSessionStore;
    this.nowMs = nowMs;
  }

  async observe(authenticatedCommand) {
    const command = validateAuthenticatedObserveCommand(authenticatedCommand);
    let receipt;
    try {
      receipt = await this.deploymentStore.getDeployment({
        connection_id: command.connection_id,
        deployment_id: command.deployment_id,
      });
    } catch (error) {
      throw knownStoreError(error, "deployment_store_unavailable", "deployment state storage is unavailable");
    }
    if (!receipt) {
      fail("deployment_not_found", "deployment does not exist", 404);
    }
    const normalizedReceipt = validateDeploymentReceipt(receipt, {
      connectionId: command.connection_id,
      deploymentId: command.deployment_id,
    });

    let bootstrap;
    try {
      bootstrap = await this.deploymentStore.getDeploymentBootstrap({
        connection_id: command.connection_id,
        deployment_id: command.deployment_id,
        request_sha256: normalizedReceipt.request_sha256,
      });
    } catch (error) {
      throw knownStoreError(error, "deployment_store_unavailable", "deployment state storage is unavailable");
    }
    if (!isRecord(bootstrap) || bootstrap.request_sha256 !== normalizedReceipt.request_sha256) {
      fail("worker_bootstrap_unavailable", "deployment has no Worker bootstrap session", 409);
    }
    const bootstrapSessionId = requireString(
      bootstrap.bootstrap_session_id,
      "bootstrap_session_id",
      ID_PATTERN,
      "worker_bootstrap_unavailable",
      409,
    );

    let session;
    try {
      session = await this.workerSessionStore.get(bootstrapSessionId);
    } catch (error) {
      throw knownStoreError(error, "worker_session_unavailable", "Worker session storage is unavailable");
    }
    const nowMs = this.nowMs();
    const observedAt = canonicalNow(nowMs);
    const worker = validateWorkerProjection(session, {
      bootstrapSessionId,
      connectionId: command.connection_id,
      deploymentId: command.deployment_id,
      requestSHA256: normalizedReceipt.request_sha256,
      instanceId: normalizedReceipt.instance_id,
      nowMs,
    });
    return validateDeploymentObservation({
      schema: DEPLOYMENT_OBSERVATION_V1_SCHEMA,
      deployment_id: normalizedReceipt.deployment_id,
      resource: {
        status: normalizedReceipt.resource_status,
        instance_id: normalizedReceipt.instance_id,
      },
      worker,
      observed_at: observedAt,
    }, { nowMs });
  }
}
