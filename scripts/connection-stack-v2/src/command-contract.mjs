import {
  createHash,
  createPublicKey,
  verify,
} from "node:crypto";

export const COMMAND_V2_SCHEMA = "dirextalk.aws.command/v2";
export const APPROVAL_BINDING_V2_SCHEMA = "dirextalk.aws.approval-binding/v2";
export const APPROVAL_V2_SCHEMA = "dirextalk.aws.approval/v2";
export const APPROVAL_CHALLENGE_V2_SCHEMA = "dirextalk.aws.approval-challenge/v2";
export const RECEIPT_COMMIT_V2_SCHEMA = "dirextalk.aws.receipt-commit/v2";
export const COMMAND_RECEIPT_V2_SCHEMA = "dirextalk.aws.command-receipt/v2";
export const WORKER_BOOTSTRAP_V1_SCHEMA = "dirextalk.worker-bootstrap/v1";
export const BROKER_V2_ACTIONS = Object.freeze([
  "approval.challenge.request",
  "quote.request",
  "artifact.put",
  "deployment.create",
  "deployment.observe",
  "deployment.destroy",
]);

const COMMAND_FIELDS = new Set([
  "schema",
  "connection_id",
  "command_id",
  "node_key_id",
  "issued_at",
  "expires_at",
  "expected_generation",
  "node_counter",
  "action",
  "payload_b64",
  "payload_sha256",
  "approval_binding",
  "approval",
  "signature_b64",
]);
const APPROVAL_BINDING_FIELDS = [
  "schema",
  "connection_id",
  "plan_hash",
  "plan_revision",
  "quote_id",
  "recipe_digest",
  "manifest_digest",
  "resource_scope_digest",
  "network_scope_digest",
  "secret_scope_digest",
  "integration_scope_digest",
  "expires_at",
];
const APPROVAL_FIELDS = [
  "schema",
  "challenge_id",
  "device_key_id",
  "binding_sha256",
  "expires_at",
  "signature_b64",
];
const SENSITIVE_ACTIONS = new Set([
  "artifact.put",
  "deployment.create",
  "deployment.destroy",
]);
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const INSTANCE_TYPE_PATTERN = /^[a-z0-9][a-z0-9.-]{1,63}$/;
const MAX_COMMAND_LIFETIME_MS = 5 * 60 * 1000;
const MAX_APPROVAL_LIFETIME_MS = 15 * 60 * 1000;
const MAX_CLOCK_SKEW_MS = 60 * 1000;
const MAX_PAYLOAD_BYTES = 192 * 1024;
const MAX_ARTIFACT_BYTES = 5 * 1024 * 1024 * 1024;

export class ConnectionStackV2Error extends Error {
  constructor(code, message, statusCode = 400) {
    super(message);
    this.name = "ConnectionStackV2Error";
    this.code = code;
    this.statusCode = statusCode;
  }
}

function fail(code, message, statusCode = 400) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(record, allowed, code, label) {
  if (!isRecord(record)) fail(code, `${label} must be an object`);
  for (const key of Object.keys(record)) {
    if (!allowed.includes(key)) fail(code, `${label}.${key} is not allowed`);
  }
  for (const key of allowed) {
    if (!Object.hasOwn(record, key)) fail(code, `${label}.${key} is required`);
  }
}

function exactPayloadKeys(payload, required, optional = []) {
  if (!isRecord(payload)) fail("invalid_payload", "payload must be a JSON object");
  const allowed = new Set([...required, ...optional]);
  for (const key of required) {
    if (!Object.hasOwn(payload, key)) fail("invalid_payload", `${key} is required`);
  }
  for (const key of Object.keys(payload)) {
    if (!allowed.has(key)) fail("invalid_payload", `${key} is not allowed for this action`);
  }
}

