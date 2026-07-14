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
