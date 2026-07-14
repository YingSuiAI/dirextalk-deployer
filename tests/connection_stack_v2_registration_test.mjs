import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";

import {
  ConnectionStackV2Error,
  buildNodeSignatureBase,
  createV2ChallengeApprovalService,
} from "../scripts/connection-stack-v2/src/command-contract.mjs";
import {
  CONNECTION_REGISTRATION_VERIFY_ACTION,
} from "../scripts/connection-stack-v2/src/registration-contract.mjs";

const NOW = Date.parse("2026-07-14T07:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const NODE_KEY_ID = "node-key-v2";
const STACK_ARN = "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-001/01234567-89ab-cdef-0123-456789abcdef";
const BROKER_URL = "https://abcde12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const nodePublicKeySpkiBase64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function signedRegistration(payload, options = {}) {
  const payloadBytes = Buffer.from(JSON.stringify(payload), "utf8");
  const command = {
    schema: "dirextalk.aws.command/v2",
    connection_id: CONNECTION_ID,
    command_id: options.commandId ?? "command-v2-registration-01",
    node_key_id: NODE_KEY_ID,
    issued_at: options.issuedAt ?? "2026-07-14T06:59:00.000Z",
    expires_at: options.expiresAt ?? "2026-07-14T07:03:00.000Z",
    expected_generation: 3,
    node_counter: options.nodeCounter ?? 1,
    action: CONNECTION_REGISTRATION_VERIFY_ACTION,
    payload_b64: payloadBytes.toString("base64"),
    payload_sha256: sha256(payloadBytes),
    signature_b64: "",
  };
  command.signature_b64 = sign(
    null,
    Buffer.from(buildNodeSignatureBase(command), "utf8"),
    privateKey,
  ).toString("base64");
  return command;
}

function receiptStore() {
  const receipts = new Map();
  return {
    async commit(request) {
      const key = `${request.connection_id}:${request.command_id}`;
      const existing = receipts.get(key);
      if (existing) {
        if (existing.request_sha256 !== request.request_sha256 || existing.action !== request.action) {
          throw new ConnectionStackV2Error("command_id_conflict", "command id conflict", 409);
        }
        return { ...existing, disposition: "idempotent" };
      }
      if (request.is_expired) throw new ConnectionStackV2Error("expired_command", "command expired", 401);
      assert.equal(request.action, CONNECTION_REGISTRATION_VERIFY_ACTION);
      assert.deepEqual(Object.keys(request.registration), [
        "schema",
        "bootstrap_id",
        "connection_id",
        "account_id",
        "region",
        "broker_command_url",
        "node_key_id",
        "connection_generation",
        "stack_arn",
        "command_id",
        "request_sha256",
      ]);
      const receipt = {
        schema: "dirextalk.aws.command-receipt/v2",
        disposition: "committed",
        connection_id: request.connection_id,
        expected_generation: request.expected_generation,
        node_counter: request.node_counter,
        command_id: request.command_id,
        request_sha256: request.request_sha256,
        action: request.action,
        registration: request.registration,
      };
      receipts.set(key, receipt);
      return receipt;
    },
  };
}

const store = receiptStore();
const serviceOptions = {
  clock: () => NOW,
  createChallengeId: () => "challenge-v2-unused",
  receiptStore: store,
  connectionId: CONNECTION_ID,
  connectionGeneration: 3,
  nodeKeyId: NODE_KEY_ID,
  nodePublicKeySpkiBase64,
  deviceKeyId: "device-key-v2",
  devicePublicKeySpkiBase64: nodePublicKeySpkiBase64,
  registration: {
    account_id: "123456789012",
    region: "ap-south-1",
    stack_arn: STACK_ARN,
    api_gateway_url_suffix: "amazonaws.com",
    stage_name: "prod",
  },
};
const service = createV2ChallengeApprovalService(serviceOptions);
const command = signedRegistration({
  bootstrap_id: "bootstrap-v2-0001",
  requested_region: "ap-south-1",
  stack_arn: STACK_ARN,
});

