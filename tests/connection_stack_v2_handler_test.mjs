import assert from "node:assert/strict";

import {
  ConnectionStackV2Error,
} from "../scripts/connection-stack-v2/src/command-contract.mjs";
import {
  createV2BrokerHandler,
} from "../scripts/connection-stack-v2/src/handler.mjs";

const command = {
  schema: "dirextalk.aws.command/v2",
  command_id: "command-v2-00001",
};
const receipt = {
  schema: "dirextalk.aws.command-receipt/v2",
  disposition: "committed",
  command_id: "command-v2-00001",
};
const challenge = {
  schema: "dirextalk.aws.approval-challenge/v2",
  challenge_id: "challenge-v2-001",
};
const quote = {
  schema: "dirextalk.aws.quote/v1",
  quote_id: "quote-v2-00001",
  currency: "USD",
  candidates: [{ instance_type: "t3.large", hourly_minor: 5 }],
};
const registration = {
  schema: "dirextalk.aws.connection-registration/v1",
  bootstrap_id: "bootstrap-v2-0001",
  connection_id: "connection-v2-0001",
  account_id: "123456789012",
  region: "ap-south-1",
  broker_command_url: "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands",
  node_key_id: "node-key-v2",
  connection_generation: 3,
  worker_artifact: { kind: "fixed_ami", ami_id: "ami-0123456789abcdef0" },
  worker_network: {
    vpc_id: "vpc-0123456789abcdef0",
    subnet_id: "subnet-0123456789abcdef0",
    availability_zone: "ap-south-1a",
  },
  worker_resource_manifest_digest: `sha256:${"b".repeat(64)}`,
  stack_arn: "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef",
  command_id: "command-v2-00001",
  request_sha256: "a".repeat(64),
};

const accepted = [];
const handler = createV2BrokerHandler({
  async accept(received) {
    accepted.push(received);
    return { status: "challenge_issued", receipt, challenge };
  },
});
const response = await handler({ body: JSON.stringify(command) });
assert.equal(response.statusCode, 201);
assert.deepEqual(accepted, [command]);
assert.deepEqual(JSON.parse(response.body), {
  status: "challenge_issued",
  receipt,
  challenge,
});
assert.doesNotMatch(response.body, /payload_b64|signature_b64|approval_binding/);

const quoteHandler = createV2BrokerHandler({
  async accept() {
    return { status: "quote_issued", receipt, quote, command };
  },
});
const quoteResponse = await quoteHandler({ body: JSON.stringify(command) });
assert.equal(quoteResponse.statusCode, 200);
assert.deepEqual(JSON.parse(quoteResponse.body), {
  status: "quote_issued",
  receipt,
  quote,
});
assert.doesNotMatch(quoteResponse.body, /payload_b64|signature_b64|approval_binding/);

const registrationReceipt = {
  ...receipt,
  action: "connection.registration.verify",
  registration,
};
const registrationHandler = createV2BrokerHandler({
  async accept() {
    return { status: "connection_registered", receipt: registrationReceipt, registration, command };
  },
});
const registrationResponse = await registrationHandler({ body: JSON.stringify(command) });
assert.equal(registrationResponse.statusCode, 200);
assert.deepEqual(JSON.parse(registrationResponse.body), {
  status: "connection_registered",
  receipt: {
    schema: "dirextalk.aws.command-receipt/v2",
    disposition: "committed",
    command_id: "command-v2-00001",
    action: "connection.registration.verify",
  },
  registration,
});
assert.doesNotMatch(registrationResponse.body, /payload_b64|signature_b64|approval_binding|node_public_key|device_approval/);

