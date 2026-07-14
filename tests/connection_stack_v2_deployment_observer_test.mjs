import assert from "node:assert/strict";

import {
  ConnectionStackV2Error,
} from "../scripts/connection-stack-v2/src/errors.mjs";
import {
  DeploymentWorkerBootstrapObserver,
  validateDeploymentObservation,
} from "../scripts/connection-stack-v2/src/deployment-observer.mjs";

const NOW = Date.parse("2026-07-15T02:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const DEPLOYMENT_ID = "deployment-v2-001";
const DEPLOYMENT_REQUEST_SHA256 = "a".repeat(64);
const BOOTSTRAP_SESSION_ID = "worker-session-v2-001";
const INSTANCE_ID = "i-0123456789abcdef0";

const receipt = {
  schema: "dirextalk.aws.deployment-receipt/v1",
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: DEPLOYMENT_REQUEST_SHA256,
  resource_status: "provisioning",
  instance_id: INSTANCE_ID,
  volume_ids: ["vol-0123456789abcdef0"],
  network_interface_ids: ["eni-0123456789abcdef0"],
};

const activeSession = {
  bootstrap_session_id: BOOTSTRAP_SESSION_ID,
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: DEPLOYMENT_REQUEST_SHA256,
  state: "active",
  expected_instance_id: INSTANCE_ID,
  lease_epoch: 4,
  lease_expires_at: "2026-07-15T02:05:00.000Z",
  last_sequence: 8,
  last_event_at: "2026-07-15T01:59:00.000Z",
  // The observer must never project private Worker material, even when a
  // storage adapter returns it as part of its validated internal record.
  token_sha256: "b".repeat(64),
  bootstrap_endpoint: "https://example.invalid/v2/worker-sessions",
  last_event_json: "{\"sensitive\":true}",
};

const command = {
  action: "deployment.observe",
  connection_id: CONNECTION_ID,
  request_sha256: "c".repeat(64),
  payload: { deployment_id: DEPLOYMENT_ID },
};

const calls = [];
const observer = new DeploymentWorkerBootstrapObserver({
  deploymentStore: {
    async getDeployment(input) {
      calls.push({ kind: "deployment", input });
      return receipt;
    },
    async getDeploymentBootstrap(input) {
      calls.push({ kind: "bootstrap", input });
      return {
        bootstrap_session_id: BOOTSTRAP_SESSION_ID,
        request_sha256: DEPLOYMENT_REQUEST_SHA256,
      };
    },
  },
  workerSessionStore: {
    async get(sessionID) {
      calls.push({ kind: "session", sessionID });
      return activeSession;
    },
    async claim() {
      throw new Error("deployment.observe must never claim a Worker");
    },
    async recordEvent() {
      throw new Error("deployment.observe must never write Worker events");
    },
  },
  nowMs: () => NOW,
});

const observation = await observer.observe(command);
assert.deepEqual(observation, {
  schema: "dirextalk.aws.deployment-observation/v1",
  deployment_id: DEPLOYMENT_ID,
  resource: {
    status: "provisioning",
    instance_id: INSTANCE_ID,
  },
  worker: {
    bootstrap_session_state: "active",
    lease_epoch: 4,
    lease_expires_at: "2026-07-15T02:05:00.000Z",
    last_sequence: 8,
    last_event_at: "2026-07-15T01:59:00.000Z",
  },
  observed_at: "2026-07-15T02:00:00.000Z",
});
assert.deepEqual(calls, [
  {
    kind: "deployment",
    input: { connection_id: CONNECTION_ID, deployment_id: DEPLOYMENT_ID },
  },
  {
    kind: "bootstrap",
    input: {
      connection_id: CONNECTION_ID,
      deployment_id: DEPLOYMENT_ID,
      request_sha256: DEPLOYMENT_REQUEST_SHA256,
    },
  },
  { kind: "session", sessionID: BOOTSTRAP_SESSION_ID },
]);
assert.doesNotMatch(
  JSON.stringify(observation),
  /bootstrap_session_id|token_sha256|bootstrap_endpoint|last_event_json|sensitive/,
  "observation must omit Worker capability and telemetry material",
);
assert.throws(
  () => validateDeploymentObservation({
    ...observation,
    worker: { ...observation.worker, last_event_at: undefined },
  }),
  (error) => error instanceof ConnectionStackV2Error && error.code === "deployment_observation_invalid",
  "public observation fields must use explicit JSON null rather than an omitted timestamp",
);
assert.throws(
  () => validateDeploymentObservation({
    ...observation,
    resource: { ...observation.resource, status: "active" },
  }),
  (error) => error instanceof ConnectionStackV2Error && error.code === "deployment_observation_invalid",
  "the first Worker bootstrap observation contract only accepts the provisioner receipt status",
);

const boundObserver = new DeploymentWorkerBootstrapObserver({
  deploymentStore: {
    async getDeployment() { return receipt; },
    async getDeploymentBootstrap() {
      return {
        bootstrap_session_id: BOOTSTRAP_SESSION_ID,
        request_sha256: DEPLOYMENT_REQUEST_SHA256,
      };
    },
  },
  workerSessionStore: {
    async get() {
      return {
        ...activeSession,
        state: "bound",
        lease_epoch: 0,
        lease_expires_at: undefined,
        last_sequence: 0,
        last_event_at: undefined,
      };
    },
  },
  nowMs: () => NOW,
});
assert.deepEqual((await boundObserver.observe(command)).worker, {
  bootstrap_session_state: "bound",
  lease_epoch: 0,
  lease_expires_at: null,
  last_sequence: 0,
  last_event_at: null,
}, "a bound Worker has no active lease or event but remains observable");

const unavailableBootstrapObserver = new DeploymentWorkerBootstrapObserver({
  deploymentStore: {
    async getDeployment() { return receipt; },
    async getDeploymentBootstrap() {
      throw new ConnectionStackV2Error("deployment_bootstrap_unavailable", "legacy deployment", 409);
    },
  },
  workerSessionStore: { async get() { throw new Error("must not read missing bootstrap"); } },
  nowMs: () => NOW,
});
await assert.rejects(
  () => unavailableBootstrapObserver.observe(command),
  (error) => error instanceof ConnectionStackV2Error && error.code === "worker_bootstrap_unavailable",
  "a legacy deployment without a Worker bootstrap fence cannot be reported as verified",
);

const mismatchedSessionObserver = new DeploymentWorkerBootstrapObserver({
  deploymentStore: {
    async getDeployment() { return receipt; },
    async getDeploymentBootstrap() {
      return {
        bootstrap_session_id: BOOTSTRAP_SESSION_ID,
        request_sha256: DEPLOYMENT_REQUEST_SHA256,
      };
    },
  },
  workerSessionStore: {
    async get() { return { ...activeSession, expected_instance_id: "i-0123456789abcdef1" }; },
  },
  nowMs: () => NOW,
});
await assert.rejects(
  () => mismatchedSessionObserver.observe(command),
  (error) => error instanceof ConnectionStackV2Error && error.code === "worker_session_invalid",
  "a Worker session may only evidence the instance recorded in the deployment receipt",
);

const expiredLeaseObserver = new DeploymentWorkerBootstrapObserver({
  deploymentStore: {
    async getDeployment() { return receipt; },
    async getDeploymentBootstrap() {
      return {
        bootstrap_session_id: BOOTSTRAP_SESSION_ID,
        request_sha256: DEPLOYMENT_REQUEST_SHA256,
      };
    },
  },
  workerSessionStore: {
    async get() { return { ...activeSession, lease_expires_at: "2026-07-15T01:59:59.999Z" }; },
  },
  nowMs: () => NOW,
});
await assert.rejects(
  () => expiredLeaseObserver.observe(command),
  (error) => error instanceof ConnectionStackV2Error && error.code === "worker_session_expired",
  "an active Worker must retain a future Stack-issued lease before it can be observed as active",
);

console.log("connection stack v2 deployment observer boundary ok");
