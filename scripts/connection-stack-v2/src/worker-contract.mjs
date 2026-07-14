import {
  ConnectionStackV2Error,
  WORKER_BOOTSTRAP_V1_SCHEMA,
} from "./command-contract.mjs";

const FIELDS = [
  "schema",
  "connection_id",
  "deployment_id",
  "bootstrap_session_id",
  "bootstrap_endpoint",
  "worker_image_digest",
  "artifact_manifest_digest",
  "expires_at",
];
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const MAX_WORKER_BOOTSTRAP_LIFETIME_MS = 10 * 60 * 1000;

function fail(message) {
  throw new ConnectionStackV2Error("invalid_worker_manifest", message);
}

function requireString(record, key, pattern) {
  const value = record[key];
  if (typeof value !== "string" || !pattern.test(value)) fail(`${key} is invalid`);
  return value;
}

function parseHTTPSBrokerEndpoint(value, label) {
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    fail(`${label} is invalid`);
  }
  if (endpoint.protocol !== "https:" || !endpoint.hostname || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    fail(`${label} must be an HTTPS endpoint without credentials, query, or fragment`);
  }
  return endpoint;
}

function validateVerificationContext(context) {
  if (context === null || typeof context !== "object" || Array.isArray(context)) {
    fail("worker verification context is required");
  }
  const { nowMs, maxLifetimeMs, expectedConnectionId, expectedBootstrapEndpoint } = context;
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) fail("nowMs is invalid");
  if (!Number.isSafeInteger(maxLifetimeMs) || maxLifetimeMs < 1 || maxLifetimeMs > MAX_WORKER_BOOTSTRAP_LIFETIME_MS) {
    fail("maxLifetimeMs is invalid");
  }
  if (typeof expectedConnectionId !== "string" || !ID_PATTERN.test(expectedConnectionId)) {
    fail("expectedConnectionId is invalid");
  }
  return {
    nowMs,
    maxLifetimeMs,
    expectedConnectionId,
    expectedBootstrapEndpoint: parseHTTPSBrokerEndpoint(expectedBootstrapEndpoint, "expectedBootstrapEndpoint"),
  };
}

export function validateWorkerBootstrapManifest(manifest, verificationContext) {
  const verification = validateVerificationContext(verificationContext);
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
    fail("worker manifest must be an object");
  }
  for (const key of Object.keys(manifest)) {
    if (!FIELDS.includes(key)) fail(`${key} is not allowed`);
  }
  for (const key of FIELDS) {
    if (!Object.hasOwn(manifest, key)) fail(`${key} is required`);
  }
  if (manifest.schema !== WORKER_BOOTSTRAP_V1_SCHEMA) fail("worker manifest schema is invalid");
  const connectionId = requireString(manifest, "connection_id", ID_PATTERN);
  if (connectionId !== verification.expectedConnectionId) {
    fail("connection_id does not match the expected connection");
  }
  requireString(manifest, "deployment_id", ID_PATTERN);
  requireString(manifest, "bootstrap_session_id", ID_PATTERN);
  requireString(manifest, "worker_image_digest", DIGEST_PATTERN);
  requireString(manifest, "artifact_manifest_digest", DIGEST_PATTERN);
  const expiresAt = requireString(manifest, "expires_at", ISO_INSTANT_PATTERN);
  const parsedExpiry = Date.parse(expiresAt);
  if (!Number.isFinite(parsedExpiry) || new Date(parsedExpiry).toISOString() !== expiresAt) {
    fail("expires_at is not a canonical UTC timestamp");
  }
  if (parsedExpiry <= verification.nowMs) {
    fail("worker bootstrap manifest has expired");
  }
  if (parsedExpiry - verification.nowMs > verification.maxLifetimeMs) {
    fail("worker bootstrap manifest exceeds its maximum lifetime");
  }
  const endpoint = parseHTTPSBrokerEndpoint(manifest.bootstrap_endpoint, "bootstrap_endpoint");
  if (endpoint.href !== verification.expectedBootstrapEndpoint.href) {
    fail("bootstrap_endpoint does not match the expected broker endpoint");
  }
  return Object.fromEntries(FIELDS.map((key) => [key, manifest[key]]));
}