function requireString(record, key, pattern, code = "invalid_command") {
  const value = record[key];
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${key} is invalid`);
  }
  return value;
}

function requireId(record, key, code = "invalid_payload") {
  return requireString(record, key, ID_PATTERN, code);
}

function requireDigest(record, key, code = "invalid_payload") {
  return requireString(record, key, NAMED_SHA256_PATTERN, code);
}

function parseCanonicalInstant(value, field, code = "invalid_command") {
  if (typeof value !== "string" || !ISO_INSTANT_PATTERN.test(value)) {
    fail(code, `${field} is not a canonical UTC timestamp`);
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== value) {
    fail(code, `${field} is not a canonical UTC timestamp`);
  }
  return parsed;
}

function decodeBase64(value, field, code = "invalid_command") {
  if (typeof value !== "string" || value.length === 0 || value.length % 4 !== 0 || !BASE64_PATTERN.test(value)) {
    fail(code, `${field} must be canonical padded base64`);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) {
    fail(code, `${field} must be canonical padded base64`);
  }
  return decoded;
}

function decodeCanonicalPayload(command) {
  const payloadBytes = decodeBase64(command.payload_b64, "payload_b64");
  if (payloadBytes.length > MAX_PAYLOAD_BYTES) fail("invalid_payload", "payload is too large", 413);
  if (sha256(payloadBytes) !== command.payload_sha256) {
    fail("payload_digest_mismatch", "payload_sha256 does not match payload_b64", 401);
  }
  let payload;
  let payloadText;
  try {
    payloadText = new TextDecoder("utf-8", { fatal: true }).decode(payloadBytes);
    payload = JSON.parse(payloadText);
  } catch {
    fail("invalid_payload", "payload_b64 must decode to UTF-8 JSON");
  }
  if (JSON.stringify(payload) !== payloadText) {
    fail("noncanonical_payload", "payload must use canonical compact JSON encoding");
  }
  return payload;
}

function approvalBindingCanonicalObject(binding) {
  return Object.fromEntries(APPROVAL_BINDING_FIELDS.map((key) => [key, binding[key]]));
}

export function validateApprovalBinding(binding, { connectionId, nowMs } = {}) {
  exactKeys(binding, APPROVAL_BINDING_FIELDS, "invalid_approval_binding", "approval_binding");
  if (binding.schema !== APPROVAL_BINDING_V2_SCHEMA) {
    fail("invalid_approval_binding", "approval_binding schema is invalid");
  }
  const bindingConnectionId = requireString(binding, "connection_id", ID_PATTERN, "invalid_approval_binding");
  if (connectionId && bindingConnectionId !== connectionId) {
    fail("wrong_connection", "approval binding connection_id does not match this stack", 403);
  }
  requireDigest(binding, "plan_hash", "invalid_approval_binding");
  if (!Number.isSafeInteger(binding.plan_revision) || binding.plan_revision < 1) {
    fail("invalid_approval_binding", "approval_binding.plan_revision must be a positive safe integer");
  }
  requireId(binding, "quote_id", "invalid_approval_binding");
  requireDigest(binding, "recipe_digest", "invalid_approval_binding");
  requireDigest(binding, "manifest_digest", "invalid_approval_binding");
  requireDigest(binding, "resource_scope_digest", "invalid_approval_binding");
  requireDigest(binding, "network_scope_digest", "invalid_approval_binding");
  requireDigest(binding, "secret_scope_digest", "invalid_approval_binding");
  requireDigest(binding, "integration_scope_digest", "invalid_approval_binding");
  const expiresAtMs = parseCanonicalInstant(binding.expires_at, "approval_binding.expires_at", "invalid_approval_binding");
  if (nowMs !== undefined) {
    if (expiresAtMs <= nowMs) fail("approval_expired", "approval binding has expired", 401);
    if (expiresAtMs - nowMs > MAX_APPROVAL_LIFETIME_MS) {
      fail("invalid_approval_binding", "approval binding lifetime exceeds fifteen minutes");
    }
  }
  return approvalBindingCanonicalObject(binding);
}

export function canonicalApprovalBindingDigest(binding) {
  const validated = validateApprovalBinding(binding);
  return sha256(Buffer.from(JSON.stringify(validated), "utf8"));
}

function approvalSignatureDigest(approval) {
  if (!approval || typeof approval !== "object" || typeof approval.signature_b64 !== "string") return "";
  return sha256(decodeBase64(approval.signature_b64, "approval.signature_b64", "invalid_approval"));
}

export function buildNodeSignatureBase(command) {
  const bindingDigest = command.approval_binding ? canonicalApprovalBindingDigest(command.approval_binding) : "";
  return [
    "dirextalk.aws.command-signature/v2",
    `schema=${command.schema ?? ""}`,
    `connection_id=${command.connection_id ?? ""}`,
    `command_id=${command.command_id ?? ""}`,
    `node_key_id=${command.node_key_id ?? ""}`,
    `issued_at=${command.issued_at ?? ""}`,
    `expires_at=${command.expires_at ?? ""}`,
    `expected_generation=${command.expected_generation ?? ""}`,
    `node_counter=${command.node_counter ?? ""}`,
    `action=${command.action ?? ""}`,
    `payload_sha256=${command.payload_sha256 ?? ""}`,
    `approval_binding_sha256=${bindingDigest}`,
    `approval_challenge_id=${command.approval?.challenge_id ?? ""}`,
    `approval_signature_sha256=${approvalSignatureDigest(command.approval)}`,
    "",
  ].join("\n");
}

export function buildApprovalSignatureBase(approval, binding) {
  return [
    "dirextalk.aws.approval-signature/v2",
    `schema=${approval.schema ?? ""}`,
    `challenge_id=${approval.challenge_id ?? ""}`,
    `device_key_id=${approval.device_key_id ?? ""}`,
    `binding_sha256=${approval.binding_sha256 ?? ""}`,
    `connection_id=${binding.connection_id ?? ""}`,
    `plan_hash=${binding.plan_hash ?? ""}`,
    `plan_revision=${binding.plan_revision ?? ""}`,
    `quote_id=${binding.quote_id ?? ""}`,
    `recipe_digest=${binding.recipe_digest ?? ""}`,
    `manifest_digest=${binding.manifest_digest ?? ""}`,
    `resource_scope_digest=${binding.resource_scope_digest ?? ""}`,
    `network_scope_digest=${binding.network_scope_digest ?? ""}`,
    `secret_scope_digest=${binding.secret_scope_digest ?? ""}`,
    `integration_scope_digest=${binding.integration_scope_digest ?? ""}`,
    `expires_at=${binding.expires_at ?? ""}`,
    "",
  ].join("\n");
}

function configuredEd25519Key(publicKeySpkiBase64, code) {
  let publicKey;
  try {
    publicKey = createPublicKey({
      key: Buffer.from(publicKeySpkiBase64, "base64"),
      format: "der",
      type: "spki",
    });
  } catch {
    fail(code, "configured public key is invalid", 500);
  }
  if (publicKey.asymmetricKeyType !== "ed25519") {
    fail(code, "configured public key is not Ed25519", 500);
  }
  return publicKey;
}

function validateApproval(approval, binding, options) {
  exactKeys(approval, APPROVAL_FIELDS, "invalid_approval", "approval");
  if (approval.schema !== APPROVAL_V2_SCHEMA) fail("invalid_approval", "approval schema is invalid");
  const challengeId = requireString(approval, "challenge_id", ID_PATTERN, "invalid_approval");
  const deviceKeyId = requireString(approval, "device_key_id", KEY_ID_PATTERN, "invalid_approval");
  const bindingSha256 = requireString(approval, "binding_sha256", SHA256_PATTERN, "invalid_approval");
  const signature = decodeBase64(approval.signature_b64, "approval.signature_b64", "invalid_approval");
  if (options.expectedChallengeId && challengeId !== options.expectedChallengeId) {
    fail("unknown_approval_challenge", "approval challenge is not active", 409);
  }
  if (deviceKeyId !== options.deviceKeyId) fail("unknown_device_key", "approval device key is not active", 401);
  if (approval.expires_at !== binding.expires_at) {
    fail("approval_binding_mismatch", "approval expiry must match approval binding", 409);
  }
  if (bindingSha256 !== canonicalApprovalBindingDigest(binding)) {
    fail("approval_binding_mismatch", "approval does not bind this plan scope", 409);
  }
  const deviceKey = configuredEd25519Key(options.devicePublicKeySpkiBase64, "invalid_stack_device_key");
  if (!verify(null, Buffer.from(buildApprovalSignatureBase(approval, binding), "utf8"), deviceKey, signature)) {
    fail("invalid_approval_signature", "approval signature is invalid", 401);
  }
  return approval;
}

function validatePayload(action, payload, binding) {
  switch (action) {
    case "approval.challenge.request":
      exactPayloadKeys(payload, ["challenge_request_id"]);
      requireId(payload, "challenge_request_id");
      break;
    case "quote.request":
      exactPayloadKeys(payload, ["quote_request_id", "plan_digest", "region", "purchase_model"], ["instance_type"]);
      requireId(payload, "quote_request_id");
      requireDigest(payload, "plan_digest");
      requireString(payload, "region", REGION_PATTERN, "invalid_payload");
      if (!new Set(["on_demand", "spot"]).has(payload.purchase_model)) {
        fail("invalid_payload", "purchase_model must be on_demand or spot");
      }
      if (Object.hasOwn(payload, "instance_type")) {
        requireString(payload, "instance_type", INSTANCE_TYPE_PATTERN, "invalid_payload");
      }
      break;
    case "artifact.put":
      exactPayloadKeys(payload, ["artifact_id", "manifest_digest", "content_digest", "content_length"]);
      requireId(payload, "artifact_id");
      requireDigest(payload, "manifest_digest");
      requireDigest(payload, "content_digest");
      if (!Number.isSafeInteger(payload.content_length) || payload.content_length < 1 || payload.content_length > MAX_ARTIFACT_BYTES) {
        fail("invalid_payload", "content_length is invalid");
      }
      if (payload.manifest_digest !== binding.manifest_digest) {
        fail("approval_binding_mismatch", "artifact manifest does not match approval binding", 409);
      }
      break;
    case "deployment.create":
      exactPayloadKeys(payload, ["deployment_id", "quote_id", "manifest_digest"]);
      requireId(payload, "deployment_id");
      requireId(payload, "quote_id");
      requireDigest(payload, "manifest_digest");
      if (payload.quote_id !== binding.quote_id || payload.manifest_digest !== binding.manifest_digest) {
        fail("approval_binding_mismatch", "deployment create does not match approval binding", 409);
      }
      break;
    case "deployment.observe":
      exactPayloadKeys(payload, ["deployment_id"]);
      requireId(payload, "deployment_id");
      break;
    case "deployment.destroy":
      exactPayloadKeys(payload, ["deployment_id", "resource_manifest_digest", "volume_policy"]);
      requireId(payload, "deployment_id");
      requireDigest(payload, "resource_manifest_digest");
      if (!new Set(["delete", "retain", "snapshot_then_delete"]).has(payload.volume_policy)) {
        fail("invalid_payload", "volume_policy is invalid");
      }
      if (payload.resource_manifest_digest !== binding.manifest_digest) {
        fail("approval_binding_mismatch", "destroy manifest does not match approval binding", 409);
      }
      break;
    default:
      fail("unsupported_action", "action is not supported", 400);
  }
}

function validateActionApprovalPresence(command, binding) {
  if (command.action === "approval.challenge.request") {
    if (!binding) fail("approval_required", "approval challenge requires a complete approval binding", 409);
    if (command.approval !== undefined) fail("invalid_approval", "approval challenge requests cannot contain an approval");
    return;
  }
  if (SENSITIVE_ACTIONS.has(command.action)) {
    if (!binding || !command.approval) {
      fail("approval_required", "this action requires a Flutter device approval", 409);
    }
    return;
  }
  if (binding !== undefined || command.approval !== undefined) {
    fail("invalid_approval", "read-only actions cannot carry an approval binding");
  }
}

function validateActionApprovalShape(command, binding, options) {
  validateActionApprovalPresence(command, binding);
  if (SENSITIVE_ACTIONS.has(command.action)) {
    return validateApproval(command.approval, binding, options);
  }
  return undefined;
}

export function validateAndAuthenticateV2Command(command, options, { allowExpiredReplay = false } = {}) {
  if (!isRecord(command)) fail("invalid_command", "command must be a JSON object");
  for (const key of Object.keys(command)) {
    if (!COMMAND_FIELDS.has(key)) fail("invalid_command", `${key} is not allowed`);
  }
  for (const key of [
    "schema", "connection_id", "command_id", "node_key_id", "issued_at", "expires_at",
    "expected_generation", "node_counter", "action", "payload_b64", "payload_sha256", "signature_b64",
  ]) {
    if (!Object.hasOwn(command, key)) fail("invalid_command", `${key} is required`);
  }
  if (command.schema !== COMMAND_V2_SCHEMA) fail("invalid_command", "unsupported command schema");
  const connectionId = requireString(command, "connection_id", ID_PATTERN);
  requireString(command, "command_id", ID_PATTERN);
  const nodeKeyId = requireString(command, "node_key_id", KEY_ID_PATTERN);
  const action = requireString(command, "action", /^[a-z][a-z0-9_.-]{2,63}$/);
  const payloadSha256 = requireString(command, "payload_sha256", SHA256_PATTERN);
  if (!BROKER_V2_ACTIONS.includes(action)) fail("unsupported_action", "action is not supported", 400);
  if (!Number.isSafeInteger(command.expected_generation) || command.expected_generation < 1) {
    fail("invalid_command", "expected_generation must be a positive safe integer");
  }
  if (!Number.isSafeInteger(command.node_counter) || command.node_counter < 0) {
    fail("invalid_command", "node_counter must be a nonnegative safe integer");
  }
  if (connectionId !== options.connectionId) fail("wrong_connection", "connection_id does not match this stack", 403);
  if (nodeKeyId !== options.nodeKeyId) fail("unknown_node_key", "node key is not active", 401);
  if (command.expected_generation !== options.connectionGeneration) {
    fail("stale_generation", "expected_generation does not match this stack", 409);
  }

  const issuedAtMs = parseCanonicalInstant(command.issued_at, "issued_at");
  const expiresAtMs = parseCanonicalInstant(command.expires_at, "expires_at");
  if (expiresAtMs <= issuedAtMs || expiresAtMs - issuedAtMs > MAX_COMMAND_LIFETIME_MS) {
    fail("invalid_command", "command time window is invalid");
  }
  if (issuedAtMs > options.nowMs + MAX_CLOCK_SKEW_MS) fail("future_command", "issued_at is too far in the future");
  const isExpired = expiresAtMs <= options.nowMs;
  if (isExpired && !allowExpiredReplay) fail("expired_command", "command has expired", 401);

  const binding = command.approval_binding === undefined
    ? undefined
    : validateApprovalBinding(command.approval_binding, {
      connectionId,
      nowMs: allowExpiredReplay ? undefined : options.nowMs,
    });
  const approvalBindingIsExpired = binding !== undefined && Date.parse(binding.expires_at) <= options.nowMs;
  const payload = decodeCanonicalPayload({ ...command, payload_sha256: payloadSha256 });
  validateActionApprovalPresence(command, binding);
  validatePayload(action, payload, binding);
  const approval = validateActionApprovalShape(command, binding, options);

  const signature = decodeBase64(command.signature_b64, "signature_b64");
  const nodeKey = configuredEd25519Key(options.nodePublicKeySpkiBase64, "invalid_stack_node_key");
  const signatureBase = Buffer.from(buildNodeSignatureBase(command), "utf8");
  if (!verify(null, signatureBase, nodeKey, signature)) {
    fail("invalid_node_signature", "node command signature is invalid", 401);
  }
  return {
    ...command,
    payload,
    approval_binding: binding,
    approval,
    request_sha256: sha256(signatureBase),
    ...(allowExpiredReplay ? {
      is_expired: isExpired,
      approval_binding_is_expired: approvalBindingIsExpired,
    } : {}),
  };
}

export function validateBootstrapIdentity(identity) {
  if (!isRecord(identity)) fail("invalid_bootstrap_identity", "bootstrap identity is required");
  const accountId = requireString(identity, "Account", /^\d{12}$/, "invalid_bootstrap_identity");
  const arn = requireString(identity, "Arn", /^arn:[^:]+:(?:iam|sts)::\d{12}:.+$/, "invalid_bootstrap_identity");
  requireString(identity, "UserId", /^.{1,256}$/, "invalid_bootstrap_identity");
  if (/:root$/.test(arn)) {
    fail("root_bootstrap_forbidden", "root AWS identities cannot bootstrap a Connection Stack", 403);
  }
  if (!new RegExp(`^arn:[^:]+:sts::${accountId}:assumed-role/[A-Za-z0-9+=,.@_-]{1,64}/[^/]{1,64}$`).test(arn)) {
    fail("bootstrap_identity_forbidden", "Connection Stack bootstrap requires a non-root assumed role", 403);
  }
  return {
    account_id: accountId,
    principal_type: "assumed_role",
  };
}

const RECEIPT_FIELDS = [
  "schema",
  "disposition",
  "connection_id",
  "expected_generation",
  "node_counter",
  "command_id",
  "request_sha256",
  "action",
];
const APPROVAL_CHALLENGE_FIELDS = [
  "schema",
  "connection_id",
  "challenge_id",
  "challenge_request_id",
  "binding_sha256",
  "expires_at",
  "issued_at",
];

function requireSafeMilliseconds(value, field, code = "receipt_store_invalid") {
  if (!Number.isSafeInteger(value) || value < 0 || !Number.isFinite(new Date(value).getTime())) {
    fail(code, `${field} must be a nonnegative safe integer`, 500);
  }
  return value;
}

function approvalChallengeReference(authenticated) {
  return {
    schema: APPROVAL_CHALLENGE_V2_SCHEMA,
    connection_id: authenticated.connection_id,
    challenge_id: authenticated.approval.challenge_id,
    binding_sha256: authenticated.approval.binding_sha256,
    expires_at: authenticated.approval.expires_at,
  };
}

function buildReceiptCommit(authenticated, nowMs, { challengeToIssue } = {}) {
  return {
    schema: RECEIPT_COMMIT_V2_SCHEMA,
    connection_id: authenticated.connection_id,
    expected_generation: authenticated.expected_generation,
    node_counter: authenticated.node_counter,
    command_id: authenticated.command_id,
    request_sha256: authenticated.request_sha256,
    action: authenticated.action,
    now_ms: nowMs,
    ...(authenticated.is_expired ? { is_expired: true } : {}),
    ...(authenticated.approval_binding_is_expired ? { approval_binding_is_expired: true } : {}),
    ...(challengeToIssue ? { challenge_to_issue: challengeToIssue } : {}),
    ...(SENSITIVE_ACTIONS.has(authenticated.action)
      ? { approval_challenge: approvalChallengeReference(authenticated) }
      : {}),
  };
}

function validateStoredChallenge(challenge, authenticated, proposedChallenge) {
  exactKeys(challenge, APPROVAL_CHALLENGE_FIELDS, "receipt_store_invalid", "receipt.challenge");
  if (challenge.schema !== APPROVAL_CHALLENGE_V2_SCHEMA) {
    fail("receipt_store_invalid", "receipt challenge schema is invalid", 500);
  }
  if (requireString(challenge, "connection_id", ID_PATTERN, "receipt_store_invalid") !== authenticated.connection_id) {
    fail("receipt_store_invalid", "receipt challenge connection_id is invalid", 500);
  }
  requireId(challenge, "challenge_id", "receipt_store_invalid");
  if (requireId(challenge, "challenge_request_id", "receipt_store_invalid")
    !== authenticated.payload.challenge_request_id) {
    fail("receipt_store_invalid", "receipt challenge request id is invalid", 500);
  }
  if (requireString(challenge, "binding_sha256", SHA256_PATTERN, "receipt_store_invalid")
    !== canonicalApprovalBindingDigest(authenticated.approval_binding)) {
    fail("receipt_store_invalid", "receipt challenge binding is invalid", 500);
  }
  if (challenge.expires_at !== authenticated.approval_binding.expires_at) {
    fail("receipt_store_invalid", "receipt challenge expiry is invalid", 500);
  }
  parseCanonicalInstant(challenge.issued_at, "receipt.challenge.issued_at", "receipt_store_invalid");
  if (proposedChallenge && challenge.challenge_id !== proposedChallenge.challenge_id) {
    fail("receipt_store_invalid", "new receipt challenge id is invalid", 500);
  }
  return challenge;
}

function validateReceipt(receipt, authenticated, proposedChallenge) {
  if (!isRecord(receipt)) fail("receipt_store_invalid", "receipt store returned no receipt", 500);
  const allowed = new Set([...RECEIPT_FIELDS, "challenge"]);
  for (const key of Object.keys(receipt)) {
    if (!allowed.has(key)) fail("receipt_store_invalid", `receipt.${key} is not allowed`, 500);
  }
  for (const key of RECEIPT_FIELDS) {
    if (!Object.hasOwn(receipt, key)) fail("receipt_store_invalid", `receipt.${key} is required`, 500);
  }
  if (receipt.schema !== COMMAND_RECEIPT_V2_SCHEMA) {
    fail("receipt_store_invalid", "receipt schema is invalid", 500);
  }
  if (!new Set(["committed", "idempotent"]).has(receipt.disposition)) {
    fail("receipt_store_invalid", "receipt disposition is invalid", 500);
  }
  if (receipt.connection_id !== authenticated.connection_id
    || receipt.expected_generation !== authenticated.expected_generation
    || receipt.node_counter !== authenticated.node_counter
    || receipt.command_id !== authenticated.command_id
    || receipt.request_sha256 !== authenticated.request_sha256
    || receipt.action !== authenticated.action) {
    fail("receipt_store_invalid", "receipt does not bind this command", 500);
  }
  if (authenticated.action === "approval.challenge.request") {
    if (!Object.hasOwn(receipt, "challenge")) {
      fail("receipt_store_invalid", "challenge receipt is missing its challenge", 500);
    }
    return {
      ...receipt,
      challenge: validateStoredChallenge(
        receipt.challenge,
        authenticated,
        receipt.disposition === "committed" ? proposedChallenge : undefined,
      ),
    };
  }
  if (Object.hasOwn(receipt, "challenge")) {
    fail("receipt_store_invalid", "non-challenge receipt must not include a challenge", 500);
  }
  return receipt;
}

// This adapter is intentionally storage-agnostic so its DynamoDB transaction
// contract can be verified without AWS. `receiptStore.commit` owns one atomic
// operation: command-id idempotency/conflict detection, generation and monotonic
// counter fencing, immutable receipt write, and (for mutating commands) one-time
// approval challenge consumption. It receives all signed command identity fields
// rather than relying on process-local counters or a separate challenge consume.
export function createV2ChallengeApprovalService(options) {
  if (typeof options?.clock !== "function" || typeof options?.createChallengeId !== "function") {
    throw new TypeError("clock and createChallengeId are required");
  }
  if (typeof options?.receiptStore?.commit !== "function") {
    throw new TypeError("receiptStore.commit is required");
  }
  const {
    clock,
    createChallengeId,
    receiptStore,
    // Challenge lookups must be owned by the store rather than a process-global
    // configured id. Ignore a caller-supplied value to avoid bypassing that lookup.
    expectedChallengeId: _expectedChallengeId,
    ...authenticationOptions
  } = options;

  return {
    async accept(command) {
      const nowMs = clock();
      requireSafeMilliseconds(nowMs, "clock()");
      const authenticated = validateAndAuthenticateV2Command(command, {
        ...authenticationOptions,
        nowMs,
      }, { allowExpiredReplay: true });
      let proposedChallenge;
      if (authenticated.action === "approval.challenge.request") {
        const challengeId = createChallengeId({
          connection_id: authenticated.connection_id,
          challenge_request_id: authenticated.payload.challenge_request_id,
          binding_sha256: canonicalApprovalBindingDigest(authenticated.approval_binding),
        });
        if (typeof challengeId !== "string" || !ID_PATTERN.test(challengeId)) {
          fail("invalid_challenge_id", "challenge id factory returned an invalid challenge id", 500);
        }
        proposedChallenge = {
          schema: APPROVAL_CHALLENGE_V2_SCHEMA,
          connection_id: authenticated.connection_id,
          challenge_id: challengeId,
          challenge_request_id: authenticated.payload.challenge_request_id,
          binding_sha256: canonicalApprovalBindingDigest(authenticated.approval_binding),
          expires_at: authenticated.approval_binding.expires_at,
          issued_at: new Date(nowMs).toISOString(),
        };
      }
      const receipt = validateReceipt(
        await receiptStore.commit(buildReceiptCommit(authenticated, nowMs, { challengeToIssue: proposedChallenge })),
        authenticated,
        proposedChallenge,
      );
      if (receipt.disposition === "idempotent") {
        return {
          status: "idempotent",
          receipt,
          ...(authenticated.action === "approval.challenge.request" ? { challenge: receipt.challenge } : {}),
          ...(authenticated.action === "approval.challenge.request" ? {} : { command: authenticated }),
        };
      }
      if (authenticated.action === "approval.challenge.request") {
        return { status: "challenge_issued", challenge: receipt.challenge, receipt };
      }
      if (SENSITIVE_ACTIONS.has(authenticated.action)) {
        return {
          status: "approval_consumed",
          challenge: approvalChallengeReference(authenticated),
          receipt,
          command: authenticated,
        };
      }
      return { status: "read_only_validated", receipt, command: authenticated };
    },
  };
}
