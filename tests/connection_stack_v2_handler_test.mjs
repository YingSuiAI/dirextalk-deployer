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

console.log("connection stack v2 broker handler boundary ok");
