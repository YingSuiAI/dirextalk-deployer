import {
  createHash,
} from "node:crypto";

import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  parseWorkerSessionEvent,
  WORKER_SESSION_MAX_LEASE_LIFETIME_MS,
  workerSessionEventSHA256,
} from "./worker-session-contract.mjs";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const ACCOUNT_ID_PATTERN = /^\d{12}$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const AMI_ID_PATTERN = /^ami-[0-9a-f]{8,17}$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;
const INSTANCE_TYPE_PATTERN = /^[a-z0-9][a-z0-9.-]{1,63}$/;
const ARCHITECTURE_PATTERN = /^(?:x86_64|arm64)$/;
const VPC_ID_PATTERN = /^vpc-[0-9a-f]{8,17}$/;
const SUBNET_ID_PATTERN = /^subnet-[0-9a-f]{8,17}$/;
const SECURITY_GROUP_ID_PATTERN = /^sg-[0-9a-f]{8,17}$/;
const AVAILABILITY_ZONE_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const SESSION_STATES = new Set(["issued", "bound", "active"]);
const MAX_EVENT_JSON_BYTES = 16 * 1024;

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireString(value, field, pattern, code = "worker_session_invalid", statusCode = 500) {
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requireSafeNonnegativeInteger(value, field, code = "worker_session_invalid", statusCode = 500) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requirePositiveSafeInteger(value, field, code = "worker_session_invalid", statusCode = 500) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function parseCanonicalInstant(value, field, code = "worker_session_invalid", statusCode = 500) {
  if (typeof value !== "string" || !ISO_INSTANT_PATTERN.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return milliseconds;
}

function requireHttpsEndpoint(value) {
  if (typeof value !== "string" || value.length < 12 || value.length > 2048) {
    fail("worker_session_invalid", "bootstrap_endpoint is invalid", 500);
  }
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    fail("worker_session_invalid", "bootstrap_endpoint is invalid", 500);
  }
  if (endpoint.protocol !== "https:" || endpoint.username !== "" || endpoint.password !== ""
    || endpoint.search !== "" || endpoint.hash !== "" || endpoint.hostname === "") {
    fail("worker_session_invalid", "bootstrap_endpoint is invalid", 500);
  }
  return endpoint.toString();
}

function sessionKey(sessionId) {
  return { bootstrap_session_id: { S: sessionId } };
}

function conditionalFailure(error) {
  return error?.name === "ConditionalCheckFailedException";
}

function storedString(item, field, pattern) {
  return requireString(item?.[field]?.S, field, pattern, "worker_session_store_invalid", 500);
}

function storedOptionalString(item, field, pattern) {
  if (item?.[field] === undefined) return undefined;
  return storedString(item, field, pattern);
}

function storedNonnegativeInteger(item, field) {
  const value = item?.[field]?.N;
  if (typeof value !== "string" || !/^(?:0|[1-9]\d*)$/.test(value)) {
    fail("worker_session_store_invalid", `${field} is invalid`, 500);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || String(parsed) !== value) {
    fail("worker_session_store_invalid", `${field} is invalid`, 500);
  }
  return parsed;
}

function storedPositiveInteger(item, field) {
  const value = storedNonnegativeInteger(item, field);
  if (value <= 0) fail("worker_session_store_invalid", `${field} is invalid`, 500);
  return value;
}

function storedInstant(item, field) {
  const value = storedString(item, field, ISO_INSTANT_PATTERN);
  parseCanonicalInstant(value, field, "worker_session_store_invalid", 500);
  return value;
}

function hasForbiddenSecretField(item) {
  return item?.access_token !== undefined || item?.worker_token !== undefined || item?.secret_ref !== undefined;
}

const STORED_SESSION_BASE_FIELDS = new Set([
  "bootstrap_session_id",
  "connection_id",
  "deployment_id",
  "request_sha256",
  "worker_image_digest",
  "artifact_manifest_digest",
  "bootstrap_endpoint",
  "account_id",
  "region",
  "expected_ami_id",
  "expected_instance_type",
  "expected_architecture",
  "expected_vpc_id",
  "expected_subnet_id",
  "expected_availability_zone",
  "expected_security_group_id",
  "state",
  "expires_at",
  "ttl_epoch_seconds",
  "issued_at",
  "updated_at",
  "lease_epoch",
  "last_sequence",
]);

function requireStoredSessionFields(item, state) {
  const allowed = new Set(STORED_SESSION_BASE_FIELDS);
  if (state === "bound" || state === "active") {
    allowed.add("expected_instance_id");
    allowed.add("bound_at");
  }
  if (state === "active") {
    for (const field of [
      "claimed_at",
      "lease_expires_at",
      "token_sha256",
      "last_event_sha256",
      "last_event_json",
      "last_event_at",
    ]) allowed.add(field);
  }
  for (const field of Object.keys(item)) {
    if (!allowed.has(field)) {
      fail("worker_session_store_invalid", "stored worker session is invalid", 500);
    }
  }
}

function parseStoredSession(item, expectedSessionId) {
  if (!isRecord(item) || hasForbiddenSecretField(item)) {
    fail("worker_session_store_invalid", "stored worker session is invalid", 500);
  }
  const bootstrapSessionId = storedString(item, "bootstrap_session_id", ID_PATTERN);
  if (bootstrapSessionId !== expectedSessionId) {
    fail("worker_session_store_invalid", "stored worker session key is invalid", 500);
  }
  const state = storedString(item, "state", /^(?:issued|bound|active)$/);
  if (!SESSION_STATES.has(state)) {
    fail("worker_session_store_invalid", "stored worker session state is invalid", 500);
  }
  requireStoredSessionFields(item, state);
  const expiresAt = storedInstant(item, "expires_at");
  const ttlEpochSeconds = storedPositiveInteger(item, "ttl_epoch_seconds");
  if (ttlEpochSeconds !== Math.ceil(Date.parse(expiresAt) / 1000)) {
    fail("worker_session_store_invalid", "stored worker session ttl is invalid", 500);
  }
  const session = {
    bootstrap_session_id: bootstrapSessionId,
    connection_id: storedString(item, "connection_id", ID_PATTERN),
    deployment_id: storedString(item, "deployment_id", ID_PATTERN),
    request_sha256: storedString(item, "request_sha256", SHA256_PATTERN),
    worker_image_digest: storedString(item, "worker_image_digest", NAMED_SHA256_PATTERN),
    artifact_manifest_digest: storedString(item, "artifact_manifest_digest", NAMED_SHA256_PATTERN),
    bootstrap_endpoint: requireHttpsEndpoint(storedString(item, "bootstrap_endpoint", /^.+$/)),
    account_id: storedString(item, "account_id", ACCOUNT_ID_PATTERN),
    region: storedString(item, "region", REGION_PATTERN),
    expected_ami_id: storedString(item, "expected_ami_id", AMI_ID_PATTERN),
    expected_instance_type: storedString(item, "expected_instance_type", INSTANCE_TYPE_PATTERN),
    expected_architecture: storedString(item, "expected_architecture", ARCHITECTURE_PATTERN),
    expected_vpc_id: storedString(item, "expected_vpc_id", VPC_ID_PATTERN),
    expected_subnet_id: storedString(item, "expected_subnet_id", SUBNET_ID_PATTERN),
    expected_availability_zone: storedString(item, "expected_availability_zone", AVAILABILITY_ZONE_PATTERN),
    expected_security_group_id: storedString(item, "expected_security_group_id", SECURITY_GROUP_ID_PATTERN),
    state,
    expires_at: expiresAt,
    ttl_epoch_seconds: ttlEpochSeconds,
    issued_at: storedInstant(item, "issued_at"),
    updated_at: storedInstant(item, "updated_at"),
    lease_epoch: storedNonnegativeInteger(item, "lease_epoch"),
    last_sequence: storedNonnegativeInteger(item, "last_sequence"),
  };
  const expectedInstanceId = storedOptionalString(item, "expected_instance_id", INSTANCE_ID_PATTERN);
  const leaseExpiresAt = item?.lease_expires_at === undefined ? undefined : storedInstant(item, "lease_expires_at");
  const tokenSHA256 = storedOptionalString(item, "token_sha256", SHA256_PATTERN);
  const lastEventSHA256 = storedOptionalString(item, "last_event_sha256", SHA256_PATTERN);
  const lastEventJSON = storedOptionalString(item, "last_event_json", /^.{1,16384}$/s);
  const lastEventAt = item?.last_event_at === undefined ? undefined : storedInstant(item, "last_event_at");
  if (lastEventJSON !== undefined && Buffer.byteLength(lastEventJSON, "utf8") > MAX_EVENT_JSON_BYTES) {
    fail("worker_session_store_invalid", "stored worker event state is invalid", 500);
  }

  if (state === "issued") {
    if (expectedInstanceId !== undefined || session.lease_epoch !== 0 || session.last_sequence !== 0
      || leaseExpiresAt !== undefined || tokenSHA256 !== undefined || lastEventSHA256 !== undefined
      || lastEventJSON !== undefined || lastEventAt !== undefined) {
      fail("worker_session_store_invalid", "stored issued worker session is invalid", 500);
    }
    return session;
  }

  if (expectedInstanceId === undefined) {
    fail("worker_session_store_invalid", "stored bound worker session is invalid", 500);
  }
  session.expected_instance_id = expectedInstanceId;
  if (state === "bound") {
    storedInstant(item, "bound_at");
    if (session.lease_epoch !== 0 || session.last_sequence !== 0 || leaseExpiresAt !== undefined
      || tokenSHA256 !== undefined || lastEventSHA256 !== undefined || lastEventJSON !== undefined || lastEventAt !== undefined) {
      fail("worker_session_store_invalid", "stored bound worker session is invalid", 500);
    }
    return session;
  }

  if (session.lease_epoch < 1 || leaseExpiresAt === undefined || tokenSHA256 === undefined) {
    fail("worker_session_store_invalid", "stored active worker session is invalid", 500);
  }
  storedInstant(item, "bound_at");
  storedInstant(item, "claimed_at");
  if (Date.parse(leaseExpiresAt) > Date.parse(session.expires_at)) {
    fail("worker_session_store_invalid", "stored worker lease is invalid", 500);
  }
  if (session.last_sequence === 0) {
    if (lastEventSHA256 !== undefined || lastEventJSON !== undefined || lastEventAt !== undefined) {
      fail("worker_session_store_invalid", "stored worker event state is invalid", 500);
    }
  } else {
    if (lastEventSHA256 === undefined || lastEventJSON === undefined || lastEventAt === undefined
      || createHash("sha256").update(lastEventJSON, "utf8").digest("hex") !== lastEventSHA256) {
      fail("worker_session_store_invalid", "stored worker event state is invalid", 500);
    }
    let event;
    try {
      event = parseWorkerSessionEvent(lastEventJSON);
    } catch {
      fail("worker_session_store_invalid", "stored worker event state is invalid", 500);
    }
    if (event.connection_id !== session.connection_id || event.deployment_id !== session.deployment_id
      || event.bootstrap_session_id !== session.bootstrap_session_id || event.lease_epoch !== session.lease_epoch
      || event.sequence !== session.last_sequence || workerSessionEventSHA256(event) !== lastEventSHA256) {
      fail("worker_session_store_invalid", "stored worker event state is invalid", 500);
    }
  }
  return {
    ...session,
    lease_expires_at: leaseExpiresAt,
    token_sha256: tokenSHA256,
    ...(lastEventSHA256 ? {
      last_event_sha256: lastEventSHA256,
      last_event_json: lastEventJSON,
      last_event_at: lastEventAt,
    } : {}),
  };
}

function validateIssueInput(input, nowMs) {
  if (!isRecord(input)) fail("worker_session_invalid", "worker session issue is invalid", 500);
  const normalized = {
    bootstrap_session_id: requireString(input.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN),
    connection_id: requireString(input.connection_id, "connection_id", ID_PATTERN),
    deployment_id: requireString(input.deployment_id, "deployment_id", ID_PATTERN),
    request_sha256: requireString(input.request_sha256, "request_sha256", SHA256_PATTERN),
    worker_image_digest: requireString(input.worker_image_digest, "worker_image_digest", NAMED_SHA256_PATTERN),
    artifact_manifest_digest: requireString(input.artifact_manifest_digest, "artifact_manifest_digest", NAMED_SHA256_PATTERN),
    bootstrap_endpoint: requireHttpsEndpoint(input.bootstrap_endpoint),
    account_id: requireString(input.account_id, "account_id", ACCOUNT_ID_PATTERN),
    region: requireString(input.region, "region", REGION_PATTERN),
    expected_ami_id: requireString(input.expected_ami_id, "expected_ami_id", AMI_ID_PATTERN),
    expected_instance_type: requireString(input.expected_instance_type, "expected_instance_type", INSTANCE_TYPE_PATTERN),
    expected_architecture: requireString(input.expected_architecture, "expected_architecture", ARCHITECTURE_PATTERN),
    expected_vpc_id: requireString(input.expected_vpc_id, "expected_vpc_id", VPC_ID_PATTERN),
    expected_subnet_id: requireString(input.expected_subnet_id, "expected_subnet_id", SUBNET_ID_PATTERN),
    expected_availability_zone: requireString(input.expected_availability_zone, "expected_availability_zone", AVAILABILITY_ZONE_PATTERN),
    expected_security_group_id: requireString(input.expected_security_group_id, "expected_security_group_id", SECURITY_GROUP_ID_PATTERN),
    expires_at: input.expires_at,
  };
  const expiresAtMs = parseCanonicalInstant(normalized.expires_at, "expires_at");
  if (expiresAtMs <= nowMs) {
    fail("worker_session_expired", "worker bootstrap session has expired", 409);
  }
  if (expiresAtMs - nowMs > WORKER_SESSION_MAX_LEASE_LIFETIME_MS) {
    fail("worker_session_invalid", "worker bootstrap session lifetime is invalid", 500);
  }
  return normalized;
}

function validateBindInput(input) {
  if (!isRecord(input)) fail("worker_session_invalid", "worker session bind is invalid", 500);
  return {
    session_id: requireString(input.session_id, "session_id", ID_PATTERN),
    request_sha256: requireString(input.request_sha256, "request_sha256", SHA256_PATTERN),
    instance_id: requireString(input.instance_id, "instance_id", INSTANCE_ID_PATTERN),
    ...(input.security_group_id === undefined ? {} : {
      security_group_id: requireString(input.security_group_id, "security_group_id", SECURITY_GROUP_ID_PATTERN),
    }),
  };
}

function validateClaimInput(input, nowMs, session) {
  if (!isRecord(input)) fail("worker_session_invalid", "worker session claim is invalid", 500);
  const normalized = {
    session_id: requireString(input.session_id, "session_id", ID_PATTERN),
    instance_id: requireString(input.instance_id, "instance_id", INSTANCE_ID_PATTERN),
    token_sha256: requireString(input.token_sha256, "token_sha256", SHA256_PATTERN),
    lease_expires_at: input.lease_expires_at,
  };
  const leaseExpiresAtMs = parseCanonicalInstant(normalized.lease_expires_at, "lease_expires_at");
  if (leaseExpiresAtMs <= nowMs || leaseExpiresAtMs > Date.parse(session.expires_at)) {
    fail("worker_session_expired", "worker session lease is outside the bootstrap session lifetime", 409);
  }
  return normalized;
}

function validateEventInput(input) {
  if (!isRecord(input)) fail("worker_session_invalid", "worker event write is invalid", 500);
  const sessionId = requireString(input.session_id, "session_id", ID_PATTERN);
  const tokenSHA256 = requireString(input.token_sha256, "token_sha256", SHA256_PATTERN);
  const leaseEpoch = requirePositiveSafeInteger(input.lease_epoch, "lease_epoch");
  const sequence = requirePositiveSafeInteger(input.sequence, "sequence");
  const eventSHA256 = requireString(input.event_sha256, "event_sha256", SHA256_PATTERN);
  if (typeof input.event_json !== "string" || Buffer.byteLength(input.event_json, "utf8") === 0
    || Buffer.byteLength(input.event_json, "utf8") > MAX_EVENT_JSON_BYTES) {
    fail("worker_session_invalid", "event_json is invalid", 500);
  }
  const event = parseWorkerSessionEvent(input.event_json);
  const eventJSON = JSON.stringify(event);
  if (eventJSON !== input.event_json || event.bootstrap_session_id !== sessionId || event.lease_epoch !== leaseEpoch
    || event.sequence !== sequence || workerSessionEventSHA256(event) !== eventSHA256) {
    fail("worker_session_invalid", "worker event binding is invalid", 500);
  }
  return {
    session_id: sessionId,
    connection_id: event.connection_id,
    deployment_id: event.deployment_id,
    token_sha256: tokenSHA256,
    lease_epoch: leaseEpoch,
    sequence,
    event_sha256: eventSHA256,
    event_json: eventJSON,
  };
}

function sessionNow(nowMs) {
  requireSafeNonnegativeInteger(nowMs, "clock", "worker_session_invalid", 500);
  const instant = new Date(nowMs).toISOString();
  parseCanonicalInstant(instant, "clock", "worker_session_invalid", 500);
  return instant;
}

function issueItem(input, now) {
  return {
    bootstrap_session_id: { S: input.bootstrap_session_id },
    connection_id: { S: input.connection_id },
    deployment_id: { S: input.deployment_id },
    request_sha256: { S: input.request_sha256 },
    worker_image_digest: { S: input.worker_image_digest },
    artifact_manifest_digest: { S: input.artifact_manifest_digest },
    bootstrap_endpoint: { S: input.bootstrap_endpoint },
    account_id: { S: input.account_id },
    region: { S: input.region },
    expected_ami_id: { S: input.expected_ami_id },
    expected_instance_type: { S: input.expected_instance_type },
    expected_architecture: { S: input.expected_architecture },
    expected_vpc_id: { S: input.expected_vpc_id },
    expected_subnet_id: { S: input.expected_subnet_id },
    expected_availability_zone: { S: input.expected_availability_zone },
    expected_security_group_id: { S: input.expected_security_group_id },
    state: { S: "issued" },
    expires_at: { S: input.expires_at },
    ttl_epoch_seconds: { N: String(Math.ceil(Date.parse(input.expires_at) / 1000)) },
    issued_at: { S: now },
    updated_at: { S: now },
    lease_epoch: { N: "0" },
    last_sequence: { N: "0" },
  };
}

// A retry may recompute a candidate expiry after RunInstances accepted its
// ClientToken but before the broker recorded its response. The first durable
// session expiry is therefore part of the immutable EC2 request material: a
// same-binding retry must reuse it rather than turn the recovery into a
// conflict or regenerate different UserData.
function sameSessionBinding(session, input) {
  return session.bootstrap_session_id === input.bootstrap_session_id
    && session.connection_id === input.connection_id
    && session.deployment_id === input.deployment_id
    && session.request_sha256 === input.request_sha256
    && session.worker_image_digest === input.worker_image_digest
    && session.artifact_manifest_digest === input.artifact_manifest_digest
    && session.bootstrap_endpoint === input.bootstrap_endpoint
    && session.account_id === input.account_id
    && session.region === input.region
    && session.expected_ami_id === input.expected_ami_id
    && session.expected_instance_type === input.expected_instance_type
    && session.expected_architecture === input.expected_architecture
    && session.expected_vpc_id === input.expected_vpc_id
    && session.expected_subnet_id === input.expected_subnet_id
    && session.expected_availability_zone === input.expected_availability_zone
    && session.expected_security_group_id === input.expected_security_group_id;
}

// DynamoWorkerSessionStore is the durable, Stack-owned session fence between a
// newly created dedicated EC2 Worker and the broker. It stores only SHA-256
// bearer-token hashes, uses consistent reads after conditional writes, and
// never treats VM-reported state as proof of instance identity.
export class DynamoWorkerSessionStore {
  constructor({
    client,
    workerSessionsTableName,
    GetItemCommand,
    PutItemCommand,
    UpdateItemCommand,
    nowMs,
  }) {
    if (!client?.send || typeof workerSessionsTableName !== "string" || workerSessionsTableName.length === 0
      || !GetItemCommand || !PutItemCommand || !UpdateItemCommand || typeof nowMs !== "function") {
      throw new TypeError("DynamoDB client, Worker session table, commands, and clock are required");
    }
    this.client = client;
    this.workerSessionsTableName = workerSessionsTableName;
    this.GetItemCommand = GetItemCommand;
    this.PutItemCommand = PutItemCommand;
    this.UpdateItemCommand = UpdateItemCommand;
    this.nowMs = nowMs;
  }

  async get(sessionId) {
    requireString(sessionId, "session_id", ID_PATTERN, "worker_session_invalid", 500);
    return this.#read(sessionId);
  }

  async issue(input) {
    const now = sessionNow(this.nowMs());
    const normalized = validateIssueInput(input, Date.parse(now));
    try {
      await this.client.send(new this.PutItemCommand({
        TableName: this.workerSessionsTableName,
        Item: issueItem(normalized, now),
        ConditionExpression: "attribute_not_exists(bootstrap_session_id)",
      }));
      return {
        ...normalized,
        state: "issued",
        ttl_epoch_seconds: Math.ceil(Date.parse(normalized.expires_at) / 1000),
        issued_at: now,
        updated_at: now,
        lease_epoch: 0,
        last_sequence: 0,
      };
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("worker_session_unavailable", "worker session storage is unavailable", 503);
      }
    }
    const existing = await this.#read(normalized.bootstrap_session_id);
    if (!existing) fail("worker_session_unavailable", "worker session storage could not reconcile its conditional write", 503);
    if (!sameSessionBinding(existing, normalized)) {
      fail("worker_session_conflict", "bootstrap session id is already bound to another Worker", 409);
    }
    if (Date.parse(existing.expires_at) <= Date.parse(now)) {
      fail("worker_session_expired", "worker bootstrap session has expired", 409);
    }
    return existing;
  }

  async bind(input) {
    const now = sessionNow(this.nowMs());
    const normalized = validateBindInput(input);
    try {
      const output = await this.client.send(new this.UpdateItemCommand({
        TableName: this.workerSessionsTableName,
        Key: sessionKey(normalized.session_id),
        ConditionExpression: `request_sha256 = :request_sha256 AND #state = :issued AND expires_at > :now AND attribute_not_exists(expected_instance_id)${normalized.security_group_id ? " AND expected_security_group_id = :security_group_id" : ""}`,
        UpdateExpression: "SET #state = :bound, expected_instance_id = :instance_id, bound_at = :now, updated_at = :now",
        ExpressionAttributeNames: { "#state": "state" },
        ExpressionAttributeValues: {
          ":request_sha256": { S: normalized.request_sha256 },
          ":issued": { S: "issued" },
          ":bound": { S: "bound" },
          ":instance_id": { S: normalized.instance_id },
          ":now": { S: now },
          ...(normalized.security_group_id ? { ":security_group_id": { S: normalized.security_group_id } } : {}),
        },
        ReturnValues: "ALL_NEW",
      }));
      return parseStoredSession(output?.Attributes, normalized.session_id);
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("worker_session_unavailable", "worker session storage is unavailable", 503);
      }
    }
    const existing = await this.#read(normalized.session_id);
    if (!existing) fail("worker_session_unavailable", "worker session storage could not reconcile its conditional write", 503);
    if (existing.request_sha256 !== normalized.request_sha256) {
      fail("worker_session_conflict", "bootstrap session is bound to another deployment request", 409);
    }
    if (Date.parse(existing.expires_at) <= Date.parse(now)) {
      fail("worker_session_expired", "worker bootstrap session has expired", 409);
    }
    if (existing.expected_instance_id === normalized.instance_id && ["bound", "active"].includes(existing.state)) {
      return existing;
    }
    fail("worker_session_conflict", "bootstrap session is already bound to another Worker", 409);
  }

  async claim(input) {
    const now = sessionNow(this.nowMs());
    if (!isRecord(input)) fail("worker_session_invalid", "worker session claim is invalid", 500);
    const sessionId = requireString(input.session_id, "session_id", ID_PATTERN);
    const before = await this.#read(sessionId);
    if (!before) fail("worker_session_unavailable", "worker bootstrap session is unavailable", 503);
    const normalized = validateClaimInput(input, Date.parse(now), before);
    if (before.expected_instance_id !== normalized.instance_id) {
      fail("worker_session_claim_conflict", "Worker instance does not match its bootstrap session", 409);
    }
    try {
      const output = await this.client.send(new this.UpdateItemCommand({
        TableName: this.workerSessionsTableName,
        Key: sessionKey(normalized.session_id),
        ConditionExpression: "expected_instance_id = :instance_id AND #state IN (:bound, :active) AND expires_at > :now",
        UpdateExpression: "SET #state = :active, lease_epoch = lease_epoch + :one, lease_expires_at = :lease_expires_at, token_sha256 = :token_sha256, last_sequence = :zero, claimed_at = :now, updated_at = :now REMOVE last_event_sha256, last_event_json, last_event_at",
        ExpressionAttributeNames: { "#state": "state" },
        ExpressionAttributeValues: {
          ":instance_id": { S: normalized.instance_id },
          ":bound": { S: "bound" },
          ":active": { S: "active" },
          ":zero": { N: "0" },
          ":one": { N: "1" },
          ":lease_expires_at": { S: normalized.lease_expires_at },
          ":token_sha256": { S: normalized.token_sha256 },
          ":now": { S: now },
        },
        ReturnValues: "ALL_NEW",
      }));
      return parseStoredSession(output?.Attributes, normalized.session_id);
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("worker_session_unavailable", "worker session storage is unavailable", 503);
      }
    }
    const existing = await this.#read(normalized.session_id);
    if (!existing) fail("worker_session_unavailable", "worker session storage could not reconcile its conditional write", 503);
    if (Date.parse(existing.expires_at) <= Date.parse(now)) {
      fail("worker_session_expired", "worker bootstrap session has expired", 409);
    }
    if (existing.expected_instance_id !== normalized.instance_id || !["bound", "active"].includes(existing.state)) {
      fail("worker_session_claim_conflict", "Worker instance does not match its bootstrap session", 409);
    }
    fail("worker_session_unavailable", "worker session claim could not reconcile its conditional write", 503);
  }

  async recordEvent(input) {
    const now = sessionNow(this.nowMs());
    const normalized = validateEventInput(input);
    const previousSequence = normalized.sequence - 1;
    try {
      await this.client.send(new this.UpdateItemCommand({
        TableName: this.workerSessionsTableName,
        Key: sessionKey(normalized.session_id),
        ConditionExpression: "connection_id = :connection_id AND deployment_id = :deployment_id AND #state = :active AND token_sha256 = :token_sha256 AND lease_epoch = :lease_epoch AND lease_expires_at > :now AND last_sequence = :previous_sequence",
        UpdateExpression: "SET last_sequence = :sequence, last_event_sha256 = :event_sha256, last_event_json = :event_json, last_event_at = :now, updated_at = :now",
        ExpressionAttributeNames: { "#state": "state" },
        ExpressionAttributeValues: {
          ":active": { S: "active" },
          ":connection_id": { S: normalized.connection_id },
          ":deployment_id": { S: normalized.deployment_id },
          ":token_sha256": { S: normalized.token_sha256 },
          ":lease_epoch": { N: String(normalized.lease_epoch) },
          ":now": { S: now },
          ":previous_sequence": { N: String(previousSequence) },
          ":sequence": { N: String(normalized.sequence) },
          ":event_sha256": { S: normalized.event_sha256 },
          ":event_json": { S: normalized.event_json },
        },
      }));
      return { disposition: "accepted" };
    } catch (error) {
      if (!conditionalFailure(error)) {
        fail("worker_session_unavailable", "worker session storage is unavailable", 503);
      }
    }
    const existing = await this.#read(normalized.session_id);
    if (!existing) fail("worker_session_unavailable", "worker session storage could not reconcile its conditional write", 503);
    if (Date.parse(existing.expires_at) <= Date.parse(now) || (existing.lease_expires_at !== undefined && Date.parse(existing.lease_expires_at) <= Date.parse(now))) {
      fail("worker_session_expired", "worker session lease has expired", 409);
    }
    if (existing.connection_id !== normalized.connection_id || existing.deployment_id !== normalized.deployment_id
      || existing.state !== "active" || existing.token_sha256 !== normalized.token_sha256 || existing.lease_epoch !== normalized.lease_epoch) {
      fail("worker_session_unauthorized", "worker event bearer is invalid", 401);
    }
    if (existing.last_sequence === normalized.sequence && existing.last_event_sha256 === normalized.event_sha256) {
      return { disposition: "idempotent" };
    }
    fail("worker_event_conflict", "worker event sequence is not the next durable event", 409);
  }

  async #read(sessionId) {
    let output;
    try {
      output = await this.client.send(new this.GetItemCommand({
        TableName: this.workerSessionsTableName,
        ConsistentRead: true,
        Key: sessionKey(sessionId),
      }));
    } catch {
      fail("worker_session_unavailable", "worker session storage is unavailable", 503);
    }
    if (!output?.Item) return undefined;
    return parseStoredSession(output.Item, sessionId);
  }
}
