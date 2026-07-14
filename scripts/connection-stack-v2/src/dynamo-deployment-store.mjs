import {
  ConnectionStackV2Error,
  validateDeploymentReceipt,
} from "./deployment-contract.mjs";
import {
  cloudOrchestratorQuoteDigest,
  validateStoredQuote,
} from "./quote-contract.mjs";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function requireString(value, field, pattern, code = "deployment_store_invalid") {
  if (typeof value !== "string" || !pattern.test(value)) fail(code, `${field} is invalid`, 500);
  return value;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function quoteKey(connectionId, quoteId) {
  return {
    connection_id: { S: connectionId },
    quote_id: { S: quoteId },
  };
}

function deploymentKey(connectionId, deploymentId) {
  return {
    connection_id: { S: connectionId },
    deployment_id: { S: deploymentId },
  };
}

function storedString(item, field, pattern) {
  return requireString(item?.[field]?.S, field, pattern);
}

function parseJSON(value, field) {
  try {
    const parsed = JSON.parse(value);
    if (!isRecord(parsed)) throw new Error("not an object");
    return parsed;
  } catch {
    fail("deployment_store_invalid", `${field} is invalid`, 500);
  }
}

function quoteRequestFromStoredQuote(quote) {
  return {
    quote_request_id: quote?.quote_request_id,
    plan_digest: quote?.plan_digest,
    region: quote?.region,
    candidates: Array.isArray(quote?.candidates)
      ? quote.candidates.map((candidate) => ({
        candidate_id: candidate?.candidate_id,
        tier: candidate?.tier,
        instance_type: candidate?.instance_type,
        purchase_option: candidate?.purchase_option,
        estimated_disk_gib: candidate?.estimated_disk_gib,
      }))
      : quote?.candidates,
  };
}

function normalizedStoredQuote(quote) {
  const normalized = validateStoredQuote(quote, {
    connection_id: quote?.connection_id,
    command_id: quote?.command_id,
    request_sha256: quote?.request_sha256,
    payload: quoteRequestFromStoredQuote(quote),
    // The private record was already accepted by the receipt fence. Reusing
    // quoted_at only validates immutable quote shape and binding here; it does
    // not re-interpret the original command lifetime.
    issued_at: quote?.quoted_at,
    expires_at: quote?.quoted_at,
  });
  return normalized;
}

function conditionalFailure(error) {
  return error?.name === "ConditionalCheckFailedException";
}

// DynamoDeploymentStore is the private lifecycle ledger for isolated EC2
// deployments. It reads immutable quote records issued by DynamoV2ReceiptStore
// and persists only the closed deployment receipt. It never handles Worker
// credentials, user data, secret references, or arbitrary provider requests.
export class DynamoDeploymentStore {
  constructor({
    client,
    issuedQuotesTableName,
    deploymentReceiptsTableName,
    GetItemCommand,
    PutItemCommand,
    nowMs,
  }) {
    if (!client?.send || !issuedQuotesTableName || !deploymentReceiptsTableName
      || !GetItemCommand || !PutItemCommand || typeof nowMs !== "function") {
      throw new TypeError("DynamoDB client, deployment table names, commands, and clock are required");
    }
    this.client = client;
    this.issuedQuotesTableName = issuedQuotesTableName;
    this.deploymentReceiptsTableName = deploymentReceiptsTableName;
    this.GetItemCommand = GetItemCommand;
    this.PutItemCommand = PutItemCommand;
    this.nowMs = nowMs;
  }

  async getQuote({ connection_id: connectionId, quote_id: quoteId }) {
    requireString(connectionId, "connection_id", ID_PATTERN, "deployment_store_invalid");
    requireString(quoteId, "quote_id", ID_PATTERN, "deployment_store_invalid");
    let output;
    try {
      output = await this.client.send(new this.GetItemCommand({
        TableName: this.issuedQuotesTableName,
        ConsistentRead: true,
        Key: quoteKey(connectionId, quoteId),
      }));
    } catch {
      fail("deployment_store_unavailable", "quote storage is unavailable", 503);
    }
    if (!output?.Item) return undefined;
    const item = output.Item;
    if (storedString(item, "connection_id", ID_PATTERN) !== connectionId
      || storedString(item, "quote_id", ID_PATTERN) !== quoteId) {
      fail("deployment_store_invalid", "stored quote key is invalid", 500);
    }
    const quote = normalizedStoredQuote(parseJSON(storedString(item, "quote_json", /^.+$/), "quote_json"));
    if (quote.connection_id !== connectionId || quote.quote_id !== quoteId
      || quote.command_id !== storedString(item, "command_id", ID_PATTERN)
      || quote.request_sha256 !== storedString(item, "request_sha256", SHA256_PATTERN)
      || quote.plan_digest !== storedString(item, "plan_digest", NAMED_SHA256_PATTERN)
      || quote.valid_until !== storedString(item, "valid_until", /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)) {
      fail("deployment_store_invalid", "stored quote binding is invalid", 500);
    }
    const quoteDigest = storedString(item, "quote_digest", NAMED_SHA256_PATTERN);
    if (quoteDigest !== cloudOrchestratorQuoteDigest(quote, {
      connection_id: quote.connection_id,
      command_id: quote.command_id,
      request_sha256: quote.request_sha256,
      quote_request: quoteRequestFromStoredQuote(quote),
      issued_at: quote.quoted_at,
      expires_at: quote.quoted_at,
    })) {
      fail("quote_digest_mismatch", "stored quote digest is invalid", 500);
    }
    return { ...quote, quote_digest: quoteDigest };
  }

  async getDeployment({ connection_id: connectionId, deployment_id: deploymentId }) {
    requireString(connectionId, "connection_id", ID_PATTERN, "deployment_store_invalid");
    requireString(deploymentId, "deployment_id", ID_PATTERN, "deployment_store_invalid");
    let output;
    try {
      output = await this.client.send(new this.GetItemCommand({
        TableName: this.deploymentReceiptsTableName,
        ConsistentRead: true,
        Key: deploymentKey(connectionId, deploymentId),
      }));
    } catch {
      fail("deployment_store_unavailable", "deployment storage is unavailable", 503);
    }
    if (!output?.Item) return undefined;
    const item = output.Item;
    if (storedString(item, "connection_id", ID_PATTERN) !== connectionId
      || storedString(item, "deployment_id", ID_PATTERN) !== deploymentId) {
      fail("deployment_store_invalid", "stored deployment key is invalid", 500);
    }
    return validateDeploymentReceipt(parseJSON(storedString(item, "receipt_json", /^.+$/), "receipt_json"), {
      connectionId,
      deploymentId,
      requestSHA256: storedString(item, "request_sha256", SHA256_PATTERN),
    });
  }

  async putDeployment(receipt) {
    const normalized = validateDeploymentReceipt(receipt);
    const nowMs = this.nowMs();
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
      fail("deployment_store_invalid", "clock is invalid", 500);
    }
    try {
      await this.client.send(new this.PutItemCommand({
        TableName: this.deploymentReceiptsTableName,
        ConditionExpression: "attribute_not_exists(connection_id) AND attribute_not_exists(deployment_id)",
        Item: {
          ...deploymentKey(normalized.connection_id, normalized.deployment_id),
          request_sha256: { S: normalized.request_sha256 },
          resource_status: { S: normalized.resource_status },
          instance_id: { S: normalized.instance_id },
          receipt_json: { S: JSON.stringify(normalized) },
          recorded_at: { S: new Date(nowMs).toISOString() },
        },
      }));
      return normalized;
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("deployment_store_unavailable", "deployment storage is unavailable", 503);
      }
    }
    const existing = await this.getDeployment({
      connection_id: normalized.connection_id,
      deployment_id: normalized.deployment_id,
    });
    if (!existing) fail("deployment_store_unavailable", "deployment storage could not reconcile its conditional write", 503);
    if (existing.request_sha256 !== normalized.request_sha256) {
      fail("deployment_id_conflict", "deployment id is already bound to another request", 409);
    }
    return existing;
  }
}
