import {
  createHash,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  WORKER_EVENT_RECEIPT_V1_SCHEMA,
  WORKER_SESSION_CLAIM_RESPONSE_V1_SCHEMA,
  WORKER_SESSION_MAX_LEASE_LIFETIME_MS,
  parseWorkerSessionClaim,
  parseWorkerSessionEvent,
  workerSessionEventSHA256,
} from "./worker-session-contract.mjs";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

function fail(code, message, statusCode = 400) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function requireString(value, field, pattern, code = "worker_session_invalid", statusCode = 409) {
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requireSafeMilliseconds(value, field) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail("worker_session_invalid", `${field} is invalid`, 500);
  }
  return value;
}

function parseCanonicalInstant(value, field, code = "worker_session_invalid", statusCode = 409) {
  if (typeof value !== "string" || !ISO_INSTANT_PATTERN.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return milliseconds;
}

function opaqueToken(value) {
  if (typeof value !== "string" || value.length < 16 || value.length > 4096 || value.trim() !== value) {
    fail("worker_session_invalid", "generated worker access token is invalid", 500);
  }
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint < 0x21 || codePoint > 0x7e || character === '"' || character === "\\") {
      fail("worker_session_invalid", "generated worker access token is invalid", 500);
    }
  }
  return value;
}

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function sameHash(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || !SHA256_PATTERN.test(left) || !SHA256_PATTERN.test(right)) {
    return false;
  }
  return timingSafeEqual(Buffer.from(left, "ascii"), Buffer.from(right, "ascii"));
}

function knownStoreError(error) {
  if (error instanceof ConnectionStackV2Error) return error;
  switch (error?.code) {
    case "worker_session_invalid":
      return new ConnectionStackV2Error(error.code, "worker session is invalid", 409);
    case "worker_session_expired":
    case "worker_session_unauthorized":
      return new ConnectionStackV2Error(error.code, "worker session is unauthorized", 401);
    case "worker_event_conflict":
    case "worker_session_conflict":
    case "worker_session_claim_conflict":
      return new ConnectionStackV2Error(error.code, "worker session state conflicts", 409);
    default:
      return undefined;
  }
}

async function callStore(operation) {
  try {
    return await operation();
  } catch (error) {
    const known = knownStoreError(error);
    if (known) throw known;
    fail("worker_session_unavailable", "worker session storage is unavailable", 503);
  }
}

async function verifyIdentity(identityVerifier, claim, session) {
  try {
    return await identityVerifier.verify(claim, session);
  } catch (error) {
    const known = knownStoreError(error);
    if (known) throw known;
    fail("worker_identity_unavailable", "worker identity verification is unavailable", 503);
  }
}

function validateSession(session, {
  sessionId,
  claim,
  nowMs,
  requireActive = false,
  allowExpiredActive = false,
} = {}) {
  if (!session || typeof session !== "object" || Array.isArray(session)) {
    fail("worker_session_invalid", "worker session is invalid", 409);
  }
  const bootstrapSessionID = requireString(session.bootstrap_session_id, "bootstrap_session_id", ID_PATTERN);
  const connectionID = requireString(session.connection_id, "connection_id", ID_PATTERN);
  const deploymentID = requireString(session.deployment_id, "deployment_id", ID_PATTERN);
  const workerImageDigest = requireString(session.worker_image_digest, "worker_image_digest", NAMED_SHA256_PATTERN);
  const artifactManifestDigest = requireString(session.artifact_manifest_digest, "artifact_manifest_digest", NAMED_SHA256_PATTERN);
  const expiresAtMs = parseCanonicalInstant(session.expires_at, "expires_at");
  if (bootstrapSessionID !== sessionId || (claim && (
    claim.bootstrap_session_id !== bootstrapSessionID
    || claim.connection_id !== connectionID
    || claim.deployment_id !== deploymentID
    || claim.worker_image_digest !== workerImageDigest
    || claim.artifact_manifest_digest !== artifactManifestDigest
  ))) {
    fail("worker_session_invalid", "worker session does not bind this request", 409);
  }
  const allowedStates = requireActive ? new Set(["active"]) : new Set(["bound", "active"]);
  if (!allowedStates.has(session.state)) {
    fail("worker_session_invalid", "worker session is not bound to an EC2 instance", 409);
  }
  if (expiresAtMs <= nowMs && !(allowExpiredActive && session.state === "active")) {
    fail("worker_session_expired", "worker session has expired", 401);
  }
  const expectedInstanceID = requireString(session.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN);
  const leaseEpoch = session.lease_epoch ?? 0;
  if (!Number.isSafeInteger(leaseEpoch) || leaseEpoch < 0) {
    fail("worker_session_invalid", "lease_epoch is invalid", 409);
  }
  const lastSequence = session.last_sequence ?? 0;
  if (!Number.isSafeInteger(lastSequence) || lastSequence < 0) {
    fail("worker_session_invalid", "last_sequence is invalid", 409);
  }
  return {
    ...session,
    bootstrap_session_id: bootstrapSessionID,
    connection_id: connectionID,
    deployment_id: deploymentID,
    worker_image_digest: workerImageDigest,
    artifact_manifest_digest: artifactManifestDigest,
    expected_instance_id: expectedInstanceID,
    expires_at_ms: expiresAtMs,
    lease_epoch: leaseEpoch,
    last_sequence: lastSequence,
  };
}

