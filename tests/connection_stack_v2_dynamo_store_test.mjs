import assert from "node:assert/strict";

import {
  DynamoV2ReceiptStore,
} from "../scripts/connection-stack-v2/src/dynamo-receipt-store.mjs";

class GetItemCommand {
  constructor(input) {
    this.input = input;
  }
}

class TransactWriteItemsCommand {
  constructor(input) {
    this.input = input;
  }
}

class ScriptedDynamo {
  constructor({ receiptItem = undefined, receiptItems = undefined, transactionError = undefined } = {}) {
    this.receiptItem = receiptItem;
    this.receiptItems = receiptItems ? [...receiptItems] : undefined;
    this.transactionError = transactionError;
    this.gets = [];
    this.transactions = [];
  }

  async send(command) {
    if (command instanceof GetItemCommand) {
      this.gets.push(command.input);
      if (command.input.TableName === "receipts") {
        const item = this.receiptItems?.length ? this.receiptItems.shift() : this.receiptItem;
        return { Item: item };
      }
      return {};
    }
    if (command instanceof TransactWriteItemsCommand) {
      this.transactions.push(command.input);
      if (this.transactionError) throw this.transactionError;
      return {};
    }
    throw new Error("unexpected DynamoDB command");
  }
}

const NOW = Date.parse("2026-07-14T07:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const REQUEST_SHA256 = "a".repeat(64);

function challenge() {
  return {
    schema: "dirextalk.aws.approval-challenge/v2",
    connection_id: CONNECTION_ID,
    challenge_id: "challenge-v2-001",
    challenge_request_id: "challenge-request-v2-01",
    binding_sha256: "b".repeat(64),
    expires_at: "2026-07-14T07:04:00.000Z",
    issued_at: "2026-07-14T07:00:00.000Z",
  };
}

function request(overrides = {}) {
  return {
    schema: "dirextalk.aws.receipt-commit/v2",
    connection_id: CONNECTION_ID,
    expected_generation: 3,
    node_counter: 11,
    command_id: "command-v2-00001",
    request_sha256: REQUEST_SHA256,
    action: "approval.challenge.request",
    now_ms: NOW,
    challenge_to_issue: challenge(),
    ...overrides,
  };
}

function receiptFor(input) {
  return {
    schema: "dirextalk.aws.command-receipt/v2",
    disposition: "committed",
    connection_id: input.connection_id,
    expected_generation: input.expected_generation,
    node_counter: input.node_counter,
    command_id: input.command_id,
    request_sha256: input.request_sha256,
    action: input.action,
    ...(input.challenge_to_issue ? { challenge: input.challenge_to_issue } : {}),
  };
}

function storedReceiptItem(input, overrides = {}) {
  return {
    request_sha256: { S: input.request_sha256 },
    expected_generation: { N: String(input.expected_generation) },
    node_counter: { N: String(input.node_counter) },
    action: { S: input.action },
    receipt_json: { S: JSON.stringify(receiptFor(input)) },
    ...overrides,
  };
}

function store(client) {
  return new DynamoV2ReceiptStore({
    client,
    receiptsTableName: "receipts",
    challengesTableName: "challenges",
    countersTableName: "counters",
    GetItemCommand,
    TransactWriteItemsCommand,
  });
}

const firstClient = new ScriptedDynamo();
const firstReceipt = await store(firstClient).commit(request());
assert.equal(firstReceipt.disposition, "committed");
assert.deepEqual(firstReceipt.challenge, challenge());
assert.equal(firstClient.transactions.length, 1);
const transaction = firstClient.transactions[0].TransactItems;
assert.equal(transaction.length, 3, "issue, counter, and immutable receipt must commit together");
assert.match(transaction[0].Update.ConditionExpression, /last_node_counter/);
assert.equal(transaction[1].Put.ConditionExpression, "attribute_not_exists(connection_id) AND attribute_not_exists(command_id)");
assert.equal(transaction[2].Put.TableName, "challenges");

const expiredReplayInput = request({ is_expired: true });
const replayClient = new ScriptedDynamo({ receiptItem: storedReceiptItem(expiredReplayInput) });
const replay = await store(replayClient).commit(expiredReplayInput);
assert.equal(replay.disposition, "idempotent", "an expired request may only return its pre-existing receipt");
assert.equal(replayClient.transactions.length, 0, "idempotent replay must not consume a challenge or advance a counter");

const transactionCanceled = new Error("simulated DynamoDB conflict");
transactionCanceled.name = "TransactionCanceledException";
const reconciledClient = new ScriptedDynamo({
  receiptItems: [undefined, storedReceiptItem(request())],
  transactionError: transactionCanceled,
});
assert.equal(
  (await store(reconciledClient).commit(request())).disposition,
  "idempotent",
  "a transaction outcome race must reconcile against the immutable receipt before retrying",
);
assert.equal(reconciledClient.transactions.length, 1);

const expiredFreshClient = new ScriptedDynamo();
await assert.rejects(
  () => store(expiredFreshClient).commit(request({ is_expired: true })),
  (error) => error?.code === "expired_command",
);
assert.equal(expiredFreshClient.transactions.length, 0, "an expired new request must not touch DynamoDB state");

const conflictClient = new ScriptedDynamo({
  receiptItem: storedReceiptItem(request(), { request_sha256: { S: "c".repeat(64) } }),
});
await assert.rejects(
  () => store(conflictClient).commit(request()),
  (error) => error?.code === "command_id_conflict",
);

const consumeClient = new ScriptedDynamo();
await store(consumeClient).commit(request({
  action: "deployment.create",
  command_id: "command-v2-00002",
  node_counter: 12,
  challenge_to_issue: undefined,
  approval_challenge: {
    schema: "dirextalk.aws.approval-challenge/v2",
    connection_id: CONNECTION_ID,
    challenge_id: "challenge-v2-001",
    binding_sha256: "b".repeat(64),
    expires_at: "2026-07-14T07:04:00.000Z",
  },
}));
const consumeTransaction = consumeClient.transactions[0].TransactItems;
assert.equal(consumeTransaction.length, 3, "challenge consume, counter, and receipt must be one transaction");
assert.equal(consumeTransaction[0].Update.TableName, "challenges");
assert.match(consumeTransaction[0].Update.ConditionExpression, /consumed/);
assert.equal(consumeTransaction[2].Put.TableName, "receipts");

console.log("connection stack v2 Dynamo receipt store boundary ok");
