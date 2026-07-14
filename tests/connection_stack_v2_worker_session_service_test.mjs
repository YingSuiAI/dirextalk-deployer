import assert from "node:assert/strict";

import {
  WorkerSessionService,
} from "../scripts/connection-stack-v2/src/worker-session-service.mjs";

const NOW = Date.parse("2026-07-15T01:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const DEPLOYMENT_ID = "deployment-v2-001";
const SESSION_ID = "worker-session-v2-001";
const DIGEST = `sha256:${"a".repeat(64)}`;
const IDENTITY = {
  account_id: "123456789012",
  region: "ap-northeast-1",
  instance_id: "i-0123456789abcdef0",
  image_id: "ami-0123456789abcdef0",
  availability_zone: "ap-northeast-1a",
  instance_type: "t3.large",
  architecture: "x86_64",
};

function claim() {
  return {
    schema: "dirextalk.worker-session-claim/v1",
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    worker_image_digest: DIGEST,
    artifact_manifest_digest: DIGEST,
    instance_identity_document_b64: Buffer.from("signed-iid-document", "utf8").toString("base64"),
    instance_identity_signature_b64: Buffer.from("signed-iid-signature", "utf8").toString("base64"),
  };
}

function heartbeat(epoch, sequence) {
  return {
    schema: "dirextalk.worker-event/v1",
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    bootstrap_session_id: SESSION_ID,
    lease_epoch: epoch,
    sequence,
    kind: "heartbeat",
    occurred_at: "2026-07-15T01:00:00.000Z",
  };
}

class MemorySessionStore {
  constructor(session) {
    this.session = structuredClone(session);
    this.claims = [];
    this.events = [];
  }

  async get(sessionID) {
    return sessionID === this.session.bootstrap_session_id ? structuredClone(this.session) : undefined;
  }

  async claim(input) {
    this.claims.push(structuredClone(input));
    if (input.session_id !== this.session.bootstrap_session_id || input.instance_id !== this.session.expected_instance_id) {
      throw Object.assign(new Error("unexpected claim"), { code: "worker_session_invalid" });
    }
    this.session.state = "active";
    this.session.lease_epoch = (this.session.lease_epoch ?? 0) + 1;
    this.session.lease_expires_at = input.lease_expires_at;
    this.session.token_sha256 = input.token_sha256;
    this.session.last_sequence = 0;
    return structuredClone(this.session);
  }

  async recordEvent(input) {
    this.events.push(structuredClone(input));
    if (input.token_sha256 !== this.session.token_sha256 || input.lease_epoch !== this.session.lease_epoch) {
      throw Object.assign(new Error("unauthorized"), { code: "worker_session_unauthorized" });
    }
    if (input.sequence === this.session.last_sequence && input.event_sha256 === this.session.last_event_sha256) {
      return { disposition: "idempotent" };
    }
    if (input.sequence !== this.session.last_sequence + 1) {
      throw Object.assign(new Error("out of order"), { code: "worker_event_conflict" });
    }
    this.session.last_sequence = input.sequence;
    this.session.last_event_sha256 = input.event_sha256;
    return { disposition: "accepted" };
  }
}

const store = new MemorySessionStore({
  bootstrap_session_id: SESSION_ID,
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: "b".repeat(64),
  worker_image_digest: DIGEST,
  artifact_manifest_digest: DIGEST,
  bootstrap_endpoint: "https://a1b2c3d4e5.execute-api.ap-northeast-1.amazonaws.com/prod/v2/worker-sessions",
  account_id: IDENTITY.account_id,
  region: IDENTITY.region,
  expected_ami_id: IDENTITY.image_id,
  expected_instance_id: IDENTITY.instance_id,
  expected_instance_type: IDENTITY.instance_type,
  expected_architecture: IDENTITY.architecture,
  expected_availability_zone: IDENTITY.availability_zone,
  state: "bound",
  expires_at: "2026-07-15T01:10:00.000Z",
  last_sequence: 0,
});
const verified = [];
let tokenCounter = 0;
let currentNow = NOW;
const service = new WorkerSessionService({
  store,
  nowMs: () => currentNow,
  leaseDurationMs: 5 * 60 * 1000,
  createAccessToken: () => `worker-session-token-${++tokenCounter}-0123456789`,
  identityVerifier: {
    async verify(request, session) {
      verified.push({ request, session });
      return IDENTITY;
    },
  },
});

const firstClaim = await service.claim(SESSION_ID, claim());
assert.equal(firstClaim.schema, "dirextalk.worker-session-claim-response/v1");
assert.equal(firstClaim.connection_id, CONNECTION_ID);
assert.equal(firstClaim.deployment_id, DEPLOYMENT_ID);
assert.equal(firstClaim.bootstrap_session_id, SESSION_ID);
assert.equal(firstClaim.lease_epoch, 1);
assert.equal(firstClaim.lease_expires_at, "2026-07-15T01:05:00.000Z");
assert.equal(firstClaim.access_token, "worker-session-token-1-0123456789");
assert.equal(verified.length, 1, "IID verification precedes token issuance");
assert.equal(store.claims[0].token_sha256.length, 64);
assert.notEqual(store.claims[0].token_sha256, firstClaim.access_token, "the durable store receives only a token hash");

const token = firstClaim.access_token;
const firstHeartbeat = await service.event(SESSION_ID, `Bearer ${token}`, heartbeat(1, 1));
assert.deepEqual(firstHeartbeat, {
  schema: "dirextalk.worker-event-receipt/v1",
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  bootstrap_session_id: SESSION_ID,
  lease_epoch: 1,
  sequence: 1,
  disposition: "accepted",
});
const retryHeartbeat = await service.event(SESSION_ID, `Bearer ${token}`, heartbeat(1, 1));
assert.equal(retryHeartbeat.disposition, "idempotent", "the exact retry is safe after an indeterminate response");
await assert.rejects(
  () => service.event(SESSION_ID, `Bearer ${token}`, heartbeat(1, 3)),
  (error) => error?.code === "worker_event_conflict",
  "an out-of-order event must not advance progress",
);
await assert.rejects(
  () => service.event(SESSION_ID, "Bearer not-the-issued-token", heartbeat(1, 2)),
  (error) => error?.code === "worker_session_unauthorized",
  "a bearer token is scoped to its worker session",
);

const reclaimed = await service.claim(SESSION_ID, claim());
assert.equal(reclaimed.lease_epoch, 2, "a rebooted proven instance rotates the token and epoch without persisting a token on disk");
assert.notEqual(reclaimed.access_token, token);
await assert.rejects(
  () => service.event(SESSION_ID, `Bearer ${token}`, heartbeat(1, 2)),
  (error) => error?.code === "worker_session_unauthorized",
  "a rotated claim invalidates the old event token",
);
assert.equal((await service.event(SESSION_ID, `Bearer ${reclaimed.access_token}`, heartbeat(2, 1))).disposition, "accepted");

currentNow = Date.parse("2026-07-15T01:11:00.000Z");
const recoveredAfterBootstrapExpiry = await service.claim(SESSION_ID, claim());
assert.equal(recoveredAfterBootstrapExpiry.lease_epoch, 3, "an already IID-proven Worker may reauthenticate after the one-time bootstrap window");
assert.equal(recoveredAfterBootstrapExpiry.lease_expires_at, "2026-07-15T01:16:00.000Z");
assert.equal(verified.length, 3, "every recovery claim must independently re-verify the EC2 identity");
assert.equal(
  (await service.event(SESSION_ID, `Bearer ${recoveredAfterBootstrapExpiry.access_token}`, heartbeat(3, 1))).disposition,
  "accepted",
  "a valid renewed bearer can report after the one-time bootstrap window closes",
);
await assert.rejects(
  () => service.event(SESSION_ID, `Bearer ${reclaimed.access_token}`, heartbeat(2, 2)),
  (error) => error?.code === "worker_session_unauthorized",
  "a post-bootstrap recovery claim invalidates the prior bearer token",
);

const unclaimedExpiredStore = new MemorySessionStore({
  bootstrap_session_id: "worker-session-v2-002",
  connection_id: CONNECTION_ID,
  deployment_id: DEPLOYMENT_ID,
  request_sha256: "b".repeat(64),
  worker_image_digest: DIGEST,
  artifact_manifest_digest: DIGEST,
  bootstrap_endpoint: "https://a1b2c3d4e5.execute-api.ap-northeast-1.amazonaws.com/prod/v2/worker-sessions",
  account_id: IDENTITY.account_id,
  region: IDENTITY.region,
  expected_ami_id: IDENTITY.image_id,
  expected_instance_id: IDENTITY.instance_id,
  expected_instance_type: IDENTITY.instance_type,
  expected_architecture: IDENTITY.architecture,
  expected_availability_zone: IDENTITY.availability_zone,
  state: "bound",
  expires_at: "2026-07-15T01:10:00.000Z",
  last_sequence: 0,
});
let unclaimedIdentityChecks = 0;
const initialClaimAfterExpiry = new WorkerSessionService({
  store: unclaimedExpiredStore,
  nowMs: () => currentNow,
  createAccessToken: () => "worker-session-token-expired-0123456789",
  identityVerifier: { async verify() { unclaimedIdentityChecks += 1; return IDENTITY; } },
});
await assert.rejects(
  () => initialClaimAfterExpiry.claim("worker-session-v2-002", { ...claim(), bootstrap_session_id: "worker-session-v2-002" }),
  (error) => error?.code === "worker_session_expired",
  "an unclaimed bootstrap session remains unusable after its one-time window",
);
assert.equal(unclaimedIdentityChecks, 0, "an expired never-claimed session must be rejected before AWS identity read-back");

console.log("connection stack v2 worker session service boundary ok");
