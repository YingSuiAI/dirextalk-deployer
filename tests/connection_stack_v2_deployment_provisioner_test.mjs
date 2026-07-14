import assert from "node:assert/strict";

import {
  Ec2DedicatedWorkerProvisioner,
} from "../scripts/connection-stack-v2/src/deployment-provisioner.mjs";

class DescribeSubnetsCommand { constructor(input) { this.input = input; } }
class DescribeVpcsCommand { constructor(input) { this.input = input; } }
class DescribeImagesCommand { constructor(input) { this.input = input; } }
class DescribeSecurityGroupsCommand { constructor(input) { this.input = input; } }
class CreateSecurityGroupCommand { constructor(input) { this.input = input; } }
class RevokeSecurityGroupEgressCommand { constructor(input) { this.input = input; } }
class AuthorizeSecurityGroupEgressCommand { constructor(input) { this.input = input; } }
class RunInstancesCommand { constructor(input) { this.input = input; } }

const commandConstructors = {
  DescribeSubnetsCommand,
  DescribeVpcsCommand,
  DescribeImagesCommand,
  DescribeSecurityGroupsCommand,
  CreateSecurityGroupCommand,
  RevokeSecurityGroupEgressCommand,
  AuthorizeSecurityGroupEgressCommand,
  RunInstancesCommand,
};
const DIGEST = (character) => `sha256:${character.repeat(64)}`;
const requestSHA256 = "b".repeat(64);
const workerBootstrapEndpoint = "https://a1b2c3d4e5.execute-api.ap-south-1.amazonaws.com/prod/v2/worker-sessions";
const payload = {
  schema: "dirextalk.aws.deployment-create/v1",
  deployment_id: "deployment-v2-001",
  connection_generation: 3,
  plan_hash: DIGEST("a"),
  plan_revision: 7,
  quote_id: "quote-v2-00001",
  quote_digest: DIGEST("d"),
  candidate_id: "candidate-recommended-01",
  resource_manifest_digest: DIGEST("c"),
  worker_artifact: { kind: "fixed_ami", ami_id: "ami-0123456789abcdef0" },
  network: {
    vpc_id: "vpc-0123456789abcdef0",
    subnet_id: "subnet-0123456789abcdef0",
    availability_zone: "ap-south-1a",
  },
};
const command = {
  connection_id: "connection-v2-0001",
  expected_generation: 3,
  request_sha256: requestSHA256,
  payload,
};
const quote = {
  quote_id: payload.quote_id,
  quote_digest: payload.quote_digest,
  plan_digest: DIGEST("e"),
  region: "ap-south-1",
  valid_until: "2026-07-14T07:15:00.000Z",
  candidates: [{
    candidate_id: payload.candidate_id,
    instance_type: "t3.large",
    architecture: "amd64",
    vcpu: 2,
    memory_mib: 8192,
    gpu_count: 0,
    gpu_memory_mib: 0,
    purchase_option: "on_demand",
    estimated_disk_gib: 40,
    availability_zones: ["ap-south-1a"],
  }, {
    candidate_id: "candidate-performance-01",
    instance_type: "m7i.xlarge",
    architecture: "amd64",
    vcpu: 4,
    memory_mib: 16384,
    gpu_count: 0,
    gpu_memory_mib: 0,
    purchase_option: "on_demand",
    estimated_disk_gib: 80,
    availability_zones: ["ap-south-1a"],
  }],
};
const approvalProof = {
  schema_version: "cloud-orchestrator/v1",
  approval_id: "approval-v2-0001",
  challenge_id: "challenge-v2-0001",
  signer_key_id: "owner-device-1",
  plan_id: "plan-v2-0001",
  plan_hash: payload.plan_hash,
  plan_revision: payload.plan_revision,
  quote_id: payload.quote_id,
  quote_digest: payload.quote_digest,
  quote_valid_until: "2026-07-14T07:15:00Z",
  cloud_connection_id: command.connection_id,
  recipe_digest: DIGEST("f"),
  resource_scope: {
    region: "ap-south-1",
    availability_zones: ["ap-south-1a"],
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
  secret_scope: null,
  integration_scope: null,
  expires_at: "2026-07-14T07:10:00Z",
  signature: "A".repeat(86),
};
command.approval_proof = approvalProof;

const sent = [];
const lifecycle = [];
const ec2Client = {
  async send(commandInput) {
    sent.push(commandInput);
    if (commandInput instanceof DescribeSubnetsCommand) {
      return { Subnets: [{
        SubnetId: payload.network.subnet_id,
        VpcId: payload.network.vpc_id,
        AvailabilityZone: payload.network.availability_zone,
        AvailableIpAddressCount: 8,
        MapPublicIpOnLaunch: false,
        AssignIpv6AddressOnCreation: false,
        Ipv6CidrBlockAssociationSet: [],
      }] };
    }
    if (commandInput instanceof DescribeVpcsCommand) {
      return { Vpcs: [{ VpcId: payload.network.vpc_id, CidrBlock: "10.0.0.0/16" }] };
    }
    if (commandInput instanceof DescribeImagesCommand) {
      return { Images: [{
        ImageId: payload.worker_artifact.ami_id,
        State: "available",
        Architecture: "x86_64",
        RootDeviceName: "/dev/sda1",
      }] };
    }
    if (commandInput instanceof DescribeSecurityGroupsCommand) return { SecurityGroups: [] };
    if (commandInput instanceof CreateSecurityGroupCommand) return { GroupId: "sg-0123456789abcdef0" };
    if (commandInput instanceof RevokeSecurityGroupEgressCommand) return {};
    if (commandInput instanceof AuthorizeSecurityGroupEgressCommand) return {};
    if (commandInput instanceof RunInstancesCommand) {
      lifecycle.push("run");
      return { Instances: [{
        InstanceId: "i-0123456789abcdef0",
        BlockDeviceMappings: [{ Ebs: { VolumeId: "vol-0123456789abcdef0" } }],
        NetworkInterfaces: [{ NetworkInterfaceId: "eni-0123456789abcdef0" }],
      }] };
    }
    throw new Error(`unexpected ${commandInput.constructor.name}`);
  },
};

const persisted = [];
let issuedWorkerSession;
const workerSessionStore = {
  async issue(input) {
    lifecycle.push("issue");
    issuedWorkerSession = {
      ...structuredClone(input),
      state: "issued",
      lease_epoch: 0,
      last_sequence: 0,
    };
    return structuredClone(issuedWorkerSession);
  },
  async bind(input) {
    lifecycle.push("bind");
    return {
      ...structuredClone(issuedWorkerSession),
      state: "bound",
      expected_instance_id: input.instance_id,
    };
  },
};
const store = {
  async getDeployment() { return undefined; },
  async getDeploymentBootstrap() {
    return { bootstrap_session_id: "worker-session-v2-001", request_sha256: requestSHA256 };
  },
  async getQuote() { return quote; },
  async putDeployment(receipt) {
    persisted.push(receipt);
    return receipt;
  },
};

const provisioner = new Ec2DedicatedWorkerProvisioner({
  ec2Client,
  commandConstructors,
  deploymentStore: store,
  workerSessionStore,
  connectionId: command.connection_id,
  connectionGeneration: 3,
  accountId: "123456789012",
  region: "ap-south-1",
  workerBaseAmiId: payload.worker_artifact.ami_id,
  workerResourceManifestDigest: payload.resource_manifest_digest,
  workerNetwork: payload.network,
  workerBootstrapEnabled: true,
  nowMs: () => Date.parse("2026-07-14T07:00:00.000Z"),
});
const receipt = await provisioner.ensure(command, { workerBootstrapEndpoint });
assert.deepEqual(receipt, {
  schema: "dirextalk.aws.deployment-receipt/v1",
  connection_id: command.connection_id,
  deployment_id: payload.deployment_id,
  request_sha256: requestSHA256,
  resource_status: "provisioning",
  instance_id: "i-0123456789abcdef0",
  volume_ids: ["vol-0123456789abcdef0"],
  network_interface_ids: ["eni-0123456789abcdef0"],
});
assert.deepEqual(persisted, [receipt]);

const run = sent.find((item) => item instanceof RunInstancesCommand)?.input;
assert.ok(run, "the typed provisioner must issue EC2 RunInstances only after its closed preflight");
assert.equal(run.ImageId, payload.worker_artifact.ami_id);
assert.equal(run.InstanceType, "t3.large");
assert.equal(run.ClientToken, requestSHA256, "ClientToken must deterministically bind the signed request for recovery");
assert.equal(run.NetworkInterfaces[0].AssociatePublicIpAddress, false);
assert.equal(run.NetworkInterfaces[0].Ipv6AddressCount, 0);
assert.equal(run.MetadataOptions.HttpTokens, "required");
assert.equal(run.MetadataOptions.HttpEndpoint, "enabled");
assert.equal(run.MetadataOptions.HttpPutResponseHopLimit, 1);
assert.equal(run.MetadataOptions.InstanceMetadataTags, "disabled");
assert.equal(run.BlockDeviceMappings[0].Ebs.Encrypted, true);
assert.equal(run.BlockDeviceMappings[0].Ebs.DeleteOnTermination, false);
assert.equal(run.BlockDeviceMappings[0].Ebs.VolumeType, "gp3");
assert.equal(run.BlockDeviceMappings[0].Ebs.VolumeSize, 40);
for (const forbidden of ["IamInstanceProfile", "KeyName", "SecurityGroupIds", "SubnetId", "AssociatePublicIpAddress"]) {
  assert.ok(!Object.hasOwn(run, forbidden), `${forbidden} must not reach RunInstances`);
}
assert.equal(lifecycle.slice(0, 3).join(","), "issue,run,bind", "the Stack must bind a durable bootstrap session around the typed EC2 mutation");
assert.equal(typeof run.UserData, "string");
const bootstrapScript = Buffer.from(run.UserData, "base64").toString("utf8");
assert.match(bootstrapScript, /dirextalk-cloud-worker\.service/);
assert.equal(issuedWorkerSession.bootstrap_session_id, "worker-session-v2-001");
assert.ok(!bootstrapScript.includes("access_token"), "EC2 UserData must not carry a Worker bearer token");
assert.ok(!sent.some((item) => /AuthorizeSecurityGroupIngress|CreateKeyPair|CreateIamInstanceProfile|PassRole/.test(item.constructor.name)));
const outbound = sent.find((item) => item instanceof AuthorizeSecurityGroupEgressCommand)?.input;
assert.deepEqual(outbound.IpPermissions.map((permission) => [permission.IpProtocol, permission.FromPort, permission.ToPort]), [
  ["tcp", 443, 443],
  ["udp", 53, 53],
  ["tcp", 53, 53],
]);

const sentBeforeMismatchedScope = sent.length;
await assert.rejects(
  () => provisioner.ensure({
    ...command,
    payload: { ...payload, candidate_id: "candidate-performance-01" },
  }, { workerBootstrapEndpoint }),
  (error) => error?.code === "approval_proof_mismatch",
  "a signed deployment command must not select a more expensive durable quote candidate outside the Flutter-approved resource scope",
);
assert.equal(sent.length, sentBeforeMismatchedScope, "a resource-scope mismatch must fail before any EC2 preflight or mutation");

const identityDisabledProvisioner = new Ec2DedicatedWorkerProvisioner({
  ec2Client: {
    async send() {
      throw new Error("an unconfigured IID verifier must fail before any EC2 mutation");
    },
  },
  commandConstructors,
  deploymentStore: store,
  workerSessionStore,
  connectionId: command.connection_id,
  connectionGeneration: 3,
  accountId: "123456789012",
  region: "ap-south-1",
  workerBaseAmiId: payload.worker_artifact.ami_id,
  workerResourceManifestDigest: payload.resource_manifest_digest,
  workerNetwork: payload.network,
  workerBootstrapEnabled: false,
  nowMs: () => Date.parse("2026-07-14T07:00:00.000Z"),
});
await assert.rejects(
  () => identityDisabledProvisioner.ensure(command, { workerBootstrapEndpoint }),
  (error) => error?.code === "worker_identity_unavailable",
  "a Stack without the official IID verifier must not create an EC2 Worker",
);

const trustedGroupTags = sent.find((item) => item instanceof CreateSecurityGroupCommand)?.input.TagSpecifications[0].Tags;
const ipv6Egress = outbound.IpPermissions.map((permission, index) => ({
  ...permission,
  IpRanges: permission.IpRanges.map((range) => ({ ...range })),
  ...(index === 0 ? { Ipv6Ranges: [{ CidrIpv6: "::/0" }] } : {}),
}));
const ipv6EgressProvisioner = new Ec2DedicatedWorkerProvisioner({
  ec2Client: {
    async send(commandInput) {
      if (commandInput instanceof DescribeSecurityGroupsCommand) {
        return { SecurityGroups: [{
          GroupId: "sg-0123456789abcdef0",
          Tags: trustedGroupTags,
          IpPermissions: [],
          IpPermissionsEgress: ipv6Egress,
        }] };
      }
      return ec2Client.send(commandInput);
    },
  },
  commandConstructors,
  deploymentStore: store,
  workerSessionStore,
  connectionId: command.connection_id,
  connectionGeneration: 3,
  accountId: "123456789012",
  region: "ap-south-1",
  workerBaseAmiId: payload.worker_artifact.ami_id,
  workerResourceManifestDigest: payload.resource_manifest_digest,
  workerNetwork: payload.network,
  workerBootstrapEnabled: true,
  nowMs: () => Date.parse("2026-07-14T07:00:00.000Z"),
});
await assert.rejects(
  () => ipv6EgressProvisioner.ensure(command, { workerBootstrapEndpoint }),
  (error) => error?.code === "worker_security_group_invalid",
  "an existing tagged group with IPv6 egress must not be treated as a safe Worker group",
);

const recoverySent = [];
let recoveredGroup;
const recoveryProvisioner = new Ec2DedicatedWorkerProvisioner({
  ec2Client: {
    async send(commandInput) {
      recoverySent.push(commandInput);
      if (commandInput instanceof DescribeSubnetsCommand) {
        return { Subnets: [{
          SubnetId: payload.network.subnet_id,
          VpcId: payload.network.vpc_id,
          AvailabilityZone: payload.network.availability_zone,
          AvailableIpAddressCount: 8,
          MapPublicIpOnLaunch: false,
          AssignIpv6AddressOnCreation: false,
          Ipv6CidrBlockAssociationSet: [],
        }] };
      }
      if (commandInput instanceof DescribeVpcsCommand) {
        return { Vpcs: [{ VpcId: payload.network.vpc_id, CidrBlock: "10.0.0.0/16" }] };
      }
      if (commandInput instanceof DescribeImagesCommand) {
        return { Images: [{
          ImageId: payload.worker_artifact.ami_id,
          State: "available",
          Architecture: "x86_64",
          RootDeviceName: "/dev/sda1",
        }] };
      }
      if (commandInput instanceof DescribeSecurityGroupsCommand) {
        return { SecurityGroups: recoveredGroup ? [recoveredGroup] : [] };
      }
      if (commandInput instanceof CreateSecurityGroupCommand) {
        recoveredGroup = {
          GroupId: "sg-0123456789abcdef0",
          Tags: commandInput.input.TagSpecifications[0].Tags,
          IpPermissions: [],
          IpPermissionsEgress: [{ IpProtocol: "-1", IpRanges: [{ CidrIp: "0.0.0.0/0" }] }],
        };
        throw new Error("simulated CreateSecurityGroup response loss after AWS accepted the request");
      }
      if (commandInput instanceof RevokeSecurityGroupEgressCommand) {
        recoveredGroup.IpPermissionsEgress = [];
        return {};
      }
      if (commandInput instanceof AuthorizeSecurityGroupEgressCommand) {
        recoveredGroup.IpPermissionsEgress.push(...commandInput.input.IpPermissions);
        return {};
      }
      if (commandInput instanceof RunInstancesCommand) {
        return { Instances: [{
          InstanceId: "i-0123456789abcdef0",
          BlockDeviceMappings: [{ Ebs: { VolumeId: "vol-0123456789abcdef0" } }],
          NetworkInterfaces: [{ NetworkInterfaceId: "eni-0123456789abcdef0" }],
        }] };
      }
      throw new Error(`unexpected ${commandInput.constructor.name}`);
    },
  },
  commandConstructors,
  deploymentStore: {
    async getDeployment() { return undefined; },
    async getDeploymentBootstrap() {
      return { bootstrap_session_id: "worker-session-v2-001", request_sha256: requestSHA256 };
    },
    async getQuote() { return quote; },
    async putDeployment(value) { return value; },
  },
  workerSessionStore,
  connectionId: command.connection_id,
  connectionGeneration: 3,
  accountId: "123456789012",
  region: "ap-south-1",
  workerBaseAmiId: payload.worker_artifact.ami_id,
  workerResourceManifestDigest: payload.resource_manifest_digest,
  workerNetwork: payload.network,
  workerBootstrapEnabled: true,
  nowMs: () => Date.parse("2026-07-14T07:00:00.000Z"),
});
assert.equal(
  (await recoveryProvisioner.ensure(command, { workerBootstrapEndpoint })).instance_id,
  "i-0123456789abcdef0",
  "a lost CreateSecurityGroup response must recover only the Stack-tagged zero-ingress group",
);
assert.equal(recoverySent.filter((item) => item instanceof CreateSecurityGroupCommand).length, 1);
assert.ok(
  recoverySent.findIndex((item) => item instanceof RevokeSecurityGroupEgressCommand)
    < recoverySent.findIndex((item) => item instanceof AuthorizeSecurityGroupEgressCommand),
  "recovery must remove default open egress before permitting the Worker to run",
);
assert.deepEqual(
  recoveredGroup.IpPermissionsEgress.map((permission) => [permission.IpProtocol, permission.FromPort, permission.ToPort]),
  [["tcp", 443, 443], ["udp", 53, 53], ["tcp", 53, 53]],
);

// An EC2 client can lose the RunInstances response after AWS accepted the
// ClientToken. The second attempt must reuse the durable bootstrap session and
// emit byte-identical UserData, otherwise AWS treats the retry as a different
// request instead of returning the original dedicated Worker.
let responseLossNow = Date.parse("2026-07-14T07:00:00.000Z");
let responseLossSession;
let responseLossRunInput;
let responseLossRunCalls = 0;
const responseLossGroup = {
  GroupId: "sg-0123456789abcdef0",
  Tags: trustedGroupTags,
  IpPermissions: [],
  IpPermissionsEgress: structuredClone(outbound.IpPermissions),
};
const responseLossProvisioner = new Ec2DedicatedWorkerProvisioner({
  ec2Client: {
    async send(commandInput) {
      if (commandInput instanceof DescribeSubnetsCommand) {
        return { Subnets: [{
          SubnetId: payload.network.subnet_id,
          VpcId: payload.network.vpc_id,
          AvailabilityZone: payload.network.availability_zone,
          AvailableIpAddressCount: 8,
          MapPublicIpOnLaunch: false,
          AssignIpv6AddressOnCreation: false,
          Ipv6CidrBlockAssociationSet: [],
        }] };
      }
      if (commandInput instanceof DescribeVpcsCommand) {
        return { Vpcs: [{ VpcId: payload.network.vpc_id, CidrBlock: "10.0.0.0/16" }] };
      }
      if (commandInput instanceof DescribeImagesCommand) {
        return { Images: [{
          ImageId: payload.worker_artifact.ami_id,
          State: "available",
          Architecture: "x86_64",
          RootDeviceName: "/dev/sda1",
        }] };
      }
      if (commandInput instanceof DescribeSecurityGroupsCommand) {
        return { SecurityGroups: [responseLossGroup] };
      }
      if (commandInput instanceof RunInstancesCommand) {
        responseLossRunCalls += 1;
        if (responseLossRunCalls === 1) {
          responseLossRunInput = structuredClone(commandInput.input);
          throw new Error("simulated RunInstances response loss after AWS accepted ClientToken");
        }
        assert.equal(commandInput.input.ClientToken, responseLossRunInput.ClientToken);
        assert.equal(commandInput.input.UserData, responseLossRunInput.UserData);
        return { Instances: [{
          InstanceId: "i-0123456789abcdef0",
          BlockDeviceMappings: [{ Ebs: { VolumeId: "vol-0123456789abcdef0" } }],
          NetworkInterfaces: [{ NetworkInterfaceId: "eni-0123456789abcdef0" }],
        }] };
      }
      throw new Error(`unexpected ${commandInput.constructor.name}`);
    },
  },
  commandConstructors,
  deploymentStore: {
    async getDeployment() { return undefined; },
    async getDeploymentBootstrap() {
      return { bootstrap_session_id: "worker-session-v2-001", request_sha256: requestSHA256 };
    },
    async getQuote() { return quote; },
    async putDeployment(value) { return value; },
  },
  workerSessionStore: {
    async issue(input) {
      if (!responseLossSession) {
        responseLossSession = {
          ...structuredClone(input),
          state: "issued",
          lease_epoch: 0,
          last_sequence: 0,
        };
      }
      return structuredClone(responseLossSession);
    },
    async bind(input) {
      return {
        ...structuredClone(responseLossSession),
        state: "bound",
        expected_instance_id: input.instance_id,
      };
    },
  },
  connectionId: command.connection_id,
  connectionGeneration: 3,
  accountId: "123456789012",
  region: "ap-south-1",
  workerBaseAmiId: payload.worker_artifact.ami_id,
  workerResourceManifestDigest: payload.resource_manifest_digest,
  workerNetwork: payload.network,
  workerBootstrapEnabled: true,
  nowMs: () => responseLossNow,
});
await assert.rejects(
  () => responseLossProvisioner.ensure(command, { workerBootstrapEndpoint }),
  (error) => error?.code === "deployment_provider_unavailable",
  "a lost RunInstances response must leave the durable session eligible for one safe recovery request",
);
responseLossNow += 5_000;
assert.equal(
  (await responseLossProvisioner.ensure(command, { workerBootstrapEndpoint })).instance_id,
  "i-0123456789abcdef0",
);
assert.equal(responseLossRunCalls, 2, "recovery must rely on the original EC2 ClientToken instead of creating another session");
assert.equal(responseLossSession.expires_at, "2026-07-14T07:10:00.000Z");

const publicSubnetProvisioner = new Ec2DedicatedWorkerProvisioner({
  ec2Client: {
    async send(commandInput) {
      if (commandInput instanceof DescribeSubnetsCommand) {
        return { Subnets: [{
          SubnetId: payload.network.subnet_id,
          VpcId: payload.network.vpc_id,
          AvailabilityZone: payload.network.availability_zone,
          AvailableIpAddressCount: 8,
          MapPublicIpOnLaunch: true,
          AssignIpv6AddressOnCreation: false,
          Ipv6CidrBlockAssociationSet: [],
        }] };
      }
      throw new Error("a public subnet must fail before any further EC2 operation");
    },
  },
  commandConstructors,
  deploymentStore: store,
  workerSessionStore,
  connectionId: command.connection_id,
  connectionGeneration: 3,
  accountId: "123456789012",
  region: "ap-south-1",
  workerBaseAmiId: payload.worker_artifact.ami_id,
  workerResourceManifestDigest: payload.resource_manifest_digest,
  workerNetwork: payload.network,
  workerBootstrapEnabled: true,
  nowMs: () => Date.parse("2026-07-14T07:00:00.000Z"),
});
await assert.rejects(
  () => publicSubnetProvisioner.ensure(command, { workerBootstrapEndpoint }),
  (error) => error?.code === "worker_network_invalid",
  "a Stack-configured subnet that assigns public IPs cannot launch a Worker",
);

console.log("connection stack v2 isolated deployment provisioner boundary ok");
