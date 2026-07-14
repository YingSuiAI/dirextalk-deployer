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
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const DEPLOYMENT_RESERVATION_STATE = "accepted";

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

function storedOptionalString(item, field, pattern) {
  if (item?.[field] === undefined) return undefined;
  return storedString(item, field, pattern);
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

function parseStoredDeployment(item, { connectionId, deploymentId }) {
  if (storedString(item, "connection_id", ID_PATTERN) !== connectionId
    || storedString(item, "deployment_id", ID_PATTERN) !== deploymentId) {
    fail("deployment_store_invalid", "stored deployment key is invalid", 500);
  }
  const requestSHA256 = storedString(item, "request_sha256", SHA256_PATTERN);
  const bootstrapSessionID = storedOptionalString(item, "bootstrap_session_id", ID_PATTERN);
  if (item?.reservation_state !== undefined) {
    if (item.reservation_state?.S !== DEPLOYMENT_RESERVATION_STATE
      || item.receipt_json !== undefined
      || item.resource_status !== undefined
      || item.instance_id !== undefined) {
      fail("deployment_store_invalid", "stored deployment reservation is invalid", 500);
    }
    storedString(item, "command_id", ID_PATTERN);
    storedString(item, "reserved_at", ISO_INSTANT_PATTERN);
    if (bootstrapSessionID === undefined) {
      fail("deployment_store_invalid", "stored deployment reservation has no bootstrap session", 500);
    }
    return {
      kind: "reservation",
      request_sha256: requestSHA256,
      bootstrap_session_id: bootstrapSessionID,
    };
  }
  return {
    kind: "receipt",
    request_sha256: requestSHA256,
    // Historical completed deployments can predate the Worker session
    // feature. They remain readable through getDeployment, but cannot be
    // reused as a Worker bootstrap source.
    bootstrap_session_id: bootstrapSessionID,
    receipt: validateDeploymentReceipt(parseJSON(storedString(item, "receipt_json", /^.+$/), "receipt_json"), {
      connectionId,
      deploymentId,
      requestSHA256,
    }),
  };
}

// DynamoDeploymentStore is the private lifecycle ledger for isolated EC2
// deployments. It reads immutable quote records issued by DynamoV2ReceiptStore
// and promotes that store's same-request deployment reservation to the closed
// receipt. It never handles Worker credentials, user data, secret references,
// or arbitrary provider requests.
export class DynamoDeploymentStore {
  constructor({
    client,
    issuedQuotesTableName,
    deploymentReceiptsTableName,
    GetItemCommand,
    UpdateItemCommand,
    nowMs,
  }) {
    if (!client?.send || !issuedQuotesTableName || !deploymentReceiptsTableName
      || !GetItemCommand || !UpdateItemCommand || typeof nowMs !== "function") {
      throw new TypeError("DynamoDB client, deployment table names, commands, and clock are required");
    }
    this.client = client;
    this.issuedQuotesTableName = issuedQuotesTableName;
    this.deploymentReceiptsTableName = deploymentReceiptsTableName;
    this.GetItemCommand = GetItemCommand;
    this.UpdateItemCommand = UpdateItemCommand;
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

  async getDeployment({ connection_id: connectionId, deployment_id: deploymentId, request_sha256: requestSHA256 } = {}) {
    requireString(connectionId, "connection_id", ID_PATTERN, "deployment_store_invalid");
    requireString(deploymentId, "deployment_id", ID_PATTERN, "deployment_store_invalid");
    if (requestSHA256 !== undefined) requireString(requestSHA256, "request_sha256", SHA256_PATTERN, "deployment_store_invalid");
    const stored = await this.#readDeployment(connectionId, deploymentId);
    if (stored && requestSHA256 !== undefined && stored.request_sha256 !== requestSHA256) {
      fail("deployment_id_conflict", "deployment id is already bound to another request");
    }
    return stored?.kind === "receipt" ? stored.receipt : undefined;
  }

  async getDeploymentBootstrap({ connection_id: connectionId, deployment_id: deploymentId, request_sha256: requestSHA256 } = {}) {
    requireString(connectionId, "connection_id", ID_PATTERN, "deployment_store_invalid");
    requireString(deploymentId, "deployment_id", ID_PATTERN, "deployment_store_invalid");
    requireString(requestSHA256, "request_sha256", SHA256_PATTERN, "deployment_store_invalid");
    const stored = await this.#readDeployment(connectionId, deploymentId);
    if (!stored) return undefined;
    if (stored.request_sha256 !== requestSHA256) {
      fail("deployment_id_conflict", "deployment id is already bound to another request");
    }
    if (stored.bootstrap_session_id === undefined) {
      fail("deployment_bootstrap_unavailable", "deployment has no worker bootstrap session", 409);
    }
    return {
      bootstrap_session_id: stored.bootstrap_session_id,
      request_sha256: stored.request_sha256,
    };
  }

  async #readDeployment(connectionId, deploymentId) {
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
    return parseStoredDeployment(output.Item, { connectionId, deploymentId });
  }

  async putDeployment(receipt) {
    const normalized = validateDeploymentReceipt(receipt);
    const nowMs = this.nowMs();
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
      fail("deployment_store_invalid", "clock is invalid", 500);
    }
    try {
      await this.client.send(new this.UpdateItemCommand({
        TableName: this.deploymentReceiptsTableName,
        Key: deploymentKey(normalized.connection_id, normalized.deployment_id),
        ConditionExpression: "request_sha256 = :request_sha256 AND reservation_state = :reservation_state AND attribute_exists(bootstrap_session_id)",
        UpdateExpression: "SET resource_status = :resource_status, instance_id = :instance_id, receipt_json = :receipt_json, recorded_at = :recorded_at REMOVE reservation_state, command_id, reserved_at",
        ExpressionAttributeValues: {
          ":request_sha256": { S: normalized.request_sha256 },
          ":reservation_state": { S: DEPLOYMENT_RESERVATION_STATE },
          ":resource_status": { S: normalized.resource_status },
          ":instance_id": { S: normalized.instance_id },
          ":receipt_json": { S: JSON.stringify(normalized) },
          ":recorded_at": { S: new Date(nowMs).toISOString() },
        },
      }));
      return normalized;
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("deployment_store_unavailable", "deployment storage is unavailable", 503);
      }
    }
    const existing = await this.#readDeployment(normalized.connection_id, normalized.deployment_id);
    if (!existing) fail("deployment_store_unavailable", "deployment storage could not reconcile its conditional write", 503);
    if (existing.request_sha256 !== normalized.request_sha256) {
      fail("deployment_id_conflict", "deployment id is already bound to another request", 409);
    }
    if (existing.kind === "reservation") {
      fail("deployment_store_unavailable", "deployment reservation could not be promoted", 503);
    }
    return existing.receipt;
  }
}