const runtimeContexts = [];
const stackDerivedEndpointHandler = createV2BrokerHandler({
  async accept(_received, runtimeContext) {
    runtimeContexts.push(runtimeContext);
    return { status: "quote_issued", receipt, quote };
  },
}, {
  registrationConfig: {
    account_id: "123456789012",
    region: "ap-south-1",
    stack_arn: "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef",
    api_gateway_url_suffix: "amazonaws.com",
    stage_name: "prod",
    worker_artifact: { kind: "fixed_ami", ami_id: "ami-0123456789abcdef0" },
    worker_network: {
      vpc_id: "vpc-0123456789abcdef0",
      subnet_id: "subnet-0123456789abcdef0",
      availability_zone: "ap-south-1a",
    },
    worker_resource_manifest_digest: `sha256:${"b".repeat(64)}`,
  },
});
const stackDerivedEndpointResponse = await stackDerivedEndpointHandler({
  body: JSON.stringify(command),
  requestContext: {
    domainName: "abcde12345.execute-api.ap-south-1.amazonaws.com",
    stage: "prod",
  },
});
assert.equal(stackDerivedEndpointResponse.statusCode, 200);
assert.deepEqual(runtimeContexts, [{
  broker_command_url: "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands",
}], "the Lambda must derive the Broker endpoint from its own API Gateway event, not command payload claims");

const deployment = {
  schema: "dirextalk.aws.deployment-receipt/v1",
  connection_id: "connection-v2-0001",
  deployment_id: "deployment-v2-001",
  request_sha256: "a".repeat(64),
  resource_status: "provisioning",
  instance_id: "i-0123456789abcdef0",
  volume_ids: ["vol-0123456789abcdef0"],
  network_interface_ids: ["eni-0123456789abcdef0"],
};
const runtimeDeploymentCalls = [];
const runtimeDeploymentHandler = createV2BrokerHandler({
  async accept() {
    return {
      status: "approval_consumed",
      receipt,
      command: { action: "deployment.create", request_sha256: deployment.request_sha256 },
    };
  },
}, {
  registrationConfig: {
    account_id: "123456789012",
    region: "ap-south-1",
    stack_arn: "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef",
    api_gateway_url_suffix: "amazonaws.com",
    stage_name: "prod",
    worker_artifact: { kind: "fixed_ami", ami_id: "ami-0123456789abcdef0" },
    worker_network: {
      vpc_id: "vpc-0123456789abcdef0",
      subnet_id: "subnet-0123456789abcdef0",
      availability_zone: "ap-south-1a",
    },
    worker_resource_manifest_digest: `sha256:${"b".repeat(64)}`,
  },
  deploymentProvisioner: {
    async ensure(commandToProvision, options) {
      runtimeDeploymentCalls.push({ commandToProvision, options });
      return deployment;
    },
  },
});
const runtimeDeploymentResponse = await runtimeDeploymentHandler({
  path: "/prod/v2/commands",
  httpMethod: "POST",
  body: JSON.stringify(command),
  requestContext: {
    domainName: "abcde12345.execute-api.ap-south-1.amazonaws.com",
    stage: "prod",
  },
});
assert.equal(runtimeDeploymentResponse.statusCode, 202);
assert.deepEqual(runtimeDeploymentCalls, [{
  commandToProvision: { action: "deployment.create", request_sha256: deployment.request_sha256 },
  options: {
    workerBootstrapEndpoint: "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/worker-sessions",
  },
}], "the Stack generates the Worker callback endpoint from its own API Gateway event, never from a signed command");
const provisionedCommands = [];
const deploymentHandler = createV2BrokerHandler({
  async accept() {
    return {
      status: "approval_consumed",
      receipt,
      command: { action: "deployment.create", request_sha256: deployment.request_sha256 },
    };
  },
}, {
  deploymentProvisioner: {
    async ensure(commandToProvision) {
      provisionedCommands.push(commandToProvision);
      return deployment;
    },
  },
});
const deploymentResponse = await deploymentHandler({ body: JSON.stringify(command) });
assert.equal(deploymentResponse.statusCode, 202);
assert.deepEqual(JSON.parse(deploymentResponse.body), {
  status: "deployment_created",
  receipt,
  deployment,
});
assert.equal(provisionedCommands.length, 1, "only the typed deployment command reaches the EC2 provisioner");
assert.doesNotMatch(deploymentResponse.body, /user_data|worker_token|secret_ref|approval_proof/);

