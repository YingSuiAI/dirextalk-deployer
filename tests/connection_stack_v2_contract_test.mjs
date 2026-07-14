import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";

import {
  BROKER_V2_ACTIONS,
  ConnectionStackV2Error,
  buildApprovalSignatureBase,
  buildNodeSignatureBase,
  canonicalApprovalBindingDigest,
  createV2ChallengeApprovalService,
  validateAndAuthenticateV2Command,
  validateBootstrapIdentity,
} from "../scripts/connection-stack-v2/src/command-contract.mjs";
import {
  canonicalApprovalProofPayload,
} from "../scripts/connection-stack-v2/src/approval-proof.mjs";
import {
  validateWorkerBootstrapManifest,
} from "../scripts/connection-stack-v2/src/worker-contract.mjs";

const NOW = Date.parse("2026-07-14T07:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const NODE_KEY_ID = "node-key-v2";
const DEVICE_KEY_ID = "flutter-device-v2";
const DIGEST = (char) => `sha256:${char.repeat(64)}`;

const { privateKey: nodePrivateKey, publicKey: nodePublicKey } = generateKeyPairSync("ed25519");
const { privateKey: devicePrivateKey, publicKey: devicePublicKey } = generateKeyPairSync("ed25519");
const nodePublicKeySpkiBase64 = nodePublicKey.export({ type: "spki", format: "der" }).toString("base64");
const devicePublicKeySpkiBase64 = devicePublicKey.export({ type: "spki", format: "der" }).toString("base64");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function binding(overrides = {}) {
  return {
    schema: "dirextalk.aws.approval-binding/v2",
    connection_id: CONNECTION_ID,
    plan_hash: DIGEST("a"),
    plan_revision: 7,
    quote_id: "quote-v2-00001",
    recipe_digest: DIGEST("b"),
    manifest_digest: DIGEST("c"),
    resource_scope_digest: DIGEST("d"),
    network_scope_digest: DIGEST("e"),
    secret_scope_digest: DIGEST("f"),
    integration_scope_digest: DIGEST("0"),
    expires_at: "2026-07-14T07:04:00.000Z",
    ...overrides,
  };
}

function deviceApproval(approvalBinding, overrides = {}) {
  const approval = {
    schema: "dirextalk.aws.approval/v2",
    challenge_id: "challenge-v2-001",
    device_key_id: DEVICE_KEY_ID,
    binding_sha256: canonicalApprovalBindingDigest(approvalBinding),
    expires_at: approvalBinding.expires_at,
    signature_b64: "",
    ...overrides,
  };
  approval.signature_b64 = sign(
    null,
    Buffer.from(buildApprovalSignatureBase(approval, approvalBinding), "utf8"),
    devicePrivateKey,
  ).toString("base64");
  return approval;
}

function deploymentPayload(deploymentId, approvalBinding = binding()) {
  return {
    schema: "dirextalk.aws.deployment-create/v1",
    deployment_id: deploymentId,
    connection_generation: 3,
    plan_hash: approvalBinding.plan_hash,
    plan_revision: approvalBinding.plan_revision,
    quote_id: approvalBinding.quote_id,
    quote_digest: DIGEST("9"),
    candidate_id: "candidate-recommended-01",
    resource_manifest_digest: approvalBinding.manifest_digest,
    worker_artifact: {
      kind: "fixed_ami",
      ami_id: "ami-0123456789abcdef0",
    },
    network: {
      vpc_id: "vpc-0123456789abcdef0",
      subnet_id: "subnet-0123456789abcdef0",
      availability_zone: "ap-south-1a",
    },
  };
}

function approvalProof(approvalBinding, overrides = {}) {
  const proof = {
    schema_version: "cloud-orchestrator/v1",
    approval_id: "approval-proof-v2-01",
    challenge_id: "challenge-v2-001",
    signer_key_id: DEVICE_KEY_ID,
    plan_id: "plan-v2-0001",
    plan_hash: approvalBinding.plan_hash,
    plan_revision: approvalBinding.plan_revision,
    quote_id: approvalBinding.quote_id,
    quote_digest: DIGEST("9"),
    quote_valid_until: "2026-07-14T07:15:00Z",
    cloud_connection_id: CONNECTION_ID,
    recipe_digest: approvalBinding.recipe_digest,
    resource_scope: {
      region: "ap-south-1",
      instance_type: "t3.large",
      architecture: "amd64",
      vcpu: 2,
      memory_mib: 8192,
      disk_gib: 40,
      purchase_option: "on_demand",
    },
    network_scope: {
      public_ingress: false,
      entry_point: "none",
      tls_required: false,
      authentication_required: false,
    },
    secret_scope: [],
    integration_scope: [],
    expires_at: "2026-07-14T07:04:00Z",
    signature: "",
    ...overrides,
  };
  proof.signature = sign(null, canonicalApprovalProofPayload(proof), devicePrivateKey).toString("base64url");
  return proof;
}

function signedCommand(action, payload, options = {}) {
  const payloadBytes = Buffer.from(JSON.stringify(payload), "utf8");
  const command = {
    schema: "dirextalk.aws.command/v2",
    connection_id: CONNECTION_ID,
    command_id: options.command_id ?? "command-v2-00001",
    node_key_id: NODE_KEY_ID,
    issued_at: options.issued_at ?? "2026-07-14T06:59:00.000Z",
    expires_at: options.expires_at ?? "2026-07-14T07:03:00.000Z",
    expected_generation: 3,
    node_counter: options.node_counter ?? 11,
    action,
    payload_b64: payloadBytes.toString("base64"),
    payload_sha256: sha256(payloadBytes),
    approval_binding: options.approval_binding,
    approval: options.approval,
    approval_proof: options.approval_proof,
    signature_b64: "",
  };
  if (command.approval_binding === undefined) delete command.approval_binding;
  if (command.approval === undefined) delete command.approval;
  if (command.approval_proof === undefined) delete command.approval_proof;
  command.signature_b64 = sign(
    null,
    Buffer.from(buildNodeSignatureBase(command), "utf8"),
    nodePrivateKey,
  ).toString("base64");
  return command;
}

const authOptions = {
  nowMs: NOW,
  connectionId: CONNECTION_ID,
  connectionGeneration: 3,
  nodeKeyId: NODE_KEY_ID,
  nodePublicKeySpkiBase64,
  deviceKeyId: DEVICE_KEY_ID,
  devicePublicKeySpkiBase64,
  expectedChallengeId: "challenge-v2-001",
};

function createFakeReceiptStore({ connectionId, generation }) {
  const receipts = new Map();
  const challenges = new Map();
  const approvalProofs = new Map();
  const deploymentReservations = new Map();
  let highestNodeCounter = -1;

  function fail(code, message) {
    throw new ConnectionStackV2Error(code, message, 409);
  }

  function receiptKey(request) {
    return `${request.connection_id}:${request.command_id}`;
  }

  function challengeKey(challenge) {
    return `${challenge.connection_id}:${challenge.challenge_id}`;
  }

  function deploymentKey(reservation) {
    return `${reservation.connection_id}:${reservation.deployment_id}`;
  }

  function sameRequest(receipt, request) {
    return receipt.expected_generation === request.expected_generation
      && receipt.node_counter === request.node_counter
      && receipt.request_sha256 === request.request_sha256
      && receipt.action === request.action;
  }

  return {
    async commit(request, quoteProvider) {
      assert.equal(request.schema, "dirextalk.aws.receipt-commit/v2");
      assert.equal(request.connection_id, connectionId);
      assert.equal(request.expected_generation, generation);
      assert.equal(typeof request.command_id, "string");
      assert.match(request.request_sha256, /^[0-9a-f]{64}$/);
      assert.equal(typeof request.action, "string");
      assert.ok(Number.isSafeInteger(request.node_counter));
      assert.ok(Number.isFinite(request.now_ms));

      const key = receiptKey(request);
      const existing = receipts.get(key);
      if (existing) {
        if (!sameRequest(existing, request)) {
          fail("command_id_conflict", "command id was already committed with a different request");
        }
        return { ...existing, disposition: "idempotent" };
      }
      if (request.is_expired) {
        fail("expired_command", "an expired command cannot create a new receipt");
      }
      if (request.approval_binding_is_expired) {
        fail("approval_expired", "an expired approval binding cannot create a new receipt");
      }
      if (request.node_counter <= highestNodeCounter) {
        fail("stale_node_counter", "node counter must advance monotonically");
      }

      let issuedChallenge;
      if (request.challenge_to_issue) {
        issuedChallenge = { ...request.challenge_to_issue };
        if (challenges.has(challengeKey(issuedChallenge))) {
          fail("challenge_id_conflict", "challenge id already exists");
        }
      }

      let consumedChallenge;
      if (request.approval_challenge) {
        const expected = request.approval_challenge;
        const stored = challenges.get(challengeKey(expected));
        if (!stored) fail("unknown_approval_challenge", "approval challenge was not issued");
        if (stored.binding_sha256 !== expected.binding_sha256
          || stored.expires_at !== expected.expires_at
          || Date.parse(stored.expires_at) <= request.now_ms) {
          fail("approval_binding_mismatch", "approval challenge does not match this receipt");
        }
        if (stored.consumed) fail("approval_replayed", "approval challenge was already consumed");
        consumedChallenge = { ...stored, consumed: true, consumed_by_command_id: request.command_id };
      }

      let consumedApprovalProof;
      if (request.approval_proof) {
        const proof = request.approval_proof;
        assert.equal(proof.schema, "dirextalk.aws.approval-proof-reference/v1");
        assert.equal(proof.connection_id, connectionId);
        assert.match(proof.approval_id, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
        assert.match(proof.payload_sha256, /^[0-9a-f]{64}$/);
        assert.equal(typeof proof.expires_at, "string");
        if (approvalProofs.has(proof.approval_id)) fail("approval_replayed", "approval proof was already consumed");
        consumedApprovalProof = { ...proof, consumed_by_command_id: request.command_id };
      }

      let deploymentReservation;
      if (request.action === "deployment.create") {
        assert.deepEqual(Object.keys(request.deployment_reservation ?? {}), ["deployment_id"], "a deployment create must carry the one-key private reservation");
        assert.equal(typeof request.deployment_reservation.deployment_id, "string");
        deploymentReservation = {
          connection_id: request.connection_id,
          deployment_id: request.deployment_reservation.deployment_id,
          request_sha256: request.request_sha256,
        };
        const existingReservation = deploymentReservations.get(deploymentKey(deploymentReservation));
        if (existingReservation && existingReservation.request_sha256 !== deploymentReservation.request_sha256) {
          fail("deployment_id_conflict", "deployment id is already bound to another request");
        }
      }

      const quote = request.action === "quote.request"
        ? await quoteProvider?.quote(request)
        : undefined;
      if (request.action === "quote.request" && !quote) {
        fail("quote_provider_unavailable", "quote provider is required");
      }
      const receipt = {
        schema: "dirextalk.aws.command-receipt/v2",
        disposition: "committed",
        connection_id: request.connection_id,
        expected_generation: request.expected_generation,
        node_counter: request.node_counter,
        command_id: request.command_id,
        request_sha256: request.request_sha256,
        action: request.action,
        ...(issuedChallenge ? { challenge: issuedChallenge } : {}),
        ...(quote ? { quote } : {}),
      };
      if (issuedChallenge) challenges.set(challengeKey(issuedChallenge), issuedChallenge);
      if (consumedChallenge) challenges.set(challengeKey(consumedChallenge), consumedChallenge);
      if (consumedApprovalProof) approvalProofs.set(consumedApprovalProof.approval_id, consumedApprovalProof);
      if (deploymentReservation) deploymentReservations.set(deploymentKey(deploymentReservation), deploymentReservation);
      receipts.set(key, receipt);
      highestNodeCounter = request.node_counter;
      return receipt;
    },
  };
}

function quoteForRequest(request) {
  const candidate = request.quote_request.candidates[0];
  return {
    schema: "dirextalk.aws.quote/v1",
    quote_id: `quote-${request.request_sha256.slice(0, 32)}`,
    connection_id: request.connection_id,
    command_id: request.command_id,
    request_sha256: request.request_sha256,
    quote_request_id: request.quote_request.quote_request_id,
    plan_digest: request.quote_request.plan_digest,
    region: request.quote_request.region,
    currency: "USD",
    quoted_at: new Date(request.now_ms).toISOString(),
    valid_until: new Date(request.now_ms + 15 * 60 * 1000).toISOString(),
    candidates: [{
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
    }],
    included_items: ["ec2_linux_ondemand"],
    unincluded_items: ["cloudwatch_logs", "data_transfer", "ebs_gp3", "public_ipv4", "snapshots", "taxes"],
  };
}

assert.deepEqual(BROKER_V2_ACTIONS, [
  "approval.challenge.request",
  "connection.registration.verify",
  "quote.request",
  "artifact.put",
  "deployment.create",
  "deployment.observe",
  "worker.task.issue",
  "worker.task.observe",
  "deployment.destroy",
]);

const quote = signedCommand("quote.request", {
  quote_request_id: "quote-request-v2-01",
  plan_digest: DIGEST("a"),
  region: "ap-south-1",
  candidates: [{
    candidate_id: "candidate-economy-01",
    tier: "economy",
    instance_type: "t3.large",
    purchase_option: "on_demand",
    estimated_disk_gib: 40,
  }],
});
const authenticatedQuote = validateAndAuthenticateV2Command(quote, authOptions);
assert.equal(authenticatedQuote.payload.region, "ap-south-1");
assert.equal(authenticatedQuote.payload.candidates[0].instance_type, "t3.large");

const spotQuote = signedCommand("quote.request", {
  quote_request_id: "quote-request-v2-spot",
  plan_digest: DIGEST("a"),
  region: "ap-south-1",
  candidates: [{
    candidate_id: "candidate-spot-quote-01",
    tier: "economy",
    instance_type: "t3.large",
    purchase_option: "spot",
    estimated_disk_gib: 40,
  }],
}, {
  command_id: "command-v2-quote-spot",
  node_counter: 9,
});
assert.throws(
  () => validateAndAuthenticateV2Command(spotQuote, authOptions),
  (error) => error instanceof ConnectionStackV2Error && error.code === "spot_quote_not_enabled",
  "Spot must be rejected by the signed command boundary before the provider can receive it",
);
assert.equal(authenticatedQuote.approval_binding, undefined);

const observe = signedCommand("deployment.observe", { deployment_id: "deployment-v2-001" }, {
  command_id: "command-v2-observe",
  node_counter: 10,
});
assert.equal(validateAndAuthenticateV2Command(observe, authOptions).payload.deployment_id, "deployment-v2-001");

const workerTaskIssue = signedCommand("worker.task.issue", {
  schema: "dirextalk.worker-task-issue/v1",
  deployment_id: "deployment-v2-001",
  task_id: "task-v2-execution-001",
  task_kind: "execution_probe",
  execution_manifest_digest: DIGEST("1"),
  input_digest: DIGEST("2"),
}, {
  command_id: "command-v2-worker-task-issue",
  node_counter: 11,
});
assert.deepEqual(validateAndAuthenticateV2Command(workerTaskIssue, authOptions).payload, {
  schema: "dirextalk.worker-task-issue/v1",
  deployment_id: "deployment-v2-001",
  task_id: "task-v2-execution-001",
  task_kind: "execution_probe",
  execution_manifest_digest: DIGEST("1"),
  input_digest: DIGEST("2"),
}, "a task issue is a signed digest-only execution-probe reference");
const workerTaskObserve = signedCommand("worker.task.observe", {
  deployment_id: "deployment-v2-001",
  task_id: "task-v2-execution-001",
}, {
  command_id: "command-v2-worker-task-observe",
  node_counter: 12,
});
assert.equal(validateAndAuthenticateV2Command(workerTaskObserve, authOptions).payload.task_id, "task-v2-execution-001");
assert.throws(
  () => validateAndAuthenticateV2Command(signedCommand("worker.task.issue", {
    schema: "dirextalk.worker-task-issue/v1",
    deployment_id: "deployment-v2-001",
    task_id: "task-v2-execution-001",
    task_kind: "execution_probe",
    execution_manifest_digest: DIGEST("1"),
    input_digest: DIGEST("2"),
    shell: "forbidden",
  }, {
    command_id: "command-v2-worker-task-shell",
    node_counter: 13,
  }), authOptions),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_payload",
  "the signed task issue has no shell or arbitrary execution extension",
);

const requestedBinding = binding();
const challengeRequest = signedCommand("approval.challenge.request", {
  challenge_request_id: "challenge-request-v2-01",
}, { approval_binding: requestedBinding });
const authenticatedChallenge = validateAndAuthenticateV2Command(challengeRequest, authOptions);
assert.equal(authenticatedChallenge.approval_binding.plan_revision, 7);
assert.equal(authenticatedChallenge.approval, undefined);

const receiptStore = createFakeReceiptStore({
  connectionId: CONNECTION_ID,
  generation: 3,
});
const challengeService = createV2ChallengeApprovalService({
  ...authOptions,
  clock: () => NOW,
  createChallengeId: () => "challenge-v2-001",
  receiptStore,
  quoteProvider: { quote: quoteForRequest },
});
const receiptQuote = signedCommand("quote.request", {
  quote_request_id: "quote-request-v2-receipt",
  plan_digest: DIGEST("a"),
  region: "ap-south-1",
  candidates: [{
    candidate_id: "candidate-economy-02",
    tier: "economy",
    instance_type: "t3.large",
    purchase_option: "on_demand",
    estimated_disk_gib: 40,
  }],
}, {
  command_id: "command-v2-quote-receipt",
  node_counter: 10,
});
const issuedQuote = await challengeService.accept(receiptQuote);
assert.equal(issuedQuote.status, "quote_issued");
assert.equal(issuedQuote.quote.candidates[0].hourly_minor, 5);
const expiredQuoteReplayService = createV2ChallengeApprovalService({
  ...authOptions,
  clock: () => Date.parse("2026-07-14T07:05:00.000Z"),
  createChallengeId: () => "challenge-v2-unused",
  receiptStore,
  quoteProvider: {
    async quote() {
      throw new Error("a stored quote must replay without a provider request");
    },
  },
});
const replayedQuote = await expiredQuoteReplayService.accept(receiptQuote);
assert.equal(replayedQuote.status, "idempotent");
assert.equal(replayedQuote.quote.quote_id, issuedQuote.quote.quote_id);
const issuedChallenge = await challengeService.accept(challengeRequest);
assert.equal(issuedChallenge.challenge.challenge_id, "challenge-v2-001");

const createBinding = binding();
const create = signedCommand("deployment.create", deploymentPayload("deployment-v2-001", createBinding), {
  command_id: "command-v2-00002",
  node_counter: 12,
  approval_proof: approvalProof(createBinding),
});
const authenticatedCreate = validateAndAuthenticateV2Command(create, authOptions);
assert.equal(authenticatedCreate.approval_proof.approval_id, "approval-proof-v2-01");
const consumedApproval = await challengeService.accept(create);
assert.equal(consumedApproval.status, "approval_consumed");
assert.equal(consumedApproval.receipt.command_id, "command-v2-00002");
assert.equal(consumedApproval.challenge, undefined, "ApprovalV1 create must not project a retired challenge reference");
const idempotentCreate = await challengeService.accept(create);
assert.equal(idempotentCreate.status, "idempotent");
assert.equal(idempotentCreate.receipt.command_id, "command-v2-00002");

const expiredReplayService = createV2ChallengeApprovalService({
  ...authOptions,
  clock: () => Date.parse("2026-07-14T07:05:00.000Z"),
  createChallengeId: () => "challenge-v2-001",
  receiptStore,
});
assert.equal(
  (await expiredReplayService.accept(create)).status,
  "idempotent",
  "a signed command must reconcile its durable receipt after the short acceptance window expires",
);
const expiredNewCommand = signedCommand("deployment.observe", {
  deployment_id: "deployment-v2-001",
}, {
  command_id: "command-v2-expired-new",
  node_counter: 15,
});
await assert.rejects(
  () => expiredReplayService.accept(expiredNewCommand),
  (error) => error instanceof ConnectionStackV2Error && error.code === "expired_command",
  "an expired command with no receipt must never advance the counter or become executable",
);

const conflictingCommand = signedCommand("deployment.create", deploymentPayload("deployment-v2-conflict", createBinding), {
  command_id: "command-v2-00002",
  node_counter: 12,
  approval_proof: approvalProof(createBinding),
});
await assert.rejects(
  () => challengeService.accept(conflictingCommand),
  (error) => error instanceof ConnectionStackV2Error && error.code === "command_id_conflict",
  "a command id must never be rebound to a different signed request",
);

const conflictingDeploymentId = signedCommand("deployment.create", deploymentPayload("deployment-v2-001", createBinding), {
  command_id: "command-v2-deployment-id-conflict",
  node_counter: 14,
  approval_proof: approvalProof(createBinding, {
    approval_id: "approval-proof-v2-deployment-id-conflict",
    challenge_id: "challenge-v2-deployment-id-conflict",
  }),
});
await assert.rejects(
  () => challengeService.accept(conflictingDeploymentId),
  (error) => error instanceof ConnectionStackV2Error && error.code === "deployment_id_conflict",
  "a different signed command must be rejected when it reuses an accepted deployment id",
);

const counterRollback = signedCommand("deployment.observe", {
  deployment_id: "deployment-v2-001",
}, {
  command_id: "command-v2-counter-rollback",
  node_counter: 11,
});
await assert.rejects(
  () => challengeService.accept(counterRollback),
  (error) => error instanceof ConnectionStackV2Error && error.code === "stale_node_counter",
  "a new command cannot move the durable node counter backward",
);

const replayedApproval = signedCommand("deployment.create", deploymentPayload("deployment-v2-004", createBinding), {
  command_id: "command-v2-00005",
  node_counter: 13,
  approval_proof: approvalProof(createBinding),
});
await assert.rejects(
  () => challengeService.accept(replayedApproval),
  (error) => error instanceof ConnectionStackV2Error && error.code === "approval_replayed",
  "a Flutter approval challenge is one-time even when a new node command id is used",
);

const artifactBinding = binding();
const artifact = signedCommand("artifact.put", {
  artifact_id: "artifact-v2-00001",
  manifest_digest: DIGEST("c"),
  content_digest: DIGEST("3"),
  content_length: 4096,
}, {
  command_id: "command-v2-artifact",
  node_counter: 16,
  approval_binding: artifactBinding,
  approval: deviceApproval(artifactBinding),
});
assert.equal(validateAndAuthenticateV2Command(artifact, authOptions).payload.content_length, 4096);

const destroyBinding = binding();
const destroy = signedCommand("deployment.destroy", {
  deployment_id: "deployment-v2-001",
  resource_manifest_digest: DIGEST("c"),
  volume_policy: "retain",
}, {
  command_id: "command-v2-destroy",
  node_counter: 17,
  approval_binding: destroyBinding,
  approval: deviceApproval(destroyBinding),
});
assert.equal(validateAndAuthenticateV2Command(destroy, authOptions).payload.volume_policy, "retain");

const arbitraryAction = signedCommand("aws.invoke", { deployment_id: "deployment-v2-001" }, {
  command_id: "command-v2-arbitrary",
  node_counter: 18,
});
assert.throws(
  () => validateAndAuthenticateV2Command(arbitraryAction, authOptions),
  (error) => error instanceof ConnectionStackV2Error && error.code === "unsupported_action",
  "an envelope cannot escape into a generic AWS action",
);

const missingApproval = signedCommand("deployment.create", deploymentPayload("deployment-v2-003"), {
  command_id: "command-v2-00004",
  node_counter: 14,
});
assert.throws(
  () => validateAndAuthenticateV2Command(missingApproval, authOptions),
  (error) => error instanceof ConnectionStackV2Error && error.code === "approval_required",
  "a mutating command must fail closed before any payload dereference when no approval exists",
);

const changedQuotePayload = deploymentPayload("deployment-v2-002", createBinding);
changedQuotePayload.quote_digest = DIGEST("1");
const changedQuoteCommand = signedCommand("deployment.create", changedQuotePayload, {
  command_id: "command-v2-00003",
  node_counter: 13,
  approval_proof: approvalProof(createBinding),
});
assert.throws(
  () => validateAndAuthenticateV2Command(changedQuoteCommand, authOptions),
  (error) => error instanceof ConnectionStackV2Error && error.code === "approval_proof_mismatch",
  "the existing device approval must bind the exact approved quote digest",
);

const rootBootstrap = {
  Account: "123456789012",
  Arn: "arn:aws:iam::123456789012:root",
  UserId: "123456789012",
};
assert.throws(
  () => validateBootstrapIdentity(rootBootstrap),
  (error) => error instanceof ConnectionStackV2Error && error.code === "root_bootstrap_forbidden",
);
assert.deepEqual(
  validateBootstrapIdentity({
    Account: "123456789012",
    Arn: "arn:aws:sts::123456789012:assumed-role/DirextalkConnectionStackBootstrap/session-001",
    UserId: "AROAXXXXXXXXXXXXX:session-001",
  }),
  {
    account_id: "123456789012",
    principal_type: "assumed_role",
  },
);

const workerManifest = {
  schema: "dirextalk.worker-bootstrap/v1",
  connection_id: CONNECTION_ID,
  deployment_id: "deployment-v2-001",
  bootstrap_session_id: "worker-session-v2-01",
  bootstrap_endpoint: "https://broker.example.invalid/v2/worker-sessions",
  worker_image_digest: DIGEST("2"),
  artifact_manifest_digest: DIGEST("c"),
  expires_at: "2026-07-14T07:04:00.000Z",
};
const workerValidation = {
  nowMs: NOW,
  maxLifetimeMs: 5 * 60 * 1000,
  expectedConnectionId: CONNECTION_ID,
  expectedBootstrapEndpoint: "https://broker.example.invalid/v2/worker-sessions",
};
assert.equal(validateWorkerBootstrapManifest(workerManifest, workerValidation).deployment_id, "deployment-v2-001");
assert.throws(
  () => validateWorkerBootstrapManifest({ ...workerManifest, ssh_key_name: "operator-key" }, workerValidation),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "a worker bootstrap manifest must never carry SSH or cloud-control configuration",
);
assert.throws(
  () => validateWorkerBootstrapManifest({ ...workerManifest, expires_at: "2026-13-01T00:00:00.000Z" }, workerValidation),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "invalid worker expiry must fail as a typed contract error instead of leaking a runtime exception",
);
assert.throws(
  () => validateWorkerBootstrapManifest({ ...workerManifest, expires_at: "2026-07-14T07:00:00.000Z" }, workerValidation),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "an expired worker bootstrap manifest must fail closed",
);
assert.throws(
  () => validateWorkerBootstrapManifest({ ...workerManifest, expires_at: "2026-07-14T07:06:00.000Z" }, workerValidation),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "a worker bootstrap manifest cannot exceed its configured TTL",
);
assert.throws(
  () => validateWorkerBootstrapManifest({ ...workerManifest, connection_id: "connection-v2-other" }, workerValidation),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "worker bootstrap connection_id must match the expected connection",
);
assert.throws(
  () => validateWorkerBootstrapManifest({ ...workerManifest, bootstrap_endpoint: "https://other.example.invalid/v2/worker-sessions" }, workerValidation),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "worker bootstrap endpoint must match the registered broker endpoint",
);
assert.throws(
  () => validateWorkerBootstrapManifest(workerManifest, { ...workerValidation, maxLifetimeMs: 11 * 60 * 1000 }),
  (error) => error instanceof ConnectionStackV2Error && error.code === "invalid_worker_manifest",
  "worker verifier context cannot relax the ten-minute maximum bootstrap lifetime",
);

console.log("connection stack v2 command contract ok");
