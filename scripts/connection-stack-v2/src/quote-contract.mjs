import {
  ConnectionStackV2Error,
} from "./errors.mjs";

export const QUOTE_V1_SCHEMA = "dirextalk.aws.quote/v1";
export const QUOTE_VALIDITY_MS = 15 * 60 * 1000;
export const QUOTE_INCLUDED_ITEMS = Object.freeze(["ec2_linux_ondemand"]);
export const QUOTE_UNINCLUDED_ITEMS = Object.freeze([
  "cloudwatch_logs",
  "data_transfer",
  "ebs_gp3",
  "public_ipv4",
  "snapshots",
  "taxes",
]);

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const AVAILABILITY_ZONE_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/;
const INSTANCE_TYPE_PATTERN = /^[a-z0-9][a-z0-9.-]{1,63}$/;
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const ITEM_PATTERN = /^[a-z][a-z0-9_.-]{1,63}$/;
const TIERS = new Set(["economy", "recommended", "performance"]);
const ARCHITECTURES = new Set(["amd64", "arm64"]);
const MAX_UINT16 = 0xffff;
const MAX_UINT32 = 0xffffffff;
const QUOTE_REQUEST_FIELDS = ["quote_request_id", "plan_digest", "region", "candidates"];
const QUOTE_CANDIDATE_REQUEST_FIELDS = [
  "candidate_id",
  "tier",
  "instance_type",
  "purchase_option",
  "estimated_disk_gib",
];
const QUOTE_CANDIDATE_FIELDS = [
  ...QUOTE_CANDIDATE_REQUEST_FIELDS,
  "architecture",
  "vcpu",
  "memory_mib",
  "gpu_count",
  "gpu_memory_mib",
  "hourly_minor",
  "thirty_day_minor",
  "startup_upper_minor",
  "availability_zones",
];
const QUOTE_FIELDS = [
  "schema",
  "quote_id",
  "connection_id",
  "command_id",
  "request_sha256",
  "quote_request_id",
  "plan_digest",
  "region",
  "currency",
  "quoted_at",
  "valid_until",
  "candidates",
  "included_items",
  "unincluded_items",
];

function fail(code, message, statusCode) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(record, fields, code, statusCode, label) {
  if (!isRecord(record)) fail(code, `${label} must be an object`, statusCode);
  for (const key of Object.keys(record)) {
    if (!fields.includes(key)) fail(code, `${label}.${key} is not allowed`, statusCode);
  }
  for (const key of fields) {
    if (!Object.hasOwn(record, key)) fail(code, `${label}.${key} is required`, statusCode);
  }
}

