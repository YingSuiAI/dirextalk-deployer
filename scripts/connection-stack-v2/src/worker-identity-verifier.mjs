import {
  createPublicKey,
  verify,
} from "node:crypto";
import {
  TextDecoder,
} from "node:util";

import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  parseStrictJSONObject,
} from "./worker-session-contract.mjs";

const ACCOUNT_ID_PATTERN = /^\d{12}$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const INSTANCE_ID_PATTERN = /^i-[0-9a-f]{8,17}$/;
const AMI_ID_PATTERN = /^ami-[0-9a-f]{8,17}$/;
const AVAILABILITY_ZONE_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/;
const INSTANCE_TYPE_PATTERN = /^[a-z0-9][a-z0-9.-]{1,63}$/;
const ARCHITECTURE_PATTERN = /^(?:x86_64|arm64)$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const decoder = new TextDecoder("utf-8", { fatal: true });

function fail(code, message, statusCode) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireString(value, field, pattern, code = "worker_identity_invalid", statusCode = 401) {
  if (typeof value !== "string" || !pattern.test(value)) fail(code, `${field} is invalid`, statusCode);
  return value;
}

function decodeCanonicalBase64(value, field) {
  if (typeof value !== "string" || value.length === 0 || value.trim() !== value || value.length % 4 !== 0
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    fail("worker_identity_invalid", `${field} is invalid`, 401);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.length === 0 || decoded.toString("base64") !== value) {
    fail("worker_identity_invalid", `${field} is invalid`, 401);
  }
  return decoded;
}

function parseIdentityDocument(document) {
  let text;
  try {
    text = decoder.decode(document);
  } catch {
    fail("worker_identity_invalid", "instance identity document is invalid", 401);
  }
  let parsed;
  try {
    parsed = parseStrictJSONObject(text);
  } catch {
    fail("worker_identity_invalid", "instance identity document is invalid", 401);
  }
  if (!isRecord(parsed)) fail("worker_identity_invalid", "instance identity document is invalid", 401);
  return {
    account_id: requireString(parsed.accountId, "accountId", ACCOUNT_ID_PATTERN),
    region: requireString(parsed.region, "region", REGION_PATTERN),
    instance_id: requireString(parsed.instanceId, "instanceId", INSTANCE_ID_PATTERN),
    image_id: requireString(parsed.imageId, "imageId", AMI_ID_PATTERN),
    availability_zone: requireString(parsed.availabilityZone, "availabilityZone", AVAILABILITY_ZONE_PATTERN),
    instance_type: requireString(parsed.instanceType, "instanceType", INSTANCE_TYPE_PATTERN),
    architecture: requireString(parsed.architecture, "architecture", ARCHITECTURE_PATTERN),
  };
}

function requireSessionBinding(session) {
  if (!isRecord(session)) fail("worker_session_invalid", "worker session is invalid", 409);
  return {
    connection_id: requireString(session.connection_id, "connection_id", /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/, "worker_session_invalid", 409),
    deployment_id: requireString(session.deployment_id, "deployment_id", /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/, "worker_session_invalid", 409),
    request_sha256: requireString(session.request_sha256, "request_sha256", SHA256_PATTERN, "worker_session_invalid", 409),
    account_id: requireString(session.account_id, "account_id", ACCOUNT_ID_PATTERN, "worker_session_invalid", 409),
    region: requireString(session.region, "region", REGION_PATTERN, "worker_session_invalid", 409),
    expected_instance_id: requireString(session.expected_instance_id, "expected_instance_id", INSTANCE_ID_PATTERN, "worker_session_invalid", 409),
    expected_ami_id: requireString(session.expected_ami_id, "expected_ami_id", AMI_ID_PATTERN, "worker_session_invalid", 409),
    expected_instance_type: requireString(session.expected_instance_type, "expected_instance_type", INSTANCE_TYPE_PATTERN, "worker_session_invalid", 409),
    expected_architecture: requireString(session.expected_architecture, "expected_architecture", ARCHITECTURE_PATTERN, "worker_session_invalid", 409),
    expected_availability_zone: requireString(session.expected_availability_zone, "expected_availability_zone", AVAILABILITY_ZONE_PATTERN, "worker_session_invalid", 409),
    expected_vpc_id: requireString(session.expected_vpc_id, "expected_vpc_id", /^vpc-[0-9a-f]{8,17}$/, "worker_session_invalid", 409),
    expected_subnet_id: requireString(session.expected_subnet_id, "expected_subnet_id", /^subnet-[0-9a-f]{8,17}$/, "worker_session_invalid", 409),
    expected_security_group_id: requireString(session.expected_security_group_id, "expected_security_group_id", /^sg-[0-9a-f]{8,17}$/, "worker_session_invalid", 409),
  };
}

function compareIdentity(identity, session) {
  if (identity.account_id !== session.account_id || identity.region !== session.region || identity.instance_id !== session.expected_instance_id
    || identity.image_id !== session.expected_ami_id || identity.instance_type !== session.expected_instance_type
    || identity.architecture !== session.expected_architecture || identity.availability_zone !== session.expected_availability_zone) {
    fail("worker_identity_invalid", "instance identity does not match the issued worker session", 401);
  }
}

