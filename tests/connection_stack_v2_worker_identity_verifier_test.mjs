import assert from "node:assert/strict";
import {
  generateKeyPairSync,
  sign,
} from "node:crypto";

import {
  AwsInstanceIdentityVerifier,
} from "../scripts/connection-stack-v2/src/worker-identity-verifier.mjs";

class DescribeInstancesCommand {
  constructor(input) { this.input = input; }
}

const connectionID = "connection-v2-0001";
const deploymentID = "deployment-v2-001";
const requestSHA256 = "a".repeat(64);
const identityDocument = {
  accountId: "123456789012",
  region: "ap-northeast-1",
  instanceId: "i-0123456789abcdef0",
  imageId: "ami-0123456789abcdef0",
  availabilityZone: "ap-northeast-1a",
  instanceType: "t3.large",
  architecture: "x86_64",
};
const identityDocumentBytes = Buffer.from(JSON.stringify(identityDocument), "utf8");
const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const claim = {
  instance_identity_document_b64: identityDocumentBytes.toString("base64"),
  instance_identity_signature_b64: sign("sha256", identityDocumentBytes, privateKey).toString("base64"),
};
const session = {
  bootstrap_session_id: "worker-session-v2-001",
  connection_id: connectionID,
  deployment_id: deploymentID,
  request_sha256: requestSHA256,
  account_id: identityDocument.accountId,
  region: identityDocument.region,
  expected_instance_id: identityDocument.instanceId,
  expected_ami_id: identityDocument.imageId,
  expected_instance_type: identityDocument.instanceType,
  expected_architecture: identityDocument.architecture,
  expected_availability_zone: identityDocument.availabilityZone,
  expected_vpc_id: "vpc-0123456789abcdef0",
  expected_subnet_id: "subnet-0123456789abcdef0",
  expected_security_group_id: "sg-0123456789abcdef0",
};

function ec2Instance(overrides = {}) {
  return {
    InstanceId: identityDocument.instanceId,
    State: { Name: "running" },
    ImageId: identityDocument.imageId,
    InstanceType: identityDocument.instanceType,
    Placement: { AvailabilityZone: identityDocument.availabilityZone },
    SubnetId: session.expected_subnet_id,
    VpcId: session.expected_vpc_id,
    MetadataOptions: {
      HttpTokens: "required",
      HttpEndpoint: "enabled",
      HttpPutResponseHopLimit: 1,
      InstanceMetadataTags: "disabled",
    },
    NetworkInterfaces: [{
      SubnetId: session.expected_subnet_id,
      VpcId: session.expected_vpc_id,
      Groups: [{ GroupId: session.expected_security_group_id }],
      Ipv6Addresses: [],
    }],
    Tags: [
      { Key: "dirextalk:connection-id", Value: connectionID },
      { Key: "dirextalk:deployment-id", Value: deploymentID },
      { Key: "dirextalk:managed-by", Value: "connection-stack-v2" },
      { Key: "dirextalk:request-sha256", Value: requestSHA256 },
    ],
    ...overrides,
  };
}

const sent = [];
const verifier = new AwsInstanceIdentityVerifier({
  ec2Client: {
    async send(command) {
      sent.push(command);
      return { Reservations: [{ Instances: [ec2Instance()] }] };
    },
  },
  DescribeInstancesCommand,
  rsaPublicKeyPem: publicKey.export({ type: "spki", format: "pem" }).toString(),
});
assert.deepEqual(await verifier.verify(claim, session), {
  account_id: identityDocument.accountId,
  region: identityDocument.region,
  instance_id: identityDocument.instanceId,
  image_id: identityDocument.imageId,
  availability_zone: identityDocument.availabilityZone,
  instance_type: identityDocument.instanceType,
  architecture: identityDocument.architecture,
});
assert.deepEqual(sent[0].input, { InstanceIds: [identityDocument.instanceId] });

await assert.rejects(
  () => verifier.verify({ ...claim, instance_identity_signature_b64: Buffer.from("not-a-signature").toString("base64") }, session),
  (error) => error?.code === "worker_identity_invalid",
  "a syntactically valid but non-AWS IID signature cannot claim a worker session",
);
await assert.rejects(
  () => verifier.verify({ ...claim, instance_identity_signature_b64: `${claim.instance_identity_signature_b64}\n` }, session),
  (error) => error?.code === "worker_identity_invalid",
  "IID verification must reject a non-canonical base64 proof even when a later consumer would trim it",
);

const publicIpVerifier = new AwsInstanceIdentityVerifier({
  ec2Client: {
    async send() {
      return { Reservations: [{ Instances: [ec2Instance({ PublicIpAddress: "198.51.100.2" })] }] };
    },
  },
  DescribeInstancesCommand,
  rsaPublicKeyPem: publicKey.export({ type: "spki", format: "pem" }).toString(),
});
await assert.rejects(
  () => publicIpVerifier.verify(claim, session),
  (error) => error?.code === "worker_instance_invalid",
  "a stack-created Worker must retain no public IP even after a valid IID signature",
);

const profileVerifier = new AwsInstanceIdentityVerifier({
  ec2Client: {
    async send() {
      return { Reservations: [{ Instances: [ec2Instance({ IamInstanceProfile: { Arn: "arn:aws:iam::123456789012:instance-profile/forbidden" } })] }] };
    },
  },
  DescribeInstancesCommand,
  rsaPublicKeyPem: publicKey.export({ type: "spki", format: "pem" }).toString(),
});
await assert.rejects(
  () => profileVerifier.verify(claim, session),
  (error) => error?.code === "worker_instance_invalid",
  "a Worker with an attached IAM instance profile must fail the claim read-back",
);

console.log("connection stack v2 worker identity verifier boundary ok");
