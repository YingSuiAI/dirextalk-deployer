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
  constructor({ receiptItem = undefined, receiptItems = undefined, deploymentItem = undefined, transactionError = undefined } = {}) {
    this.receiptItem = receiptItem;
    this.receiptItems = receiptItems ? [...receiptItems] : undefined;
    this.deploymentItem = deploymentItem;
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
      if (command.input.TableName === "deployments") return { Item: this.deploymentItem };
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
const BOOTSTRAP_SESSION_ID = "worker-session-v2-001";
const QUOTE_REQUEST = {
  quote_request_id: "quote-request-v2-001",
  plan_digest: `sha256:${"b".repeat(64)}`,
  region: "ap-south-1",
  candidates: [{
    candidate_id: "candidate-economy-01",
    tier: "economy",
    instance_type: "t3.large",
    purchase_option: "on_demand",
    estimated_disk_gib: 40,
  }],
};

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

function approvalProof() {
  return {
    schema: "dirextalk.aws.approval-proof-reference/v1",
    connection_id: CONNECTION_ID,
    approval_id: "approval-proof-v2-01",
    payload_sha256: "d".repeat(64),
    expires_at: "2026-07-14T07:04:00.000Z",
  };
}

function deploymentReservation(deploymentId = "deployment-v2-001") {
  return { deployment_id: deploymentId };
}

function reservedDeploymentItem({
  deploymentId = "deployment-v2-001",
  requestSHA256 = REQUEST_SHA256,
  bootstrapSessionID = BOOTSTRAP_SESSION_ID,
} = {}) {
  return {
    connection_id: { S: CONNECTION_ID },
    deployment_id: { S: deploymentId },
    request_sha256: { S: requestSHA256 },
    command_id: { S: "command-v2-reserved-001" },
    bootstrap_session_id: { S: bootstrapSessionID },
    reservation_state: { S: "accepted" },
    reserved_at: { S: "2026-07-14T07:00:00.000Z" },
  };
}

function quoteFor(input) {
  return {
    schema: "dirextalk.aws.quote/v1",
    quote_id: `quote-${input.request_sha256.slice(0, 32)}`,
    connection_id: input.connection_id,
    command_id: input.command_id,
    request_sha256: input.request_sha256,
    quote_request_id: input.quote_request.quote_request_id,
    plan_digest: input.quote_request.plan_digest,
    region: input.quote_request.region,
    currency: "USD",
    quoted_at: new Date(input.now_ms).toISOString(),
    valid_until: new Date(input.now_ms + 15 * 60 * 1000).toISOString(),
    candidates: input.quote_request.candidates.map((candidate) => ({
      ...candidate,
      architecture: "amd64",
      vcpu: 2,
      memory_mib: 8192,
      gpu_count: 0,
      gpu_memory_mib: 0,
      hourly_minor: 5,
      thirty_day_minor: 2996,
      startup_upper_minor: 0,
      availability_zones: ["ap-south-1a"],
    })),
    included_items: ["ec2_linux_ondemand"],
    unincluded_items: ["cloudwatch_logs", "data_transfer", "ebs_gp3", "public_ipv4", "snapshots", "taxes"],
  };
}

function quoteRequest(overrides = {}) {
  return request({
    action: "quote.request",
    command_id: "command-v2-quote-001",
    node_counter: 12,
    request_sha256: "c".repeat(64),
    challenge_to_issue: undefined,
    quote_request: structuredClone(QUOTE_REQUEST),
    ...overrides,
  });
}

function registration() {
  return {
    schema: "dirextalk.aws.connection-registration/v1",
    bootstrap_id: "bootstrap-v2-0001",
    connection_id: CONNECTION_ID,
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
    worker_resource_manifest_digest: `sha256:${"e".repeat(64)}`,
    stack_arn: "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef",
    command_id: "command-v2-registration-01",
    request_sha256: "d".repeat(64),
  };
}

function registrationRequest(overrides = {}) {
  return request({
    action: "connection.registration.verify",
    command_id: "command-v2-registration-01",
    node_counter: 13,
    request_sha256: "d".repeat(64),
    challenge_to_issue: undefined,
    registration: registration(),
    ...overrides,
  });
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
    ...(input.action === "quote.request" ? { quote: quoteFor(input) } : {}),
    ...(input.registration ? { registration: input.registration } : {}),
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

function store(client, { createBootstrapSessionID } = {}) {
  return new DynamoV2ReceiptStore({
    client,
    receiptsTableName: "receipts",
    challengesTableName: "challenges",
    approvalProofsTableName: "approval-proofs",
    issuedQuotesTableName: "issued-quotes",
    deploymentReceiptsTableName: "deployments",
    countersTableName: "counters",
    GetItemCommand,
    TransactWriteItemsCommand,
    ...(createBootstrapSessionID ? { createBootstrapSessionID } : {}),
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

let quoteProviderCalls = 0;
const quoteInput = quoteRequest();
const quoteClient = new ScriptedDynamo();
const quoteReceipt = await store(quoteClient).commit(quoteInput, {
  async quote(input) {
    quoteProviderCalls += 1;
    return quoteFor(input);
  },
});
assert.equal(quoteProviderCalls, 1, "a fresh quote must be obtained once before its receipt is committed");
assert.equal(quoteReceipt.quote.quote_id, `quote-${"c".repeat(32)}`);
assert.equal(quoteClient.transactions.length, 1);
assert.equal(quoteClient.transactions[0].TransactItems.length, 3, "a quote atomically stores its durable private digest, counter, and receipt");
assert.deepEqual(
  JSON.parse(quoteClient.transactions[0].TransactItems[1].Put.Item.receipt_json.S).quote,
  quoteReceipt.quote,
  "the durable receipt must retain the exact provider quote",
);
const issuedQuoteWrite = quoteClient.transactions[0].TransactItems[2].Put;
assert.equal(issuedQuoteWrite.TableName, "issued-quotes");
assert.match(issuedQuoteWrite.Item.quote_digest.S, /^sha256:[0-9a-f]{64}$/);
assert.equal(issuedQuoteWrite.Item.quote_json.S, JSON.stringify(quoteReceipt.quote), "the private quote record must preserve the public quote without expanding it");

const expiredQuoteInput = quoteRequest({ is_expired: true });
const quoteReplayClient = new ScriptedDynamo({ receiptItem: storedReceiptItem(expiredQuoteInput) });
const quoteReplay = await store(quoteReplayClient).commit(expiredQuoteInput, {
  async quote() {
    throw new Error("an idempotent quote replay must not query AWS pricing");
  },
});
assert.equal(quoteReplay.disposition, "idempotent");
assert.equal(quoteReplay.quote.quote_id, `quote-${"c".repeat(32)}`);
assert.equal(quoteReplayClient.transactions.length, 0);

let expiredQuoteProviderCalls = 0;
const expiredFreshQuoteClient = new ScriptedDynamo();
await assert.rejects(
  () => store(expiredFreshQuoteClient).commit(quoteRequest({ is_expired: true }), {
    async quote() {
      expiredQuoteProviderCalls += 1;
      return quoteFor(quoteInput);
    },
  }),
  (error) => error?.code === "expired_command",
);
assert.equal(expiredQuoteProviderCalls, 0, "an expired fresh quote must not query AWS pricing");
assert.equal(expiredFreshQuoteClient.transactions.length, 0);

const registrationClient = new ScriptedDynamo();
const registrationReceipt = await store(registrationClient).commit(registrationRequest());
assert.equal(registrationReceipt.action, "connection.registration.verify");
assert.deepEqual(registrationReceipt.registration, registration());
assert.equal(registrationClient.transactions.length, 1);
assert.equal(registrationClient.transactions[0].TransactItems.length, 2, "registration must atomically advance its counter and persist the exact attestation");
assert.deepEqual(
  JSON.parse(registrationClient.transactions[0].TransactItems[1].Put.Item.receipt_json.S).registration,
  registration(),
  "the durable receipt must retain the stack-derived registration exactly",
);

const invalidQuoteClient = new ScriptedDynamo();
await assert.rejects(
  () => store(invalidQuoteClient).commit(quoteRequest({ command_id: "command-v2-quote-002", node_counter: 13 }), {
    async quote() {
      return {};
    },
  }),
  (error) => error?.code === "receipt_store_invalid",
);
assert.equal(invalidQuoteClient.transactions.length, 0, "an invalid provider result must not be persisted");

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
  deployment_reservation: deploymentReservation(),
  approval_challenge: {
    schema: "dirextalk.aws.approval-challenge/v2",
    connection_id: CONNECTION_ID,
    challenge_id: "challenge-v2-001",
    binding_sha256: "b".repeat(64),
    expires_at: "2026-07-14T07:04:00.000Z",
  },
}));
const consumeTransaction = consumeClient.transactions[0].TransactItems;
assert.equal(consumeTransaction.length, 4, "challenge consume, deployment-id reservation, counter, and receipt must be one transaction");
assert.equal(consumeTransaction[0].Update.TableName, "challenges");
assert.match(consumeTransaction[0].Update.ConditionExpression, /consumed/);
assert.equal(consumeTransaction.find((item) => item.Put?.TableName === "deployments").Put.Item.deployment_id.S, "deployment-v2-001");
assert.equal(consumeTransaction.find((item) => item.Put?.TableName === "receipts").Put.TableName, "receipts");

const proofClient = new ScriptedDynamo();
let generatedBootstrapSessionIDs = 0;
await store(proofClient, {
  createBootstrapSessionID() {
    generatedBootstrapSessionIDs += 1;
    return BOOTSTRAP_SESSION_ID;
  },
}).commit(request({
  action: "deployment.create",
  command_id: "command-v2-proof-01",
  node_counter: 13,
  challenge_to_issue: undefined,
  deployment_reservation: deploymentReservation(),
  approval_proof: approvalProof(),
}));
const proofTransaction = proofClient.transactions[0].TransactItems;
assert.equal(proofTransaction.length, 4, "ApprovalV1 proof, deployment-id reservation, counter, and immutable command receipt must commit together");
assert.equal(proofTransaction[0].Put.TableName, "approval-proofs");
assert.equal(proofTransaction[0].Put.Item.approval_id.S, "approval-proof-v2-01");
assert.equal(proofTransaction[0].Put.Item.payload_sha256.S, "d".repeat(64));
const deploymentReservationWrite = proofTransaction.find((item) => item.Put?.TableName === "deployments");
assert.ok(deploymentReservationWrite, "the deployment id must be reserved in the command acceptance transaction before EC2 can run");
assert.equal(deploymentReservationWrite.Put.ConditionExpression, "attribute_not_exists(connection_id) AND attribute_not_exists(deployment_id)");
assert.deepEqual(deploymentReservationWrite.Put.Item, {
  connection_id: { S: CONNECTION_ID },
  deployment_id: { S: "deployment-v2-001" },
  request_sha256: { S: REQUEST_SHA256 },
  command_id: { S: "command-v2-proof-01" },
  bootstrap_session_id: { S: BOOTSTRAP_SESSION_ID },
  reservation_state: { S: "accepted" },
  reserved_at: { S: "2026-07-14T07:00:00.000Z" },
});
assert.equal(generatedBootstrapSessionIDs, 1, "a fresh deployment reservation must generate one opaque Worker session id inside the durable transaction");
assert.equal(proofTransaction.find((item) => item.Put?.TableName === "receipts").Put.TableName, "receipts");

const recoveredDeploymentInput = request({
  action: "deployment.create",
  command_id: "command-v2-deployment-recovered",
  node_counter: 14,
  challenge_to_issue: undefined,
  deployment_reservation: deploymentReservation(),
  approval_proof: approvalProof(),
});
let recoveredGeneratorCalls = 0;
const recoveredReceiptClient = new ScriptedDynamo({
  receiptItem: storedReceiptItem(recoveredDeploymentInput),
});
assert.equal(
  (await store(recoveredReceiptClient, {
    createBootstrapSessionID() {
      recoveredGeneratorCalls += 1;
      return "worker-session-v2-should-not-run";
    },
  }).commit(recoveredDeploymentInput)).disposition,
  "idempotent",
  "a recovered committed command must use its existing receipt before generating a different bootstrap session id",
);
assert.equal(recoveredGeneratorCalls, 0, "a retry after a persisted receipt must not replace its bootstrap session id");
assert.equal(recoveredReceiptClient.transactions.length, 0);

const deploymentReservationConflict = new Error("simulated DynamoDB deployment reservation conflict");
deploymentReservationConflict.name = "TransactionCanceledException";
const deploymentConflictClient = new ScriptedDynamo({
  deploymentItem: reservedDeploymentItem({ requestSHA256: "f".repeat(64) }),
  transactionError: deploymentReservationConflict,
});
await assert.rejects(
  () => store(deploymentConflictClient).commit(request({
    action: "deployment.create",
    command_id: "command-v2-deployment-conflict",
    node_counter: 14,
    challenge_to_issue: undefined,
    approval_proof: approvalProof(),
    deployment_reservation: deploymentReservation(),
  })),
  (error) => error?.code === "deployment_id_conflict",
  "a different request for a reserved deployment id must fail in the acceptance transaction",
);
assert.equal(deploymentConflictClient.transactions.length, 1, "the conflicting request must be stopped by Dynamo before any provider step can follow");
assert.equal(
  deploymentConflictClient.gets.find((input) => input.TableName === "deployments")?.ConsistentRead,
  true,
  "the rejected reservation must be read back consistently before classifying the conflict",
);

console.log("connection stack v2 Dynamo receipt store boundary ok");