function requireAuthorizationToken(authorization) {
  if (typeof authorization !== "string" || !authorization.startsWith("Bearer ")) {
    fail("worker_session_unauthorized", "worker bearer token is required", 401);
  }
  const token = authorization.slice("Bearer ".length);
  if (token.length === 0 || token.includes(" ") || token.includes("\t") || token.includes("\r") || token.includes("\n")) {
    fail("worker_session_unauthorized", "worker bearer token is invalid", 401);
  }
  return token;
}

function claimResponse(session, token) {
  return {
    schema: WORKER_SESSION_CLAIM_RESPONSE_V1_SCHEMA,
    connection_id: session.connection_id,
    deployment_id: session.deployment_id,
    bootstrap_session_id: session.bootstrap_session_id,
    lease_epoch: session.lease_epoch,
    lease_expires_at: session.lease_expires_at,
    access_token: token,
  };
}

function eventReceipt(event, disposition) {
  if (disposition !== "accepted" && disposition !== "idempotent") {
    fail("worker_session_invalid", "worker event store returned an invalid disposition", 500);
  }
  return {
    schema: WORKER_EVENT_RECEIPT_V1_SCHEMA,
    connection_id: event.connection_id,
    deployment_id: event.deployment_id,
    bootstrap_session_id: event.bootstrap_session_id,
    lease_epoch: event.lease_epoch,
    sequence: event.sequence,
    disposition,
  };
}

// WorkerSessionService is the Stack-side capability gate for an already-bound,
// dedicated Worker. It deliberately issues its short-lived bearer only after
// the Stack verifies the IMDS IID proof and independently reads the EC2
// instance. Tokens are never retained outside this response; Dynamo receives
// their SHA-256 only.
export class WorkerSessionService {
  constructor({
    store,
    identityVerifier,
    nowMs = Date.now,
    leaseDurationMs = 5 * 60 * 1000,
    createAccessToken = () => randomBytes(32).toString("base64url"),
  }) {
    if (!store || typeof store.get !== "function" || typeof store.claim !== "function" || typeof store.recordEvent !== "function"
      || !identityVerifier || typeof identityVerifier.verify !== "function" || typeof nowMs !== "function" || typeof createAccessToken !== "function"
      || !Number.isSafeInteger(leaseDurationMs) || leaseDurationMs < 1 || leaseDurationMs > WORKER_SESSION_MAX_LEASE_LIFETIME_MS) {
      throw new TypeError("worker session store, identity verifier, clock, and bounded lease are required");
    }
    this.store = store;
    this.identityVerifier = identityVerifier;
    this.nowMs = nowMs;
    this.leaseDurationMs = leaseDurationMs;
    this.createAccessToken = createAccessToken;
  }

