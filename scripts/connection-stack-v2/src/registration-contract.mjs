import {
  createPublicKey,
} from "node:crypto";

import {
  ConnectionStackV2Error,
} from "./errors.mjs";

export const CONNECTION_REGISTRATION_VERIFY_ACTION = "connection.registration.verify";
export const CONNECTION_REGISTRATION_V1_SCHEMA = "dirextalk.aws.connection-registration/v1";
export const CONNECTION_STACK_DEPLOY_REQUEST_V1_SCHEMA = "dirextalk.aws.connection-stack-deploy-request/v1";
export const CONNECTION_REGISTRATION_MANIFEST_V1_SCHEMA = "dirextalk.aws.connection-registration-manifest/v1";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ACCOUNT_ID_PATTERN = /^\d{12}$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const STACK_NAME_PATTERN = /^[A-Za-z][-A-Za-z0-9]{0,127}$/;
const STAGE_NAME_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const AMI_ID_PATTERN = /^ami-[0-9a-f]{8,17}$/;
const VPC_ID_PATTERN = /^vpc-[0-9a-f]{8,17}$/;
const SUBNET_ID_PATTERN = /^subnet-[0-9a-f]{8,17}$/;
const AVAILABILITY_ZONE_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const URL_SUFFIX_PATTERN = /^[a-z0-9][a-z0-9.-]{1,126}[a-z0-9]$/;

const REGISTRATION_PAYLOAD_FIELDS = ["bootstrap_id", "requested_region", "stack_arn"];
const REGISTRATION_FIELDS = [
  "schema",
  "bootstrap_id",
  "connection_id",
  "account_id",
  "region",
  "broker_command_url",
  "node_key_id",
  "connection_generation",
  "worker_artifact",
  "worker_network",
  "worker_resource_manifest_digest",
  "stack_arn",
  "command_id",
  "request_sha256",
];
const DEPLOY_REQUEST_FIELDS = [
  "schema",
  "bootstrap_id",
  "stack_name",
  "connection_id",
  "connection_generation",
  "requested_region",
  "node_key_id",
  "node_public_key_spki_b64",
  "device_approval_key_id",
  "device_approval_public_key_spki_b64",
  "stage_name",
  "worker_base_ami_id",
  "worker_vpc_id",
  "worker_subnet_id",
  "worker_availability_zone",
  "worker_resource_manifest_digest",
  "template_sha256",
  "source_tree_sha256",
];
const MANIFEST_FIELDS = [
  "schema",
  "bootstrap_id",
  "connection_id",
  "account_id",
  "region",
  "broker_command_url",
  "node_key_id",
  "connection_generation",
  "worker_artifact",
  "worker_network",
  "worker_resource_manifest_digest",
  "stack_arn",
];
const STACK_OUTPUT_FIELDS = new Set([
  "ConnectionId",
  "ConnectionGeneration",
  "AccountId",
  "Region",
  "NodeKeyId",
  "WorkerBaseAmiId",
  "WorkerVpcId",
  "WorkerSubnetId",
  "WorkerAvailabilityZone",
  "WorkerResourceManifestDigest",
  "BrokerCommandUrl",
  "StackArn",
]);

