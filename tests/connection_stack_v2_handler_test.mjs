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