  async claim(sessionId, rawClaim) {
    const claim = parseWorkerSessionClaim(rawClaim);
    if (sessionId !== claim.bootstrap_session_id) {
      fail("worker_session_invalid", "worker session path does not match the claim", 409);
    }
    const nowMs = requireSafeMilliseconds(this.nowMs(), "clock");
    const current = validateSession(await callStore(() => this.store.get(sessionId)), {
      sessionId,
      claim,
      nowMs,
      allowExpiredActive: true,
    });
    const identity = await verifyIdentity(this.identityVerifier, claim, current);
    if (!identity || identity.instance_id !== current.expected_instance_id) {
      fail("worker_identity_invalid", "worker identity does not match its issued session", 401);
    }
    const token = opaqueToken(this.createAccessToken());
    const leaseExpiresAtMs = current.state === "active"
      ? nowMs + this.leaseDurationMs
      : Math.min(nowMs + this.leaseDurationMs, current.expires_at_ms);
    if (leaseExpiresAtMs <= nowMs) {
      fail("worker_session_expired", "worker session has expired", 401);
    }
    const leaseExpiresAt = new Date(leaseExpiresAtMs).toISOString();
    const tokenSHA256 = sha256(token);
    const claimed = await callStore(() => this.store.claim({
      session_id: current.bootstrap_session_id,
      instance_id: current.expected_instance_id,
      token_sha256: tokenSHA256,
      lease_expires_at: leaseExpiresAt,
      now_ms: nowMs,
    }));
    const normalized = validateSession(claimed, {
      sessionId,
      claim,
      nowMs,
      requireActive: true,
      allowExpiredActive: true,
    });
    if (normalized.expected_instance_id !== current.expected_instance_id || normalized.lease_expires_at !== leaseExpiresAt
      || !sameHash(normalized.token_sha256, tokenSHA256) || !Number.isSafeInteger(normalized.lease_epoch) || normalized.lease_epoch < 1) {
      fail("worker_session_invalid", "worker session claim storage result is invalid", 500);
    }
    return claimResponse(normalized, token);
  }

  // authorize is the shared active-Worker capability check used by both the
  // legacy bounded session-event route and the separate Worker task transport.
  // It deliberately returns only a token hash and verified session binding;
  // callers never receive or persist the bearer itself.
  async authorize(sessionId, authorization, { leaseEpoch } = {}) {
    const nowMs = requireSafeMilliseconds(this.nowMs(), "clock");
    const current = validateSession(await callStore(() => this.store.get(sessionId)), {
      sessionId,
      nowMs,
      requireActive: true,
      allowExpiredActive: true,
    });
    if (leaseEpoch !== undefined && (!Number.isSafeInteger(leaseEpoch) || leaseEpoch < 1 || leaseEpoch !== current.lease_epoch)) {
      fail("worker_session_unauthorized", "worker request does not bind the active session lease", 401);
    }
    const leaseExpiresAtMs = parseCanonicalInstant(current.lease_expires_at, "lease_expires_at", "worker_session_invalid", 500);
    if (leaseExpiresAtMs <= nowMs) {
      fail("worker_session_expired", "worker session lease has expired", 401);
    }
    const tokenSHA256 = sha256(requireAuthorizationToken(authorization));
    if (!sameHash(tokenSHA256, current.token_sha256)) {
      fail("worker_session_unauthorized", "worker bearer token is unauthorized", 401);
    }
    return {
      session: current,
      token_sha256: tokenSHA256,
      now_ms: nowMs,
    };
  }

  async event(sessionId, authorization, rawEvent) {
    const event = parseWorkerSessionEvent(rawEvent);
    if (sessionId !== event.bootstrap_session_id) {
      fail("worker_session_invalid", "worker session path does not match the event", 409);
    }
    const authorizationContext = await this.authorize(sessionId, authorization, { leaseEpoch: event.lease_epoch });
    const current = authorizationContext.session;
    if (event.connection_id !== current.connection_id || event.deployment_id !== current.deployment_id) {
      fail("worker_session_unauthorized", "worker event does not bind the active session lease", 401);
    }
    const recorded = await callStore(() => this.store.recordEvent({
      session_id: current.bootstrap_session_id,
      token_sha256: authorizationContext.token_sha256,
      lease_epoch: event.lease_epoch,
      sequence: event.sequence,
      event_sha256: workerSessionEventSHA256(event),
      event_json: JSON.stringify(event),
      now_ms: authorizationContext.now_ms,
    }));
    return eventReceipt(event, recorded?.disposition);
  }
}
