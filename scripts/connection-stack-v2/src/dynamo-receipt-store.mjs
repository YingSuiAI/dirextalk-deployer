import {
  ConnectionStackV2Error,
} from "./command-contract.mjs";

const RECEIPT_COMMIT_SCHEMA = "dirextalk.aws.receipt-commit/v2";
const RECEIPT_SCHEMA = "dirextalk.aws.command-receipt/v2";
const CHALLENGE_SCHEMA = "dirextalk.aws.approval-challenge/v2";
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireString(record, field, pattern, code = "receipt_store_invalid") {
  const value = record[field];
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, 500);
  }
  return value;
}

function requireCounter(record, field, code = "receipt_store_invalid") {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(code, `${field} is invalid`, 500);
  }
  return value;
}

function requireCanonicalInstant(value, field, code = "receipt_store_invalid") {
  if (typeof value !== "string" || !ISO_INSTANT_PATTERN.test(value)) {
    fail(code, `${field} is invalid`, 500);
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== value) {
    fail(code, `${field} is invalid`, 500);
  }
  return value;
}

function transactionCanceled(error) {
  return error?.name === "TransactionCanceledException";
}

function requestKey(request) {
  return {
    connection_id: { S: request.connection_id },
    command_id: { S: request.command_id },
  };
}

function challengeKey(connectionId, challengeId) {
  return {
    connection_id: { S: connectionId },
    challenge_id: { S: challengeId },
  };
}

function validateChallengeToIssue(challenge, request) {
  if (!isRecord(challenge) || challenge.schema !== CHALLENGE_SCHEMA) {
    fail("receipt_store_invalid", "challenge to issue is invalid", 500);
  }
  if (requireString(challenge, "connection_id", ID_PATTERN) !== request.connection_id) {
    fail("receipt_store_invalid", "challenge connection is invalid", 500);
  }
  requireString(challenge, "challenge_id", ID_PATTERN);
  requireString(challenge, "challenge_request_id", ID_PATTERN);
  requireString(challenge, "binding_sha256", SHA256_PATTERN);
  requireCanonicalInstant(challenge.expires_at, "challenge expires_at");
  requireCanonicalInstant(challenge.issued_at, "challenge issued_at");
  return challenge;
}

function validateApprovalChallenge(challenge, request) {
  if (!isRecord(challenge) || challenge.schema !== CHALLENGE_SCHEMA) {
    fail("receipt_store_invalid", "approval challenge is invalid", 500);
  }
  if (requireString(challenge, "connection_id", ID_PATTERN) !== request.connection_id) {
    fail("receipt_store_invalid", "approval challenge connection is invalid", 500);
  }
  requireString(challenge, "challenge_id", ID_PATTERN);
  requireString(challenge, "binding_sha256", SHA256_PATTERN);
  requireCanonicalInstant(challenge.expires_at, "approval challenge expires_at");
  return challenge;
}

function validateRequest(request) {
  if (!isRecord(request) || request.schema !== RECEIPT_COMMIT_SCHEMA) {
    fail("receipt_store_invalid", "receipt commit is invalid", 500);
  }
  requireString(request, "connection_id", ID_PATTERN);
  if (!Number.isSafeInteger(request.expected_generation) || request.expected_generation < 1) {
    fail("receipt_store_invalid", "expected_generation is invalid", 500);
  }
  requireCounter(request, "node_counter");
  requireString(request, "command_id", ID_PATTERN);
  requireString(request, "request_sha256", SHA256_PATTERN);
  requireString(request, "action", /^[a-z][a-z0-9_.-]{2,63}$/);
  if (!Number.isSafeInteger(request.now_ms) || request.now_ms < 0) {
    fail("receipt_store_invalid", "now_ms is invalid", 500);
  }
  if (request.is_expired !== undefined && request.is_expired !== true) {
    fail("receipt_store_invalid", "is_expired is invalid", 500);
  }
  if (request.approval_binding_is_expired !== undefined && request.approval_binding_is_expired !== true) {
    fail("receipt_store_invalid", "approval_binding_is_expired is invalid", 500);
  }
  if (request.challenge_to_issue !== undefined) validateChallengeToIssue(request.challenge_to_issue, request);
  if (request.approval_challenge !== undefined) validateApprovalChallenge(request.approval_challenge, request);
  if (request.challenge_to_issue !== undefined && request.approval_challenge !== undefined) {
    fail("receipt_store_invalid", "a command cannot issue and consume a challenge", 500);
  }
  return request;
}