let rejectedDeploymentProvisionerCalls = 0;
const deploymentConflictHandler = createV2BrokerHandler({
  async accept() {
    throw new ConnectionStackV2Error("deployment_id_conflict", "deployment id is already reserved", 409);
  },
}, {
  deploymentProvisioner: {
    async ensure() {
      rejectedDeploymentProvisionerCalls += 1;
      return deployment;
    },
  },
});
const deploymentConflictResponse = await deploymentConflictHandler({ body: JSON.stringify(command) });
assert.equal(deploymentConflictResponse.statusCode, 409);
assert.deepEqual(JSON.parse(deploymentConflictResponse.body), { error: { code: "deployment_id_conflict" } });
assert.equal(rejectedDeploymentProvisionerCalls, 0, "a deployment-id reservation conflict must be rejected before any EC2 provider call");

const replayDeploymentHandler = createV2BrokerHandler({
  async accept() {
    return {
      status: "idempotent",
      receipt: { ...receipt, disposition: "idempotent" },
      command: { action: "deployment.create", request_sha256: deployment.request_sha256 },
    };
  },
}, {
  deploymentProvisioner: {
    async ensure() { return deployment; },
  },
});
const replayDeploymentResponse = await replayDeploymentHandler({ body: JSON.stringify(command) });
assert.equal(replayDeploymentResponse.statusCode, 200, "an expired/replayed command must still reconcile the EC2 receipt without a second approval");
assert.equal(JSON.parse(replayDeploymentResponse.body).status, "idempotent");

const deploymentObservation = {
  schema: "dirextalk.aws.deployment-observation/v1",
  deployment_id: deployment.deployment_id,
  resource: {
    status: "provisioning",
    instance_id: deployment.instance_id,
  },
  worker: {
    bootstrap_session_state: "active",
    lease_epoch: 1,
    lease_expires_at: "2026-07-15T01:05:00.000Z",
    last_sequence: 0,
    last_event_at: null,
  },
  observed_at: "2026-07-15T01:00:00.000Z",
};
const observeCommand = {
  action: "deployment.observe",
  connection_id: deployment.connection_id,
  request_sha256: "c".repeat(64),
  payload: { deployment_id: deployment.deployment_id },
};
const observedCommands = [];
let observerProvisionerCalls = 0;
const observeHandler = createV2BrokerHandler({
  async accept() {
    return {
      status: "read_only_validated",
      receipt: { ...receipt, action: "deployment.observe" },
      command: observeCommand,
    };
  },
}, {
  deploymentObserver: {
    async observe(commandToObserve) {
      observedCommands.push(commandToObserve);
      return deploymentObservation;
    },
  },
  deploymentProvisioner: {
    async ensure() {
      observerProvisionerCalls += 1;
      throw new Error("deployment.observe must not provision or mutate EC2");
    },
  },
});
const observeResponse = await observeHandler({ body: JSON.stringify(command) });
assert.equal(observeResponse.statusCode, 200);
assert.deepEqual(JSON.parse(observeResponse.body), {
  status: "deployment_observed",
  receipt: { ...receipt, action: "deployment.observe" },
  observation: deploymentObservation,
});
assert.deepEqual(observedCommands, [observeCommand], "the signed observe command reaches only the read-only observer after receipt acceptance");
assert.equal(observerProvisionerCalls, 0, "deployment.observe must not reach the EC2 provisioner");
assert.doesNotMatch(observeResponse.body, /bootstrap_session_id|access_token|token_sha256|bootstrap_endpoint|last_event_json/);

const replayObserveHandler = createV2BrokerHandler({
  async accept() {
    return {
      status: "idempotent",
      receipt: { ...receipt, action: "deployment.observe", disposition: "idempotent" },
      command: observeCommand,
    };
  },
}, {
  deploymentObserver: {
    async observe() { return deploymentObservation; },
  },
});
const replayObserveResponse = await replayObserveHandler({ body: JSON.stringify(command) });
assert.equal(replayObserveResponse.statusCode, 200, "an expired signed observe replay must return fresh read-only evidence");
assert.deepEqual(JSON.parse(replayObserveResponse.body), {
  status: "idempotent",
  receipt: { ...receipt, action: "deployment.observe", disposition: "idempotent" },
  observation: deploymentObservation,
});