function fail(code, message, statusCode = 400) {
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

function requireInteger(record, field, minimum, code, statusCode) {
  const value = record[field];
  if (!Number.isSafeInteger(value) || value < minimum) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function requireEd25519PublicKey(record, field, code, statusCode) {
  const value = requireString(record, field, BASE64_PATTERN, code, statusCode);
  if (value.length < 56 || value.length > 256 || value.length % 4 !== 0) {
    fail(code, `${field} is invalid`, statusCode);
  }
  const der = Buffer.from(value, "base64");
  if (der.toString("base64") !== value) fail(code, `${field} is invalid`, statusCode);
  try {
    const publicKey = createPublicKey({ key: der, format: "der", type: "spki" });
    if (publicKey.asymmetricKeyType !== "ed25519") fail(code, `${field} is not an Ed25519 public key`, statusCode);
  } catch (error) {
    if (error instanceof ConnectionStackV2Error) throw error;
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function stackArnPattern(accountId, region) {
  return new RegExp(`^arn:(?:aws|aws-cn|aws-us-gov):cloudformation:${escapeRegExp(region)}:${accountId}:stack/[A-Za-z][-A-Za-z0-9]{0,127}/[A-Za-z0-9-]{8,128}$`);
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function validateStackArn(value, { accountId, region, code, statusCode, field = "stack_arn" }) {
  if (typeof value !== "string" || !stackArnPattern(accountId, region).test(value)) {
    fail(code, `${field} is invalid`, statusCode);
  }
  return value;
}

function validateBrokerCommandURL(value, { region, urlSuffix, stageName, code, statusCode }) {
  if (typeof value !== "string" || value.length > 512) {
    fail(code, "broker_command_url is invalid", statusCode);
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail(code, "broker_command_url is invalid", statusCode);
  }
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.search || parsed.hash) {
    fail(code, "broker_command_url is invalid", statusCode);
  }
  const suffixes = urlSuffix ? [urlSuffix] : ["amazonaws.com", "amazonaws.com.cn"];
  const accepted = suffixes.some((suffix) => {
    const expectedSuffix = `.execute-api.${region}.${suffix}`;
    if (!parsed.hostname.endsWith(expectedSuffix)) return false;
    const apiId = parsed.hostname.slice(0, -expectedSuffix.length);
    return /^[a-z0-9]{10}$/.test(apiId);
  });
  if (!accepted || parsed.pathname !== `/${stageName}/v2/commands`) {
    fail(code, "broker_command_url is invalid", statusCode);
  }
  if (parsed.toString() !== value) fail(code, "broker_command_url is invalid", statusCode);
  return value;
}

function canonicalRegistration(record) {
  return Object.fromEntries(REGISTRATION_FIELDS.map((field) => [field, record[field]]));
}

function canonicalManifest(record) {
  return Object.fromEntries(MANIFEST_FIELDS.map((field) => [field, record[field]]));
}

function validateWorkerArtifact(value, code, statusCode) {
  exactKeys(value, ["kind", "ami_id"], code, statusCode, "worker_artifact");
  if (value.kind !== "fixed_ami") fail(code, "worker_artifact.kind is invalid", statusCode);
  return {
    kind: "fixed_ami",
    ami_id: requireString(value, "ami_id", AMI_ID_PATTERN, code, statusCode),
  };
}

function validateWorkerNetwork(value, code, statusCode) {
  exactKeys(value, ["vpc_id", "subnet_id", "availability_zone"], code, statusCode, "worker_network");
  return {
    vpc_id: requireString(value, "vpc_id", VPC_ID_PATTERN, code, statusCode),
    subnet_id: requireString(value, "subnet_id", SUBNET_ID_PATTERN, code, statusCode),
    availability_zone: requireString(value, "availability_zone", AVAILABILITY_ZONE_PATTERN, code, statusCode),
  };
}

function workerConfigurationFromDeployRequest(request, code, statusCode) {
  return {
    worker_artifact: {
      kind: "fixed_ami",
      ami_id: requireString(request, "worker_base_ami_id", AMI_ID_PATTERN, code, statusCode),
    },
    worker_network: {
      vpc_id: requireString(request, "worker_vpc_id", VPC_ID_PATTERN, code, statusCode),
      subnet_id: requireString(request, "worker_subnet_id", SUBNET_ID_PATTERN, code, statusCode),
      availability_zone: requireString(request, "worker_availability_zone", AVAILABILITY_ZONE_PATTERN, code, statusCode),
    },
    worker_resource_manifest_digest: requireString(request, "worker_resource_manifest_digest", NAMED_SHA256_PATTERN, code, statusCode),
  };
}

export function validateRegistrationVerifyPayload(payload, { code = "invalid_payload", statusCode = 400 } = {}) {
  exactKeys(payload, REGISTRATION_PAYLOAD_FIELDS, code, statusCode, "payload");
  requireString(payload, "bootstrap_id", ID_PATTERN, code, statusCode);
  requireString(payload, "requested_region", REGION_PATTERN, code, statusCode);
  if (typeof payload.stack_arn !== "string" || payload.stack_arn.length > 512) {
    fail(code, "stack_arn is invalid", statusCode);
  }
  return Object.fromEntries(REGISTRATION_PAYLOAD_FIELDS.map((field) => [field, payload[field]]));
}

export function validateConnectionRegistrationConfig(config, { code = "registration_config_invalid", statusCode = 500 } = {}) {
  const fields = [
    "account_id",
    "region",
    "stack_arn",
    "api_gateway_url_suffix",
    "stage_name",
    "worker_artifact",
    "worker_network",
    "worker_resource_manifest_digest",
  ];
  exactKeys(config, fields, code, statusCode, "registration_config");
  const accountId = requireString(config, "account_id", ACCOUNT_ID_PATTERN, code, statusCode);
  const region = requireString(config, "region", REGION_PATTERN, code, statusCode);
  const stackArn = validateStackArn(config.stack_arn, { accountId, region, code, statusCode });
  const urlSuffix = requireString(config, "api_gateway_url_suffix", URL_SUFFIX_PATTERN, code, statusCode);
  const stageName = requireString(config, "stage_name", STAGE_NAME_PATTERN, code, statusCode);
  return {
    account_id: accountId,
    region,
    stack_arn: stackArn,
    api_gateway_url_suffix: urlSuffix,
    stage_name: stageName,
    worker_artifact: validateWorkerArtifact(config.worker_artifact, code, statusCode),
    worker_network: validateWorkerNetwork(config.worker_network, code, statusCode),
    worker_resource_manifest_digest: requireString(config, "worker_resource_manifest_digest", NAMED_SHA256_PATTERN, code, statusCode),
  };
}

export function buildConnectionRegistration(authenticated, config, runtimeContext, { code = "registration_config_invalid", statusCode = 500 } = {}) {
  const configured = validateConnectionRegistrationConfig(config, { code, statusCode });
  const payload = validateRegistrationVerifyPayload(authenticated?.payload, { code: "invalid_payload", statusCode: 400 });
  if (payload.requested_region !== configured.region) {
    fail("registration_region_mismatch", "requested_region does not match this stack", 409);
  }
  if (payload.stack_arn !== configured.stack_arn) {
    fail("registration_stack_mismatch", "stack_arn does not match this stack", 409);
  }
  if (!isRecord(runtimeContext) || Object.keys(runtimeContext).length !== 1 || typeof runtimeContext.broker_command_url !== "string") {
    fail(code, "registration runtime context is unavailable", statusCode);
  }
  const connectionId = requireString(authenticated, "connection_id", ID_PATTERN, code, statusCode);
  const nodeKeyId = requireString(authenticated, "node_key_id", KEY_ID_PATTERN, code, statusCode);
  const commandId = requireString(authenticated, "command_id", ID_PATTERN, code, statusCode);
  const requestSha256 = requireString(authenticated, "request_sha256", SHA256_PATTERN, code, statusCode);
  const generation = authenticated.expected_generation;
  if (!Number.isSafeInteger(generation) || generation < 1) {
    fail(code, "expected_generation is invalid", statusCode);
  }
  const brokerCommandURL = validateBrokerCommandURL(runtimeContext.broker_command_url, {
    region: configured.region,
    urlSuffix: configured.api_gateway_url_suffix,
    stageName: configured.stage_name,
    code,
    statusCode,
  });
  return {
    schema: CONNECTION_REGISTRATION_V1_SCHEMA,
    bootstrap_id: payload.bootstrap_id,
    connection_id: connectionId,
    account_id: configured.account_id,
    region: configured.region,
    broker_command_url: brokerCommandURL,
    node_key_id: nodeKeyId,
    connection_generation: generation,
    worker_artifact: configured.worker_artifact,
    worker_network: configured.worker_network,
    worker_resource_manifest_digest: configured.worker_resource_manifest_digest,
    stack_arn: configured.stack_arn,
    command_id: commandId,
    request_sha256: requestSha256,
  };
}

export function validateConnectionRegistration(record, {
  connectionId,
  connectionGeneration,
  commandId,
  requestSha256,
  code = "invalid_registration",
  statusCode = 400,
} = {}) {
  exactKeys(record, REGISTRATION_FIELDS, code, statusCode, "registration");
  if (record.schema !== CONNECTION_REGISTRATION_V1_SCHEMA) {
    fail(code, "registration schema is invalid", statusCode);
  }
  const bootstrapId = requireString(record, "bootstrap_id", ID_PATTERN, code, statusCode);
  const actualConnectionId = requireString(record, "connection_id", ID_PATTERN, code, statusCode);
  const accountId = requireString(record, "account_id", ACCOUNT_ID_PATTERN, code, statusCode);
  const region = requireString(record, "region", REGION_PATTERN, code, statusCode);
  const nodeKeyId = requireString(record, "node_key_id", KEY_ID_PATTERN, code, statusCode);
  const generation = requireInteger(record, "connection_generation", 1, code, statusCode);
  const workerArtifact = validateWorkerArtifact(record.worker_artifact, code, statusCode);
  const workerNetwork = validateWorkerNetwork(record.worker_network, code, statusCode);
  const workerResourceManifestDigest = requireString(record, "worker_resource_manifest_digest", NAMED_SHA256_PATTERN, code, statusCode);
  const stackArn = validateStackArn(record.stack_arn, { accountId, region, code, statusCode });
  const actualCommandId = requireString(record, "command_id", ID_PATTERN, code, statusCode);
  const actualRequestSha256 = requireString(record, "request_sha256", SHA256_PATTERN, code, statusCode);
  const brokerCommandURL = validateBrokerCommandURL(record.broker_command_url, {
    region,
    stageName: inferStageName(record.broker_command_url, region),
    code,
    statusCode,
  });
  if (connectionId !== undefined && actualConnectionId !== connectionId) {
    fail(code, "registration connection_id does not match receipt", statusCode);
  }
  if (connectionGeneration !== undefined && generation !== connectionGeneration) {
    fail(code, "registration connection_generation does not match receipt", statusCode);
  }
  if (commandId !== undefined && actualCommandId !== commandId) {
    fail(code, "registration command_id does not match receipt", statusCode);
  }
  if (requestSha256 !== undefined && actualRequestSha256 !== requestSha256) {
    fail(code, "registration request_sha256 does not match receipt", statusCode);
  }
  return canonicalRegistration({
    ...record,
    bootstrap_id: bootstrapId,
    connection_id: actualConnectionId,
    account_id: accountId,
    region,
    broker_command_url: brokerCommandURL,
    node_key_id: nodeKeyId,
    connection_generation: generation,
    worker_artifact: workerArtifact,
    worker_network: workerNetwork,
    worker_resource_manifest_digest: workerResourceManifestDigest,
    stack_arn: stackArn,
    command_id: actualCommandId,
    request_sha256: actualRequestSha256,
  });
}

function inferStageName(url, region) {
  if (typeof url !== "string") return "";
  try {
    const parsed = new URL(url);
    const suffixes = ["amazonaws.com", "amazonaws.com.cn"];
    if (!suffixes.some((suffix) => parsed.hostname.endsWith(`.execute-api.${region}.${suffix}`))) return "";
    const match = parsed.pathname.match(/^\/([A-Za-z0-9_-]{1,32})\/v2\/commands$/);
    return match?.[1] || "";
  } catch {
    return "";
  }
}

export function validateConnectionStackDeployRequest(request, { templateSha256, sourceTreeSha256 } = {}) {
  const code = "invalid_connection_stack_deploy_request";
  exactKeys(request, DEPLOY_REQUEST_FIELDS, code, 400, "deploy_request");
  if (request.schema !== CONNECTION_STACK_DEPLOY_REQUEST_V1_SCHEMA) {
    fail(code, "deploy_request schema is invalid");
  }
  requireString(request, "bootstrap_id", ID_PATTERN, code, 400);
  requireString(request, "stack_name", STACK_NAME_PATTERN, code, 400);
  requireString(request, "connection_id", ID_PATTERN, code, 400);
  requireInteger(request, "connection_generation", 1, code, 400);
  requireString(request, "requested_region", REGION_PATTERN, code, 400);
  requireString(request, "node_key_id", KEY_ID_PATTERN, code, 400);
  requireEd25519PublicKey(request, "node_public_key_spki_b64", code, 400);
  requireString(request, "device_approval_key_id", KEY_ID_PATTERN, code, 400);
  requireEd25519PublicKey(request, "device_approval_public_key_spki_b64", code, 400);
  requireString(request, "stage_name", STAGE_NAME_PATTERN, code, 400);
  workerConfigurationFromDeployRequest(request, code, 400);
  const digest = requireString(request, "template_sha256", NAMED_SHA256_PATTERN, code, 400);
  if (templateSha256 !== undefined && digest !== templateSha256) {
    fail("connection_stack_template_digest_mismatch", "the requested Connection Stack template digest does not match this pinned artifact", 409);
  }
  const sourceDigest = requireString(request, "source_tree_sha256", NAMED_SHA256_PATTERN, code, 400);
  if (sourceTreeSha256 !== undefined && sourceDigest !== sourceTreeSha256) {
    fail("connection_stack_source_digest_mismatch", "the requested Connection Stack source digest does not match this pinned artifact", 409);
  }
  return Object.fromEntries(DEPLOY_REQUEST_FIELDS.map((field) => [field, request[field]]));
}

export function buildConnectionRegistrationManifest(request, bootstrapIdentity, stackDescription) {
  const validatedRequest = validateConnectionStackDeployRequest(request);
  const accountId = requireString(bootstrapIdentity, "account_id", ACCOUNT_ID_PATTERN, "invalid_bootstrap_identity", 403);
  const stack = Array.isArray(stackDescription?.Stacks) ? stackDescription.Stacks[0] : undefined;
  if (!isRecord(stack)) fail("invalid_connection_stack_output", "Connection Stack description is invalid", 502);
  const stackArn = validateStackArn(stack.StackId, {
    accountId,
    region: validatedRequest.requested_region,
    code: "invalid_connection_stack_output",
    statusCode: 502,
    field: "StackId",
  });
  if (!Array.isArray(stack.Outputs)) fail("invalid_connection_stack_output", "Connection Stack outputs are invalid", 502);
  const outputs = new Map();
  for (const output of stack.Outputs) {
    if (!isRecord(output) || typeof output.OutputKey !== "string" || typeof output.OutputValue !== "string"
      || !STACK_OUTPUT_FIELDS.has(output.OutputKey) || outputs.has(output.OutputKey)) {
      fail("invalid_connection_stack_output", "Connection Stack outputs are invalid", 502);
    }
    outputs.set(output.OutputKey, output.OutputValue);
  }
  if (outputs.size !== STACK_OUTPUT_FIELDS.size) {
    fail("invalid_connection_stack_output", "Connection Stack outputs are incomplete", 502);
  }
  const output = (key) => {
    const value = outputs.get(key);
    if (value === undefined) fail("invalid_connection_stack_output", `Connection Stack output ${key} is missing`, 502);
    return value;
  };
  if (output("ConnectionId") !== validatedRequest.connection_id
    || output("ConnectionGeneration") !== String(validatedRequest.connection_generation)
    || output("AccountId") !== accountId
    || output("Region") !== validatedRequest.requested_region
    || output("NodeKeyId") !== validatedRequest.node_key_id
    || output("WorkerBaseAmiId") !== validatedRequest.worker_base_ami_id
    || output("WorkerVpcId") !== validatedRequest.worker_vpc_id
    || output("WorkerSubnetId") !== validatedRequest.worker_subnet_id
    || output("WorkerAvailabilityZone") !== validatedRequest.worker_availability_zone
    || output("WorkerResourceManifestDigest") !== validatedRequest.worker_resource_manifest_digest
    || output("StackArn") !== stackArn) {
    fail("connection_stack_output_mismatch", "Connection Stack outputs do not match the signed deployment request", 409);
  }
  const brokerCommandURL = validateBrokerCommandURL(output("BrokerCommandUrl"), {
    region: validatedRequest.requested_region,
    stageName: validatedRequest.stage_name,
    code: "invalid_connection_stack_output",
    statusCode: 502,
  });
  return canonicalManifest({
    schema: CONNECTION_REGISTRATION_MANIFEST_V1_SCHEMA,
    bootstrap_id: validatedRequest.bootstrap_id,
    connection_id: validatedRequest.connection_id,
    account_id: accountId,
    region: validatedRequest.requested_region,
    broker_command_url: brokerCommandURL,
    node_key_id: validatedRequest.node_key_id,
    connection_generation: validatedRequest.connection_generation,
    worker_artifact: {
      kind: "fixed_ami",
      ami_id: validatedRequest.worker_base_ami_id,
    },
    worker_network: {
      vpc_id: validatedRequest.worker_vpc_id,
      subnet_id: validatedRequest.worker_subnet_id,
      availability_zone: validatedRequest.worker_availability_zone,
    },
    worker_resource_manifest_digest: validatedRequest.worker_resource_manifest_digest,
    stack_arn: stackArn,
  });
}

export function validateConnectionRegistrationManifest(manifest) {
  const code = "invalid_connection_registration_manifest";
  exactKeys(manifest, MANIFEST_FIELDS, code, 400, "registration_manifest");
  if (manifest.schema !== CONNECTION_REGISTRATION_MANIFEST_V1_SCHEMA) {
    fail(code, "registration_manifest schema is invalid");
  }
  const bootstrapId = requireString(manifest, "bootstrap_id", ID_PATTERN, code, 400);
  const connectionId = requireString(manifest, "connection_id", ID_PATTERN, code, 400);
  const accountId = requireString(manifest, "account_id", ACCOUNT_ID_PATTERN, code, 400);
  const region = requireString(manifest, "region", REGION_PATTERN, code, 400);
  const nodeKeyId = requireString(manifest, "node_key_id", KEY_ID_PATTERN, code, 400);
  const generation = requireInteger(manifest, "connection_generation", 1, code, 400);
  const workerArtifact = validateWorkerArtifact(manifest.worker_artifact, code, 400);
  const workerNetwork = validateWorkerNetwork(manifest.worker_network, code, 400);
  const workerResourceManifestDigest = requireString(manifest, "worker_resource_manifest_digest", NAMED_SHA256_PATTERN, code, 400);
  const stackArn = validateStackArn(manifest.stack_arn, { accountId, region, code, statusCode: 400 });
  const brokerCommandURL = validateBrokerCommandURL(manifest.broker_command_url, {
    region,
    stageName: inferStageName(manifest.broker_command_url, region),
    code,
    statusCode: 400,
  });
  return canonicalManifest({
    ...manifest,
    bootstrap_id: bootstrapId,
    connection_id: connectionId,
    account_id: accountId,
    region,
    broker_command_url: brokerCommandURL,
    node_key_id: nodeKeyId,
    connection_generation: generation,
    worker_artifact: workerArtifact,
    worker_network: workerNetwork,
    worker_resource_manifest_digest: workerResourceManifestDigest,
    stack_arn: stackArn,
  });
}