function receiptFor(request) {
  return {
    schema: RECEIPT_SCHEMA,
    disposition: "committed",
    connection_id: request.connection_id,
    expected_generation: request.expected_generation,
    node_counter: request.node_counter,
    command_id: request.command_id,
    request_sha256: request.request_sha256,
    action: request.action,
    ...(request.challenge_to_issue ? { challenge: request.challenge_to_issue } : {}),
  };
}

function storedNumber(item, field) {
  const numeric = item?.[field]?.N;
  const parsed = typeof numeric === "string" ? Number(numeric) : Number.NaN;
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    fail("receipt_store_invalid", `${field} is invalid`, 500);
  }
  return parsed;
}

function storedString(item, field, pattern) {
  const value = item?.[field]?.S;
  if (typeof value !== "string" || !pattern.test(value)) {
    fail("receipt_store_invalid", `${field} is invalid`, 500);
  }
  return value;
}

function parseStoredReceipt(item, request) {
  if (storedString(item, "request_sha256", SHA256_PATTERN) !== request.request_sha256
    || storedNumber(item, "expected_generation") !== request.expected_generation
    || storedNumber(item, "node_counter") !== request.node_counter
    || storedString(item, "action", /^[a-z][a-z0-9_.-]{2,63}$/) !== request.action) {
    fail("command_id_conflict", "command id is already bound to a different request");
  }
  let receipt;
  try {
    receipt = JSON.parse(storedString(item, "receipt_json", /^.+$/));
  } catch {
    fail("receipt_store_invalid", "stored receipt is invalid", 500);
  }
  if (!isRecord(receipt) || receipt.schema !== RECEIPT_SCHEMA) {
    fail("receipt_store_invalid", "stored receipt is invalid", 500);
  }
  return { ...receipt, disposition: "idempotent" };
}

function receiptItem(request, receipt) {
  return {
    connection_id: { S: request.connection_id },
    command_id: { S: request.command_id },
    request_sha256: { S: request.request_sha256 },
    expected_generation: { N: String(request.expected_generation) },
    node_counter: { N: String(request.node_counter) },
    action: { S: request.action },
    accepted_at: { S: new Date(request.now_ms).toISOString() },
    receipt_json: { S: JSON.stringify(receipt) },
  };
}

// DynamoV2ReceiptStore is the sole durable command/approval fence for the
// Connection Stack. It never accepts cloud credentials or invokes provider
// control APIs: a caller receives only an immutable command receipt.
export class DynamoV2ReceiptStore {
  constructor({
    client,
    receiptsTableName,
    challengesTableName,
    countersTableName,
    GetItemCommand,
    TransactWriteItemsCommand,
  }) {
    if (!client?.send || !receiptsTableName || !challengesTableName || !countersTableName
      || !GetItemCommand || !TransactWriteItemsCommand) {
      throw new TypeError("DynamoDB client, table names, and command constructors are required");
    }
    this.client = client;
    this.receiptsTableName = receiptsTableName;
    this.challengesTableName = challengesTableName;
    this.countersTableName = countersTableName;
    this.GetItemCommand = GetItemCommand;
    this.TransactWriteItemsCommand = TransactWriteItemsCommand;
  }

  async commit(input) {
    const request = validateRequest(input);
    const existing = await this.#findReceipt(request);
    if (existing) return existing;
    if (request.is_expired) {
      fail("expired_command", "an expired command cannot create a new receipt", 401);
    }
    if (request.approval_binding_is_expired) {
      fail("approval_expired", "an expired approval cannot create a new receipt", 401);
    }
    const receipt = receiptFor(request);
    try {
      await this.client.send(new this.TransactWriteItemsCommand({
        TransactItems: this.#transactionItems(request, receipt),
      }));
      return receipt;
    } catch (error) {
      if (!transactionCanceled(error)) {
        fail("connection_stack_store_unavailable", "Connection Stack receipt storage is unavailable", 503);
      }
    }
    const reconciled = await this.#findReceipt(request);
    if (reconciled) return reconciled;
    await this.#classifyCanceledTransaction(request);
    fail("receipt_race", "command receipt could not be reconciled", 503);
  }