const denied = createV2BrokerHandler({
  async accept() {
    throw new ConnectionStackV2Error("invalid_node_signature", "internal detail must not leave the broker", 401);
  },
});
const deniedResponse = await denied({ body: JSON.stringify(command) });
assert.equal(deniedResponse.statusCode, 401);
assert.deepEqual(JSON.parse(deniedResponse.body), { error: { code: "invalid_node_signature" } });
assert.doesNotMatch(deniedResponse.body, /internal detail/);

const invalidResponse = await handler({ body: "not-json" });
assert.equal(invalidResponse.statusCode, 400);
assert.deepEqual(JSON.parse(invalidResponse.body), { error: { code: "invalid_request" } });

const workerSessionID = "worker-session-v2-001";
const workerClaim = {
  schema: "dirextalk.worker-session-claim/v1",
  connection_id: "connection-v2-0001",
  deployment_id: "deployment-v2-001",
  bootstrap_session_id: workerSessionID,
  worker_image_digest: `sha256:${"e".repeat(64)}`,
  artifact_manifest_digest: `sha256:${"f".repeat(64)}`,
  instance_identity_document_b64: "e30=",
  instance_identity_signature_b64: "AA==",
};
const workerEvent = {
  schema: "dirextalk.worker-event/v1",
  connection_id: workerClaim.connection_id,
  deployment_id: workerClaim.deployment_id,
  bootstrap_session_id: workerSessionID,
  lease_epoch: 1,
  sequence: 1,
  kind: "progress",
  occurred_at: "2026-07-15T01:00:00.000Z",
  report_status: "installing",
};
const workerClaimResponse = {
  schema: "dirextalk.worker-session-claim-response/v1",
  connection_id: workerClaim.connection_id,
  deployment_id: workerClaim.deployment_id,
  bootstrap_session_id: workerSessionID,
  lease_epoch: 1,
  lease_expires_at: "2026-07-15T01:05:00.000Z",
  access_token: "worker-session-test-token-123456",
};
const workerEventReceipt = {
  schema: "dirextalk.worker-event-receipt/v1",
  connection_id: workerEvent.connection_id,
  deployment_id: workerEvent.deployment_id,
  bootstrap_session_id: workerSessionID,
  lease_epoch: 1,
  sequence: 1,
  disposition: "accepted",
};
const workerSessionCalls = [];
let workerRouteCommandCalls = 0;
const workerRouteHandler = createV2BrokerHandler({
  async accept() {
    workerRouteCommandCalls += 1;
    throw new Error("Worker session routes must not reach signed command acceptance");
  },
}, {
  workerSessionService: {
    async claim(sessionId, receivedClaim) {
      workerSessionCalls.push({ kind: "claim", sessionId, receivedClaim });
      return workerClaimResponse;
    },
    async event(sessionId, authorization, receivedEvent) {
      workerSessionCalls.push({ kind: "event", sessionId, authorization, receivedEvent });
      return workerEventReceipt;
    },
  },
});

const workerClaimRouteResponse = await workerRouteHandler({
  path: `/v2/worker-sessions/${workerSessionID}/claim`,
  httpMethod: "POST",
  body: JSON.stringify(workerClaim),
});
assert.equal(workerClaimRouteResponse.statusCode, 200);
assert.deepEqual(JSON.parse(workerClaimRouteResponse.body), workerClaimResponse);
assert.deepEqual(workerSessionCalls, [{ kind: "claim", sessionId: workerSessionID, receivedClaim: workerClaim }]);
assert.equal(workerRouteCommandCalls, 0, "an unauthenticated Worker claim must never reach signed command acceptance");

const stagedWorkerClaimRouteResponse = await workerRouteHandler({
  path: `/prod/v2/worker-sessions/${workerSessionID}/claim`,
  httpMethod: "POST",
  requestContext: { stage: "prod" },
  body: JSON.stringify(workerClaim),
});
assert.equal(stagedWorkerClaimRouteResponse.statusCode, 200);
assert.deepEqual(workerSessionCalls.at(-1), { kind: "claim", sessionId: workerSessionID, receivedClaim: workerClaim });