function tags(instance) {
  return new Map((Array.isArray(instance?.Tags) ? instance.Tags : [])
    .filter((tag) => typeof tag?.Key === "string" && typeof tag?.Value === "string")
    .map((tag) => [tag.Key, tag.Value]));
}

function networkGroups(instance) {
  const interfaces = Array.isArray(instance?.NetworkInterfaces) ? instance.NetworkInterfaces : [];
  if (interfaces.length !== 1) return undefined;
  const network = interfaces[0];
  if (!isRecord(network) || network.SubnetId !== instance.SubnetId || network.VpcId !== instance.VpcId
    || network.Association?.PublicIp || (Array.isArray(network.Ipv6Addresses) && network.Ipv6Addresses.length > 0)) {
    return undefined;
  }
  const groups = Array.isArray(network.Groups) ? network.Groups.map((group) => group?.GroupId).filter((id) => typeof id === "string") : [];
  return groups.length === 1 ? groups : undefined;
}

function verifyReadBack(instance, session) {
  if (!isRecord(instance) || instance.InstanceId !== session.expected_instance_id || !["pending", "running"].includes(instance?.State?.Name)
    || instance.ImageId !== session.expected_ami_id || instance.InstanceType !== session.expected_instance_type
    || instance?.Placement?.AvailabilityZone !== session.expected_availability_zone || instance.SubnetId !== session.expected_subnet_id
    || instance.VpcId !== session.expected_vpc_id || instance.PublicIpAddress !== undefined || instance.IamInstanceProfile !== undefined
    || instance?.MetadataOptions?.HttpTokens !== "required" || instance?.MetadataOptions?.HttpEndpoint !== "enabled"
    || instance?.MetadataOptions?.HttpPutResponseHopLimit !== 1 || instance?.MetadataOptions?.InstanceMetadataTags !== "disabled") {
    fail("worker_instance_invalid", "EC2 read-back does not match the dedicated Worker session", 409);
  }
  const groups = networkGroups(instance);
  if (!groups || groups[0] !== session.expected_security_group_id) {
    fail("worker_instance_invalid", "EC2 network read-back does not match the dedicated Worker session", 409);
  }
  const actualTags = tags(instance);
  const expectedTags = {
    "dirextalk:connection-id": session.connection_id,
    "dirextalk:deployment-id": session.deployment_id,
    "dirextalk:managed-by": "connection-stack-v2",
    "dirextalk:request-sha256": session.request_sha256,
  };
  for (const [key, value] of Object.entries(expectedTags)) {
    if (actualTags.get(key) !== value) fail("worker_instance_invalid", "EC2 tags do not match the dedicated Worker session", 409);
  }
}

// AwsInstanceIdentityVerifier validates the IMDSv2 IID signature using a
// Stack-pinned regional AWS RSA public certificate, then independently reads
// the exact EC2 resource that the Stack created. It never uses the Worker IAM
// identity, assumes a role, or accepts a certificate from the worker request.
export class AwsInstanceIdentityVerifier {
  constructor({ ec2Client, DescribeInstancesCommand, rsaPublicKeyPem }) {
    if (!ec2Client?.send || !DescribeInstancesCommand || typeof rsaPublicKeyPem !== "string" || rsaPublicKeyPem.length < 64 || rsaPublicKeyPem.length > 8192) {
      throw new TypeError("EC2 client, DescribeInstancesCommand, and Stack-pinned RSA public key are required");
    }
    try {
      this.publicKey = createPublicKey(rsaPublicKeyPem);
    } catch {
      throw new TypeError("Stack-pinned RSA public key is invalid");
    }
    if (this.publicKey.asymmetricKeyType !== "rsa") {
      throw new TypeError("Stack-pinned worker identity key must be RSA");
    }
    this.ec2Client = ec2Client;
    this.DescribeInstancesCommand = DescribeInstancesCommand;
  }

  async verify(claim, sessionRecord) {
    const session = requireSessionBinding(sessionRecord);
    const document = decodeCanonicalBase64(claim?.instance_identity_document_b64, "instance identity document");
    const signature = decodeCanonicalBase64(claim?.instance_identity_signature_b64, "instance identity signature");
    if (!verify("sha256", document, this.publicKey, signature)) {
      fail("worker_identity_invalid", "instance identity signature is invalid", 401);
    }
    const identity = parseIdentityDocument(document);
    compareIdentity(identity, session);
    let output;
    try {
      output = await this.ec2Client.send(new this.DescribeInstancesCommand({ InstanceIds: [identity.instance_id] }));
    } catch {
      fail("worker_instance_unavailable", "EC2 instance read-back is unavailable", 503);
    }
    const reservations = Array.isArray(output?.Reservations) ? output.Reservations : [];
    const instances = reservations.flatMap((reservation) => Array.isArray(reservation?.Instances) ? reservation.Instances : []);
    if (instances.length !== 1) fail("worker_instance_invalid", "EC2 instance read-back is invalid", 409);
    verifyReadBack(instances[0], session);
    return identity;
  }
}