  #transactionItems(request, receipt) {
    const items = [];
    if (request.approval_challenge) {
      const challenge = request.approval_challenge;
      items.push({
        Update: {
          TableName: this.challengesTableName,
          Key: challengeKey(request.connection_id, challenge.challenge_id),
          UpdateExpression: "SET consumed = :true, consumed_by_command_id = :command_id, consumed_at = :now",
          ConditionExpression: "attribute_exists(connection_id) AND attribute_exists(challenge_id) AND consumed = :false AND binding_sha256 = :binding_sha256 AND expires_at = :expires_at AND expires_at > :now",
          ExpressionAttributeValues: {
            ":true": { BOOL: true },
            ":false": { BOOL: false },
            ":command_id": { S: request.command_id },
            ":now": { S: new Date(request.now_ms).toISOString() },
            ":binding_sha256": { S: challenge.binding_sha256 },
            ":expires_at": { S: challenge.expires_at },
          },
        },
      });
    }
    items.push({
      Update: {
        TableName: this.countersTableName,
        Key: { connection_id: { S: request.connection_id } },
        UpdateExpression: "SET last_node_counter = :node_counter, updated_at = :now",
        ConditionExpression: "attribute_not_exists(last_node_counter) OR last_node_counter < :node_counter",
        ExpressionAttributeValues: {
          ":node_counter": { N: String(request.node_counter) },
          ":now": { S: new Date(request.now_ms).toISOString() },
        },
      },
    });
    items.push({
      Put: {
        TableName: this.receiptsTableName,
        ConditionExpression: "attribute_not_exists(connection_id) AND attribute_not_exists(command_id)",
        Item: receiptItem(request, receipt),
      },
    });
    if (request.challenge_to_issue) {
      const challenge = request.challenge_to_issue;
      items.push({
        Put: {
          TableName: this.challengesTableName,
          ConditionExpression: "attribute_not_exists(connection_id) AND attribute_not_exists(challenge_id)",
          Item: {
            connection_id: { S: challenge.connection_id },
            challenge_id: { S: challenge.challenge_id },
            challenge_request_id: { S: challenge.challenge_request_id },
            binding_sha256: { S: challenge.binding_sha256 },
            expires_at: { S: challenge.expires_at },
            issued_at: { S: challenge.issued_at },
            consumed: { BOOL: false },
          },
        },
      });
    }
    return items;
  }

  async #findReceipt(request) {
    let output;
    try {
      output = await this.client.send(new this.GetItemCommand({
        TableName: this.receiptsTableName,
        ConsistentRead: true,
        Key: requestKey(request),
      }));
    } catch {
      fail("connection_stack_store_unavailable", "Connection Stack receipt storage is unavailable", 503);
    }
    return output?.Item ? parseStoredReceipt(output.Item, request) : undefined;
  }

  async #readCounter(connectionId) {
    try {
      const output = await this.client.send(new this.GetItemCommand({
        TableName: this.countersTableName,
        ConsistentRead: true,
        Key: { connection_id: { S: connectionId } },
      }));
      return output?.Item ? storedNumber(output.Item, "last_node_counter") : undefined;
    } catch {
      fail("connection_stack_store_unavailable", "Connection Stack receipt storage is unavailable", 503);
    }
  }

  async #readChallenge(connectionId, challengeId) {
    try {
      const output = await this.client.send(new this.GetItemCommand({
        TableName: this.challengesTableName,
        ConsistentRead: true,
        Key: challengeKey(connectionId, challengeId),
      }));
      return output?.Item;
    } catch {
      fail("connection_stack_store_unavailable", "Connection Stack receipt storage is unavailable", 503);
    }
  }

  async #classifyCanceledTransaction(request) {
    if (request.approval_challenge) {
      const expected = request.approval_challenge;
      const stored = await this.#readChallenge(request.connection_id, expected.challenge_id);
      if (!stored) fail("unknown_approval_challenge", "approval challenge was not issued");
      if (stored.binding_sha256?.S !== expected.binding_sha256 || stored.expires_at?.S !== expected.expires_at) {
        fail("approval_binding_mismatch", "approval challenge does not bind this command");
      }
      if (stored.consumed?.BOOL === true) {
        fail("approval_replayed", "approval challenge was already consumed");
      }
      if (typeof stored.expires_at?.S !== "string" || stored.expires_at.S <= new Date(request.now_ms).toISOString()) {
        fail("approval_expired", "approval challenge has expired", 401);
      }
    }
    if (request.challenge_to_issue) {
      const stored = await this.#readChallenge(request.connection_id, request.challenge_to_issue.challenge_id);
      if (stored) fail("challenge_id_conflict", "challenge id is already in use");
    }
    const counter = await this.#readCounter(request.connection_id);
    if (counter !== undefined && counter >= request.node_counter) {
      fail("stale_node_counter", "node counter must advance monotonically");
    }
  }
}