function requireString(record, field, pattern, code, statusCode) {
  const value = record[field];
  if (typeof value !== "string" || !pattern.test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requireInteger(record, field, minimum, code, statusCode, maximum = Number.MAX_SAFE_INTEGER) {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function parseInstant(value, field, code, statusCode) {
  if (typeof value !== "string" || !ISO_INSTANT_PATTERN.test(value)) {
    fail(code, `${field} is not a canonical UTC timestamp`, statusCode);
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== value) {
    fail(code, `${field} is not a canonical UTC timestamp`, statusCode);
  }
  return parsed;
}

function canonicalStrings(value, field, pattern, code, statusCode, { nonempty = false } = {}) {
  if (!Array.isArray(value) || (nonempty && value.length === 0)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  const copy = [];
  let previous = "";
  for (const item of value) {
    if (typeof item !== "string" || !pattern.test(item) || (previous !== "" && previous >= item)) {
      fail(code, `${field} must be strictly sorted and unique`, statusCode);
    }
    previous = item;
    copy.push(item);
  }
  return copy;
}

function sameStrings(actual, expected) {
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}

function normalizeQuoteCandidateRequest(value, code, statusCode) {
  exactKeys(value, QUOTE_CANDIDATE_REQUEST_FIELDS, code, statusCode, "quote candidate");
  const candidate = {
    candidate_id: requireString(value, "candidate_id", ID_PATTERN, code, statusCode),
    tier: requireString(value, "tier", /^[a-z]+$/, code, statusCode),
    instance_type: requireString(value, "instance_type", INSTANCE_TYPE_PATTERN, code, statusCode),
    purchase_option: requireString(value, "purchase_option", /^[a-z_]+$/, code, statusCode),
    estimated_disk_gib: requireInteger(value, "estimated_disk_gib", 8, code, statusCode),
  };
  if (!TIERS.has(candidate.tier)) fail(code, "tier is invalid", statusCode);
  if (candidate.purchase_option !== "on_demand") {
    fail("spot_quote_not_enabled", "only on-demand quote candidates are enabled", 409);
  }
  if (candidate.estimated_disk_gib > 16384) {
    fail(code, "estimated_disk_gib is invalid", statusCode);
  }
  return candidate;
}

function normalizeQuoteRequest(payload, code, statusCode) {
  exactKeys(payload, QUOTE_REQUEST_FIELDS, code, statusCode, "quote request");
  const request = {
    quote_request_id: requireString(payload, "quote_request_id", ID_PATTERN, code, statusCode),
    plan_digest: requireString(payload, "plan_digest", /^sha256:[0-9a-f]{64}$/, code, statusCode),
    region: requireString(payload, "region", REGION_PATTERN, code, statusCode),
  };
  if (!Array.isArray(payload.candidates) || payload.candidates.length < 1 || payload.candidates.length > 3) {
    fail(code, "quote request candidates must contain one to three entries", statusCode);
  }
  const seenIDs = new Set();
  const seenTiers = new Set();
  request.candidates = payload.candidates.map((candidate) => {
    const normalized = normalizeQuoteCandidateRequest(candidate, code, statusCode);
    if (seenIDs.has(normalized.candidate_id) || seenTiers.has(normalized.tier)) {
      fail(code, "quote request candidates must not duplicate ids or tiers", statusCode);
    }
    seenIDs.add(normalized.candidate_id);
    seenTiers.add(normalized.tier);
    return normalized;
  });
  return request;
}

export function validateQuoteRequestPayload(payload) {
  return normalizeQuoteRequest(payload, "invalid_payload", 400);
}

export function quoteIDForRequest(request) {
  const requestSHA256 = requireString(request, "request_sha256", SHA256_PATTERN, "receipt_store_invalid", 500);
  return `quote-${requestSHA256.slice(0, 32)}`;
}

function requestIdentity(request, code, statusCode) {
  if (!isRecord(request)) fail(code, "quote request context is invalid", statusCode);
  return {
    connection_id: requireString(request, "connection_id", ID_PATTERN, code, statusCode),
    command_id: requireString(request, "command_id", ID_PATTERN, code, statusCode),
    request_sha256: requireString(request, "request_sha256", SHA256_PATTERN, code, statusCode),
    quote_request: normalizeQuoteRequest(request.quote_request, code, statusCode),
    ...(Number.isSafeInteger(request.now_ms) ? { now_ms: request.now_ms } : {}),
    ...(typeof request.issued_at === "string" ? { issued_at: request.issued_at } : {}),
    ...(typeof request.expires_at === "string" ? { expires_at: request.expires_at } : {}),
  };
}

function normalizeQuoteCandidate(value, expected, code, statusCode) {
  exactKeys(value, QUOTE_CANDIDATE_FIELDS, code, statusCode, "quote candidate");
  const candidate = {
    candidate_id: requireString(value, "candidate_id", ID_PATTERN, code, statusCode),
    tier: requireString(value, "tier", /^[a-z]+$/, code, statusCode),
    instance_type: requireString(value, "instance_type", INSTANCE_TYPE_PATTERN, code, statusCode),
    architecture: requireString(value, "architecture", /^[a-z0-9]+$/, code, statusCode),
    vcpu: requireInteger(value, "vcpu", 1, code, statusCode, MAX_UINT16),
    memory_mib: requireInteger(value, "memory_mib", 1, code, statusCode, MAX_UINT32),
    gpu_count: requireInteger(value, "gpu_count", 0, code, statusCode, MAX_UINT16),
    gpu_memory_mib: requireInteger(value, "gpu_memory_mib", 0, code, statusCode, MAX_UINT32),
    purchase_option: requireString(value, "purchase_option", /^[a-z_]+$/, code, statusCode),
    estimated_disk_gib: requireInteger(value, "estimated_disk_gib", 8, code, statusCode),
    hourly_minor: requireInteger(value, "hourly_minor", 0, code, statusCode),
    thirty_day_minor: requireInteger(value, "thirty_day_minor", 0, code, statusCode),
    startup_upper_minor: requireInteger(value, "startup_upper_minor", 0, code, statusCode),
    availability_zones: canonicalStrings(value.availability_zones, "availability_zones", AVAILABILITY_ZONE_PATTERN, code, statusCode, { nonempty: true }),
  };
  if (!ARCHITECTURES.has(candidate.architecture)) {
    fail(code, "architecture is invalid", statusCode);
  }
  if ((candidate.gpu_count === 0) !== (candidate.gpu_memory_mib === 0)) {
    fail(code, "gpu count and memory must agree", statusCode);
  }
  if (candidate.candidate_id !== expected.candidate_id || candidate.tier !== expected.tier
    || candidate.instance_type !== expected.instance_type || candidate.purchase_option !== expected.purchase_option
    || candidate.estimated_disk_gib !== expected.estimated_disk_gib) {
    fail(code, "quote candidate does not bind the requested resource", statusCode);
  }
  return candidate;
}

function normalizeQuote(quote, request, code, statusCode, { requireQuotedAtNow } = {}) {
  exactKeys(quote, QUOTE_FIELDS, code, statusCode, "quote");
  const identity = requestIdentity(request, code, statusCode);
  const normalized = {
    schema: requireString(quote, "schema", /^dirextalk\.aws\.quote\/v1$/, code, statusCode),
    quote_id: requireString(quote, "quote_id", ID_PATTERN, code, statusCode),
    connection_id: requireString(quote, "connection_id", ID_PATTERN, code, statusCode),
    command_id: requireString(quote, "command_id", ID_PATTERN, code, statusCode),
    request_sha256: requireString(quote, "request_sha256", SHA256_PATTERN, code, statusCode),
    quote_request_id: requireString(quote, "quote_request_id", ID_PATTERN, code, statusCode),
    plan_digest: requireString(quote, "plan_digest", /^sha256:[0-9a-f]{64}$/, code, statusCode),
    region: requireString(quote, "region", REGION_PATTERN, code, statusCode),
    currency: requireString(quote, "currency", /^[A-Z]{3}$/, code, statusCode),
    quoted_at: requireString(quote, "quoted_at", ISO_INSTANT_PATTERN, code, statusCode),
    valid_until: requireString(quote, "valid_until", ISO_INSTANT_PATTERN, code, statusCode),
  };
  if (normalized.schema !== QUOTE_V1_SCHEMA || normalized.currency !== "USD") {
    fail(code, "quote schema or currency is invalid", statusCode);
  }
  if (normalized.quote_id !== quoteIDForRequest(identity)
    || normalized.connection_id !== identity.connection_id
    || normalized.command_id !== identity.command_id
    || normalized.request_sha256 !== identity.request_sha256
    || normalized.quote_request_id !== identity.quote_request.quote_request_id
    || normalized.plan_digest !== identity.quote_request.plan_digest
    || normalized.region !== identity.quote_request.region) {
    fail(code, "quote does not bind the signed request", statusCode);
  }
  const quotedAt = parseInstant(normalized.quoted_at, "quoted_at", code, statusCode);
  const validUntil = parseInstant(normalized.valid_until, "valid_until", code, statusCode);
  if (validUntil - quotedAt !== QUOTE_VALIDITY_MS) {
    fail(code, "quote validity window is invalid", statusCode);
  }
  if (requireQuotedAtNow && quotedAt !== identity.now_ms) {
    fail(code, "quote timestamp does not bind receipt acceptance", statusCode);
  }
  if (identity.issued_at !== undefined && quotedAt < parseInstant(identity.issued_at, "issued_at", code, statusCode)) {
    fail(code, "quote predates its signed command", statusCode);
  }
  if (identity.expires_at !== undefined && quotedAt > parseInstant(identity.expires_at, "expires_at", code, statusCode)) {
    fail(code, "quote was issued after its signed command expired", statusCode);
  }
  if (!Array.isArray(quote.candidates) || quote.candidates.length !== identity.quote_request.candidates.length) {
    fail(code, "quote candidates do not match the request", statusCode);
  }
  normalized.candidates = quote.candidates.map((candidate, index) => normalizeQuoteCandidate(
    candidate,
    identity.quote_request.candidates[index],
    code,
    statusCode,
  ));
  normalized.included_items = canonicalStrings(quote.included_items, "included_items", ITEM_PATTERN, code, statusCode, { nonempty: true });
  normalized.unincluded_items = canonicalStrings(quote.unincluded_items, "unincluded_items", ITEM_PATTERN, code, statusCode, { nonempty: true });
  if (!sameStrings(normalized.included_items, QUOTE_INCLUDED_ITEMS) || !sameStrings(normalized.unincluded_items, QUOTE_UNINCLUDED_ITEMS)) {
    fail(code, "quote cost coverage is invalid", statusCode);
  }
  return normalized;
}

export function validateIssuedQuote(quote, request) {
  return normalizeQuote(quote, request, "receipt_store_invalid", 500, { requireQuotedAtNow: true });
}

export function validateStoredQuote(quote, authenticatedCommand) {
  return normalizeQuote(quote, {
    connection_id: authenticatedCommand.connection_id,
    command_id: authenticatedCommand.command_id,
    request_sha256: authenticatedCommand.request_sha256,
    quote_request: authenticatedCommand.payload,
    issued_at: authenticatedCommand.issued_at,
    expires_at: authenticatedCommand.expires_at,
  }, "receipt_store_invalid", 500, { requireQuotedAtNow: false });
}