const registered = await service.accept(command, { broker_command_url: BROKER_URL });
assert.equal(registered.status, "connection_registered");
assert.equal(registered.receipt.action, CONNECTION_REGISTRATION_VERIFY_ACTION);
assert.deepEqual(registered.registration, {
  schema: "dirextalk.aws.connection-registration/v1",
  bootstrap_id: "bootstrap-v2-0001",
  connection_id: CONNECTION_ID,
  account_id: "123456789012",
  region: "ap-south-1",
  broker_command_url: BROKER_URL,
  node_key_id: NODE_KEY_ID,
  connection_generation: 3,
  stack_arn: STACK_ARN,
  command_id: command.command_id,
  request_sha256: registered.receipt.request_sha256,
});

const replay = await createV2ChallengeApprovalService({
  ...serviceOptions,
  clock: () => Date.parse("2026-07-14T07:05:00.000Z"),
}).accept(command, { broker_command_url: BROKER_URL });
assert.equal(replay.status, "idempotent");
assert.deepEqual(replay.registration, registered.registration, "expired signed replays must return the immutable registration receipt");

const wrongRegion = signedRegistration({
  bootstrap_id: "bootstrap-v2-0001",
  requested_region: "us-east-1",
  stack_arn: STACK_ARN,
}, { commandId: "command-v2-registration-02", nodeCounter: 2 });
await assert.rejects(
  () => service.accept(wrongRegion, { broker_command_url: BROKER_URL }),
  (error) => error?.code === "registration_region_mismatch",
  "the Broker must derive its region from the Stack rather than accept a signed payload claim",
);

const wrongStack = signedRegistration({
  bootstrap_id: "bootstrap-v2-0001",
  requested_region: "ap-south-1",
  stack_arn: "arn:aws:cloudformation:ap-south-1:123456789012:stack/DirextalkConnectionStackV2-002/01234567-89ab-cdef-0123-456789abcdef",
}, { commandId: "command-v2-registration-03", nodeCounter: 3 });
await assert.rejects(
  () => service.accept(wrongStack, { broker_command_url: BROKER_URL }),
  (error) => error?.code === "registration_stack_mismatch",
  "the Broker must derive its stack identity rather than accept a signed payload claim",
);

const extraClaim = signedRegistration({
  bootstrap_id: "bootstrap-v2-0001",
  requested_region: "ap-south-1",
  stack_arn: STACK_ARN,
  account_id: "123456789012",
}, { commandId: "command-v2-registration-04", nodeCounter: 4 });
await assert.rejects(
  () => service.accept(extraClaim, { broker_command_url: BROKER_URL }),
  (error) => error?.code === "invalid_payload",
  "registration payloads must remain the exact three-field closed contract",
);

const corruptReceiptService = createV2ChallengeApprovalService({
  ...serviceOptions,
  receiptStore: {
    async commit(request) {
      return {
        schema: "dirextalk.aws.command-receipt/v2",
        disposition: "committed",
        connection_id: request.connection_id,
        expected_generation: request.expected_generation,
        node_counter: request.node_counter,
        command_id: request.command_id,
        request_sha256: request.request_sha256,
        action: request.action,
        registration: {
          ...request.registration,
          broker_command_url: "https://fffff12345.execute-api.ap-south-1.amazonaws.com/prod/v2/commands",
        },
      };
    },
  },
});
const corruptReceiptCommand = signedRegistration({
  bootstrap_id: "bootstrap-v2-0001",
  requested_region: "ap-south-1",
  stack_arn: STACK_ARN,
}, { commandId: "command-v2-registration-05", nodeCounter: 5 });
await assert.rejects(
  () => corruptReceiptService.accept(corruptReceiptCommand, { broker_command_url: BROKER_URL }),
  (error) => error?.code === "receipt_store_invalid",
  "a receipt must match the current Stack-derived registration, not merely have a well-formed endpoint",
);

console.log("connection stack v2 registration boundary ok");
