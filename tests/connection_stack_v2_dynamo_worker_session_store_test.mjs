import assert from "node:assert/strict";

import {
  DynamoWorkerSessionStore,
} from "../scripts/connection-stack-v2/src/dynamo-worker-session-store.mjs";
import {
  workerSessionEventSHA256,
} from "../scripts/connection-stack-v2/src/worker-session-contract.mjs";

class GetItemCommand {
  constructor(input) { this.input = input; }
}

class PutItemCommand {
  constructor(input) { this.input = input; }
}

class UpdateItemCommand {
  constructor(input) { this.input = input; }
}

const NOW = Date.parse("2026-07-15T01:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const DEPLOYMENT_ID = "deployment-v2-001";
const SESSION_ID = "worker-session-v2-001";
const REQUEST_SHA256 = "a".repeat(64);
const TOKEN_ONE_SHA256 = "b".repeat(64);
const TOKEN_TWO_SHA256 = "c".repeat(64);

function conditionalFailure() {
  return Object.assign(new Error("conditional write failed"), { name: "ConditionalCheckFailedException" });
}

function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

function sessionInput(overrides = {}) {
  return {
    bootstrap_session_id: SESSION_ID,
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: REQUEST_SHA256,
    worker_image_digest: `sha256:${"e".repeat(64)}`,
    artifact_manifest_digest: `sha256:${"f".repeat(64)}`,
    bootstrap_endpoint: "https://a1b2c3d4e5.execute-api.ap-northeast-1.amazonaws.com/prod/v2/worker-sessions",
    account_id: "123456789012",
    region: "ap-northeast-1",
    expected_ami_id: "ami-0123456789abcdef0",
    expected_instance_type: "t3.large",
    expected_architecture: "x86_64",
    expected_vpc_id: "vpc-0123456789abcdef0",
    expected_subnet_id: "subnet-0123456789abcdef0",
    expected_availability_zone: "ap-northeast-1a",
    expected_security_group_id: "sg-0123456789abcdef0",
    expires_at: "2026-07-15T01:10:00.000Z",
    ...overrides,
  };
}

function heartbeat(sequence, overrides = {}) {
  return {
    schema: "dirextalk.worker-event/v1",
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    lease_epoch: 1,
    sequence,
    kind: "heartbeat",
    occurred_at: "2026-07-15T01:00:00.000Z",
    ...overrides,
  };
}

function eventInput(sequence, overrides = {}) {
  const event = heartbeat(sequence, overrides);
  return {
    event_json: JSON.stringify(event),
    event_sha256: workerSessionEventSHA256(event),
  };
}

class SessionDynamo {
  constructor() {
    this.item = undefined;
    this.gets = [];
    this.puts = [];
    this.updates = [];
  }

  async send(command) {
    if (command instanceof GetItemCommand) {
      this.gets.push(clone(command.input));
      return { Item: clone(this.item) };
    }
    if (command instanceof PutItemCommand) {
      this.puts.push(clone(command.input));
      if (this.item) throw conditionalFailure();
      this.item = clone(command.input.Item);
      return {};
    }
    if (!(command instanceof UpdateItemCommand)) throw new Error("unexpected Dynamo command");
    this.updates.push(clone(command.input));
    const values = command.input.ExpressionAttributeValues;
    if (!this.item) throw conditionalFailure();

    if (command.input.UpdateExpression.includes("expected_instance_id")) {
      if (this.item.request_sha256?.S !== values[":request_sha256"].S
        || this.item.state?.S !== "issued" || this.item.expires_at?.S <= values[":now"].S
        || this.item.expected_instance_id !== undefined
        || (values[":security_group_id"] !== undefined && this.item.expected_security_group_id?.S !== values[":security_group_id"].S)) throw conditionalFailure();
      this.item.state = values[":bound"];
      this.item.expected_instance_id = values[":instance_id"];
      this.item.bound_at = values[":now"];
      this.item.updated_at = values[":now"];
      return { Attributes: clone(this.item) };
    }
    if (command.input.UpdateExpression.includes("lease_epoch")) {
      if (this.item.expected_instance_id?.S !== values[":instance_id"].S
        || !["bound", "active"].includes(this.item.state?.S)
        || this.item.expires_at?.S <= values[":now"].S) throw conditionalFailure();
      this.item.state = values[":active"];
      this.item.lease_epoch = { N: String(Number(this.item.lease_epoch?.N ?? "0") + 1) };
      this.item.lease_expires_at = values[":lease_expires_at"];
      this.item.token_sha256 = values[":token_sha256"];
      this.item.last_sequence = values[":zero"];
      delete this.item.last_event_sha256;
      delete this.item.last_event_json;
      delete this.item.last_event_at;
      this.item.claimed_at = values[":now"];
      this.item.updated_at = values[":now"];
      return { Attributes: clone(this.item) };
    }
    if (command.input.UpdateExpression.includes("last_event_sha256")) {
      if (this.item.connection_id?.S !== values[":connection_id"].S || this.item.deployment_id?.S !== values[":deployment_id"].S
        || this.item.state?.S !== "active" || this.item.token_sha256?.S !== values[":token_sha256"].S
        || this.item.lease_epoch?.N !== values[":lease_epoch"].N
        || this.item.lease_expires_at?.S <= values[":now"].S
        || this.item.last_sequence?.N !== values[":previous_sequence"].N) throw conditionalFailure();
      this.item.last_sequence = values[":sequence"];
      this.item.last_event_sha256 = values[":event_sha256"];
      this.item.last_event_json = values[":event_json"];
      this.item.last_event_at = values[":now"];
      this.item.updated_at = values[":now"];
      return { Attributes: clone(this.item) };
    }
    throw new Error("unexpected Dynamo update");
  }
}

function store(client, nowMs = () => NOW) {
  return new DynamoWorkerSessionStore({
    client,
    workerSessionsTableName: "worker-sessions",
    GetItemCommand,
    PutItemCommand,
    UpdateItemCommand,
    nowMs,
  });
}

const client = new SessionDynamo();
let currentNow = NOW;
const sessions = store(client, () => currentNow);
const issued = await sessions.issue(sessionInput());
assert.equal(issued.state, "issued");
assert.equal(issued.lease_epoch, 0);
assert.equal(issued.last_sequence, 0);
assert.equal(client.puts.length, 1);
assert.equal(client.puts[0].ConditionExpression, "attribute_not_exists(bootstrap_session_id)");
assert.equal(client.puts[0].Item.ttl_epoch_seconds.N, String(Math.ceil(Date.parse(sessionInput().expires_at) / 1000)));
for (const field of ["access_token", "worker_token", "secret_ref"]) {
  assert.equal(Object.hasOwn(client.puts[0].Item, field), false, `${field} must never enter a durable Worker session`);
}
assert.equal((await sessions.get(SESSION_ID)).state, "issued");
assert.equal(client.gets.at(-1).ConsistentRead, true);

const bound = await sessions.bind({
  session_id: SESSION_ID,
  request_sha256: REQUEST_SHA256,
  instance_id: "i-0123456789abcdef0",
  security_group_id: "sg-0123456789abcdef0",
});
assert.equal(bound.state, "bound");
assert.equal(bound.expected_instance_id, "i-0123456789abcdef0");
assert.match(client.updates.at(-1).ConditionExpression, /expected_security_group_id = :security_group_id/);

const claimed = await sessions.claim({
  session_id: SESSION_ID,
  instance_id: "i-0123456789abcdef0",
  token_sha256: TOKEN_ONE_SHA256,
  lease_expires_at: "2026-07-15T01:05:00.000Z",
});
assert.equal(claimed.state, "active");
assert.equal(claimed.lease_epoch, 1);
assert.equal(claimed.token_sha256, TOKEN_ONE_SHA256);
assert.equal(client.updates.at(-1).ConditionExpression.includes("token_sha256"), false, "claim replaces a bearer hash only after the IID-bound session is proven");
assert.equal(client.updates.at(-1).ReturnValues, "ALL_NEW");

assert.deepEqual(
  await sessions.recordEvent({
    session_id: SESSION_ID,
    token_sha256: TOKEN_ONE_SHA256,
    lease_epoch: 1,
    sequence: 1,
    ...eventInput(1),
  }),
  { disposition: "accepted" },
);
assert.match(client.updates.at(-1).ConditionExpression, /connection_id = :connection_id/);
assert.match(client.updates.at(-1).ConditionExpression, /token_sha256 = :token_sha256/);
assert.match(client.updates.at(-1).ConditionExpression, /last_sequence = :previous_sequence/);
assert.deepEqual(
  await sessions.recordEvent({
    session_id: SESSION_ID,
    token_sha256: TOKEN_ONE_SHA256,
    lease_epoch: 1,
    sequence: 1,
    ...eventInput(1),
  }),
  { disposition: "idempotent" },
  "the same post-response retry must not create a second progress transition",
);
await assert.rejects(
  () => sessions.recordEvent({
    session_id: SESSION_ID,
    token_sha256: TOKEN_ONE_SHA256,
    lease_epoch: 1,
    sequence: 3,
    ...eventInput(3),
  }),
  (error) => error?.code === "worker_event_conflict",
  "a sequence gap must fail closed",
);
await assert.rejects(
  () => sessions.recordEvent({
    session_id: SESSION_ID,
    token_sha256: TOKEN_ONE_SHA256,
    lease_epoch: 1,
    sequence: 2,
    ...eventInput(2, { connection_id: "connection-v2-0002" }),
  }),
  (error) => error?.code === "worker_session_unauthorized",
  "a valid-looking event cannot be rebound to a different durable deployment",
);

const reclaimed = await sessions.claim({
  session_id: SESSION_ID,
  instance_id: "i-0123456789abcdef0",
  token_sha256: TOKEN_TWO_SHA256,
  lease_expires_at: "2026-07-15T01:06:00.000Z",
});
assert.equal(reclaimed.lease_epoch, 2, "the same IID-proven Worker rotates its lease epoch on reconnect");
assert.equal(reclaimed.last_sequence, 0);
await assert.rejects(
  () => sessions.recordEvent({
    session_id: SESSION_ID,
    token_sha256: TOKEN_ONE_SHA256,
    lease_epoch: 1,
    sequence: 1,
    ...eventInput(1),
  }),
  (error) => error?.code === "worker_session_unauthorized",
  "rotated bearer hashes invalidate old Worker event submissions",
);

const idempotentIssue = await sessions.issue(sessionInput());
assert.equal(idempotentIssue.bootstrap_session_id, SESSION_ID);
currentNow += 5_000;
const recoveredIssue = await sessions.issue(sessionInput({
  // A provisioning retry can start a few seconds later after RunInstances
  // accepted the ClientToken but its response was lost. Its durable session
  // fence must preserve the originally written expiry so regenerated UserData
  // remains byte-for-byte equivalent to the first EC2 request.
  expires_at: "2026-07-15T01:10:05.000Z",
}));
assert.equal(
  recoveredIssue.expires_at,
  sessionInput().expires_at,
  "a same-binding Worker bootstrap retry must reuse its original expiry",
);
await assert.rejects(
  () => sessions.issue(sessionInput({ artifact_manifest_digest: `sha256:${"1".repeat(64)}` })),
  (error) => error?.code === "worker_session_conflict",
  "a bootstrap session id cannot be rebound to a different artifact",
);

const expiredClient = new SessionDynamo();
const expiredStore = store(expiredClient, () => Date.parse("2026-07-15T01:11:00.000Z"));
await assert.rejects(
  () => expiredStore.issue(sessionInput()),
  (error) => error?.code === "worker_session_expired",
  "a bootstrap session cannot be issued after its own expiry",
);

console.log("connection stack v2 Dynamo Worker session store boundary ok");