const workerEventRouteResponse = await workerRouteHandler({
  rawPath: `/v2/worker-sessions/${workerSessionID}/events`,
  requestContext: { http: { method: "POST" } },
  headers: { Authorization: `Bearer ${workerClaimResponse.access_token}` },
  body: JSON.stringify(workerEvent),
});
assert.equal(workerEventRouteResponse.statusCode, 200);
assert.deepEqual(JSON.parse(workerEventRouteResponse.body), workerEventReceipt);
assert.deepEqual(workerSessionCalls.at(-1), {
  kind: "event",
  sessionId: workerSessionID,
  authorization: `Bearer ${workerClaimResponse.access_token}`,
  receivedEvent: workerEvent,
});
assert.doesNotMatch(workerEventRouteResponse.body, /worker-session-test-token/, "event responses must not echo the bearer token");

const duplicateKeyResponse = await workerRouteHandler({
  path: `/v2/worker-sessions/${workerSessionID}/claim`,
  httpMethod: "POST",
  body: '{"schema":"dirextalk.worker-session-claim/v1","schema":"shadow"}',
});
assert.equal(duplicateKeyResponse.statusCode, 400);
assert.deepEqual(JSON.parse(duplicateKeyResponse.body), { error: { code: "invalid_request" } });
assert.equal(workerSessionCalls.length, 3, "duplicate-key JSON must be rejected before the Worker session service");

const missingWorkerServiceCommandCalls = [];
const missingWorkerServiceHandler = createV2BrokerHandler({
  async accept(received) {
    missingWorkerServiceCommandCalls.push(received);
    return { status: "challenge_issued", receipt, challenge };
  },
});
const missingWorkerServiceResponse = await missingWorkerServiceHandler({
  path: `/v2/worker-sessions/${workerSessionID}/claim`,
  httpMethod: "POST",
  body: JSON.stringify(workerClaim),
});
assert.equal(missingWorkerServiceResponse.statusCode, 503);
assert.deepEqual(JSON.parse(missingWorkerServiceResponse.body), { error: { code: "worker_session_unavailable" } });
assert.deepEqual(missingWorkerServiceCommandCalls, [], "a disabled Worker session service must fail closed instead of treating a claim as a command");

const unknownPathResponse = await workerRouteHandler({
  path: "/v2/worker-sessions/not-a-session/unknown",
  httpMethod: "POST",
  body: JSON.stringify(workerClaim),
});
assert.equal(unknownPathResponse.statusCode, 404);
assert.deepEqual(JSON.parse(unknownPathResponse.body), { error: { code: "not_found" } });
assert.equal(workerRouteCommandCalls, 0, "an unknown path must not reach signed command acceptance");

const wrongMethodResponse = await workerRouteHandler({
  path: `/v2/worker-sessions/${workerSessionID}/claim`,
  httpMethod: "GET",
  body: JSON.stringify(workerClaim),
});
assert.equal(wrongMethodResponse.statusCode, 404);
assert.deepEqual(JSON.parse(wrongMethodResponse.body), { error: { code: "not_found" } });

const explicitCommandRouteResponse = await handler({
  path: "/v2/commands",
  httpMethod: "POST",
  body: JSON.stringify(command),
});
assert.equal(explicitCommandRouteResponse.statusCode, 201);
assert.equal(accepted.length, 2, "the explicit command path must keep its existing signed-command behavior");

const duplicateCommandResponse = await handler({
  path: "/v2/commands",
  httpMethod: "POST",
  body: '{"schema":"dirextalk.aws.command/v2","schema":"shadow"}',
});
assert.equal(duplicateCommandResponse.statusCode, 400);
assert.deepEqual(JSON.parse(duplicateCommandResponse.body), { error: { code: "invalid_request" } });
assert.equal(accepted.length, 2, "strict JSON parsing must reject duplicate keys before signed command acceptance");

console.log("connection stack v2 broker handler boundary ok");
