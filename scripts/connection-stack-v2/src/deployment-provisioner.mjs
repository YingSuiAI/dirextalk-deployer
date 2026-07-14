import {
  createHash,
} from "node:crypto";

import {
  ConnectionStackV2Error,
  validateDeploymentCreatePayload,
  validateDeploymentReceipt,
} from "./deployment-contract.mjs";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const NAMED_SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const AMI_ID_PATTERN = /^ami-[0-9a-f]{8,17}$/;
const REGION_PATTERN = /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d$/;
const AWS_ARCHITECTURE_BY_DIREXTALK_ARCHITECTURE = new Map([
  ["amd64", "x86_64"],
  ["arm64", "arm64"],
]);

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireString(value, field, pattern, code = "deployment_provider_invalid") {
  if (typeof value !== "string" || !pattern.test(value)) fail(code, `${field} is invalid`, 500);
  return value;
}

function requireSafeMilliseconds(value) {
  if (!Number.isSafeInteger(value) || value < 0) fail("deployment_provider_invalid", "clock is invalid", 500);
  return value;
}

function canonicalIDs(values, key, pattern) {
  if (!Array.isArray(values) || values.length === 0) {
    fail("deployment_provider_invalid", `${key} is missing from EC2 response`, 502);
  }
  const result = [...new Set(values.filter((value) => typeof value === "string" && pattern.test(value)))].sort();
  if (result.length !== values.length) {
    fail("deployment_provider_invalid", `${key} is invalid in EC2 response`, 502);
  }
  return result;
}

function deploymentTags(command) {
  return [
    { Key: "dirextalk:connection-id", Value: command.connection_id },
    { Key: "dirextalk:deployment-id", Value: command.payload.deployment_id },
    { Key: "dirextalk:managed-by", Value: "connection-stack-v2" },
    { Key: "dirextalk:request-sha256", Value: command.request_sha256 },
  ];
}

function tagSpecifications(tags) {
  return ["instance", "volume", "network-interface"].map((ResourceType) => ({ ResourceType, Tags: tags }));
}

function securityGroupName(command) {
  const digest = createHash("sha256")
    .update(`${command.connection_id}\0${command.payload.deployment_id}\0${command.request_sha256}`, "utf8")
    .digest("hex");
  return `dirextalk-${digest.slice(0, 32)}`;
}

function safeEgress(vpcCidr) {
  return [
    { IpProtocol: "tcp", FromPort: 443, ToPort: 443, IpRanges: [{ CidrIp: "0.0.0.0/0", Description: "Dirextalk Worker HTTPS egress" }] },
    { IpProtocol: "udp", FromPort: 53, ToPort: 53, IpRanges: [{ CidrIp: vpcCidr, Description: "Dirextalk Worker VPC DNS egress" }] },
    { IpProtocol: "tcp", FromPort: 53, ToPort: 53, IpRanges: [{ CidrIp: vpcCidr, Description: "Dirextalk Worker VPC DNS egress" }] },
  ];
}

function tagsMatch(group, expectedTags) {
  const actual = new Map((Array.isArray(group?.Tags) ? group.Tags : [])
    .filter((tag) => typeof tag?.Key === "string" && typeof tag?.Value === "string")
    .map((tag) => [tag.Key, tag.Value]));
  return expectedTags.every(({ Key, Value }) => actual.get(Key) === Value);
}

function noIngress(group) {
  return Array.isArray(group?.IpPermissions) && group.IpPermissions.length === 0;
}

function egressKey(permission) {
  return JSON.stringify({
    protocol: permission?.IpProtocol,
    from: permission?.FromPort ?? null,
    to: permission?.ToPort ?? null,
    cidrs: [...(permission?.IpRanges ?? [])].map((range) => range?.CidrIp).sort(),
    ipv6Cidrs: [...(permission?.Ipv6Ranges ?? [])].map((range) => range?.CidrIpv6).sort(),
    prefixListIds: [...(permission?.PrefixListIds ?? [])].map((item) => item?.PrefixListId).sort(),
    groupPairs: [...(permission?.UserIdGroupPairs ?? [])].map((item) => JSON.stringify({
      group_id: item?.GroupId ?? null,
      user_id: item?.UserId ?? null,
      vpc_id: item?.VpcId ?? null,
      peering_connection_id: item?.VpcPeeringConnectionId ?? null,
    })).sort(),
  });
}

function securityGroupEgressState(group, expected) {
  const actual = group?.IpPermissionsEgress;
  if (!Array.isArray(actual)) return "invalid";
  if (actual.length === 0) return "empty";
  const expectedKeys = new Set(expected.map(egressKey));
  const actualKeys = actual.map(egressKey);
  if (actualKeys.every((key) => expectedKeys.has(key)) && new Set(actualKeys).size === actualKeys.length) {
    return actualKeys.length === expected.length ? "expected" : "safe_subset";
  }
  if (actualKeys.length === 1 && actualKeys[0] === JSON.stringify({
    protocol: "-1",
    from: null,
    to: null,
    cidrs: ["0.0.0.0/0"],
    ipv6Cidrs: [],
    prefixListIds: [],
    groupPairs: [],
  })) {
    return "default";
  }
  return "unsafe";
}

function requireApprovedCandidateScope(approvalProof, candidate, region, availabilityZone) {
  const scope = approvalProof?.resource_scope;
  if (!isRecord(scope)
    || typeof scope.region !== "string"
    || typeof scope.instance_type !== "string"
    || typeof scope.architecture !== "string"
    || !Number.isSafeInteger(scope.vcpu)
    || !Number.isSafeInteger(scope.memory_mib)
    || !Number.isSafeInteger(scope.disk_gib)
    || typeof scope.purchase_option !== "string") {
    fail("deployment_provider_invalid", "authenticated deployment approval proof has no valid resource scope", 500);
  }
  const approvedGPUCount = scope.gpu_count ?? 0;
  const approvedGPUMemoryMiB = scope.gpu_memory_mib ?? 0;
  if (!Number.isSafeInteger(approvedGPUCount) || !Number.isSafeInteger(approvedGPUMemoryMiB)) {
    fail("deployment_provider_invalid", "authenticated deployment approval proof has invalid GPU scope", 500);
  }
  if (scope.region !== region
    || scope.instance_type !== candidate.instance_type
    || scope.architecture !== candidate.architecture
    || scope.vcpu !== candidate.vcpu
    || scope.memory_mib !== candidate.memory_mib
    || scope.disk_gib !== candidate.estimated_disk_gib
    || scope.purchase_option !== candidate.purchase_option
    || approvedGPUCount !== candidate.gpu_count
    || approvedGPUMemoryMiB !== candidate.gpu_memory_mib
    || (scope.availability_zones !== undefined && (!Array.isArray(scope.availability_zones)
      || !scope.availability_zones.includes(availabilityZone)))) {
    fail("approval_proof_mismatch", "approval proof does not bind the selected dedicated Worker resource", 409);
  }
  const networkScope = approvalProof?.network_scope;
  if (!isRecord(networkScope)
    || networkScope.public_ingress !== false
    || networkScope.entry_point !== "none"
    || networkScope.tls_required !== false
    || networkScope.authentication_required !== false
    || (networkScope.ingress !== undefined && (!Array.isArray(networkScope.ingress) || networkScope.ingress.length !== 0))) {
    fail("approval_proof_mismatch", "approval proof does not bind the isolated Worker network scope", 409);
  }
}

function candidateFromQuote(quote, payload, region, nowMs, approvalProof) {
  // Stack quote.plan_digest is the pre-price QuoteRequestV1 digest. The final
  // PlanV1 hash is instead bound by the node signature and ApprovalV1 proof,
  // because it does not exist until after the quote is issued.
  if (!isRecord(quote)
    || quote.quote_id !== payload.quote_id
    || quote.quote_digest !== payload.quote_digest
    || quote.region !== region) {
    fail("quote_mismatch", "the durable quote does not bind this deployment", 409);
  }
  if (typeof quote.valid_until !== "string" || Date.parse(quote.valid_until) <= nowMs) {
    fail("quote_expired", "the durable quote has expired", 409);
  }
  if (!Array.isArray(quote.candidates)) fail("quote_mismatch", "the durable quote is invalid", 500);
  const candidate = quote.candidates.find((value) => value?.candidate_id === payload.candidate_id);
  if (!isRecord(candidate)
    || typeof candidate.instance_type !== "string"
    || !AWS_ARCHITECTURE_BY_DIREXTALK_ARCHITECTURE.has(candidate.architecture)
    || candidate.purchase_option !== "on_demand"
    || !Number.isSafeInteger(candidate.vcpu)
    || candidate.vcpu < 1
    || !Number.isSafeInteger(candidate.memory_mib)
    || candidate.memory_mib < 1
    || !Number.isSafeInteger(candidate.gpu_count)
    || candidate.gpu_count < 0
    || !Number.isSafeInteger(candidate.gpu_memory_mib)
    || candidate.gpu_memory_mib < 0
    || (candidate.gpu_count === 0) !== (candidate.gpu_memory_mib === 0)
    || !Number.isSafeInteger(candidate.estimated_disk_gib)
    || candidate.estimated_disk_gib < 8
    || !Array.isArray(candidate.availability_zones)
    || !candidate.availability_zones.includes(payload.network.availability_zone)) {
    fail("quote_mismatch", "the selected quoted candidate is invalid for this deployment", 409);
  }
  requireApprovedCandidateScope(approvalProof, candidate, region, payload.network.availability_zone);
  return candidate;
}

function extractRunReceipt(output, command) {
  const instance = output?.Instances?.[0];
  const instanceId = instance?.InstanceId;
  const volumeIDs = (instance?.BlockDeviceMappings ?? []).map((mapping) => mapping?.Ebs?.VolumeId);
  const networkInterfaceIDs = (instance?.NetworkInterfaces ?? []).map((networkInterface) => networkInterface?.NetworkInterfaceId);
  return validateDeploymentReceipt({
    schema: "dirextalk.aws.deployment-receipt/v1",
    connection_id: command.connection_id,
    deployment_id: command.payload.deployment_id,
    request_sha256: command.request_sha256,
    resource_status: "provisioning",
    instance_id: instanceId,
    volume_ids: canonicalIDs(volumeIDs, "volume_ids", /^vol-[0-9a-f]{8,17}$/),
    network_interface_ids: canonicalIDs(networkInterfaceIDs, "network_interface_ids", /^eni-[0-9a-f]{8,17}$/),
  }, {
    connectionId: command.connection_id,
    deploymentId: command.payload.deployment_id,
    requestSHA256: command.request_sha256,
  });
}

// Ec2DedicatedWorkerProvisioner has a deliberately narrow provider surface.
// It can launch exactly one quoted EC2 VM with an immutable AMI, a dedicated
// zero-ingress security group, no public IP/key pair/instance profile, IMDSv2,
// encrypted retained gp3 storage, and deterministic ClientToken recovery.
// It neither receives nor generates Worker credentials, user data, or cloud
// control credentials for the VM.
export class Ec2DedicatedWorkerProvisioner {
  constructor({
    ec2Client,
    commandConstructors,
    deploymentStore,
    connectionId,
    connectionGeneration,
    region,
    workerBaseAmiId,
    workerResourceManifestDigest,
    workerNetwork,
    nowMs,
  }) {
    const requiredCommands = [
      "DescribeSubnetsCommand",
      "DescribeVpcsCommand",
      "DescribeImagesCommand",
      "DescribeSecurityGroupsCommand",
      "CreateSecurityGroupCommand",
      "RevokeSecurityGroupEgressCommand",
      "AuthorizeSecurityGroupEgressCommand",
      "RunInstancesCommand",
    ];
    if (!ec2Client?.send || !deploymentStore?.getDeployment || !deploymentStore?.getQuote || !deploymentStore?.putDeployment
      || !commandConstructors || !requiredCommands.every((name) => commandConstructors[name]) || typeof nowMs !== "function") {
      throw new TypeError("EC2 client, deployment store, clock, and typed command constructors are required");
    }
    this.ec2Client = ec2Client;
    this.commands = commandConstructors;
    this.deploymentStore = deploymentStore;
    this.connectionId = requireString(connectionId, "connectionId", ID_PATTERN);
    if (!Number.isSafeInteger(connectionGeneration) || connectionGeneration < 1) {
      throw new TypeError("connectionGeneration must be a positive integer");
    }
    this.connectionGeneration = connectionGeneration;
    this.region = requireString(region, "region", REGION_PATTERN);
    this.workerBaseAmiId = requireString(workerBaseAmiId, "workerBaseAmiId", AMI_ID_PATTERN);
    this.workerResourceManifestDigest = requireString(workerResourceManifestDigest, "workerResourceManifestDigest", NAMED_SHA256_PATTERN);
    if (!isRecord(workerNetwork)) throw new TypeError("workerNetwork is required");
    this.workerNetwork = {
      vpc_id: requireString(workerNetwork.vpc_id, "workerNetwork.vpc_id", /^vpc-[0-9a-f]{8,17}$/),
      subnet_id: requireString(workerNetwork.subnet_id, "workerNetwork.subnet_id", /^subnet-[0-9a-f]{8,17}$/),
      availability_zone: requireString(workerNetwork.availability_zone, "workerNetwork.availability_zone", /^(?:af|ap|ca|cn|eu|il|me|mx|sa|us)(?:-gov)?-[a-z]+-\d[a-z]$/),
    };
    this.nowMs = nowMs;
  }

  async ensure(authenticatedCommand) {
    const nowMs = requireSafeMilliseconds(this.nowMs());
    const command = this.#validateAuthenticatedCommand(authenticatedCommand);
    const existing = await this.#getExisting(command);
    if (existing) return existing;
    const quote = await this.#getQuote(command);
    const candidate = candidateFromQuote(quote, command.payload, this.region, nowMs, command.approval_proof);
    await this.#preflightNetwork(command);
    await this.#preflightImage(command, candidate);
    const groupId = await this.#ensureSecurityGroup(command);
    const receipt = extractRunReceipt(await this.#send("RunInstancesCommand", this.#runInput(command, candidate, groupId)), command);
    const persisted = await this.#putDeployment(receipt);
    return validateDeploymentReceipt(persisted, {
      connectionId: command.connection_id,
      deploymentId: command.payload.deployment_id,
      requestSHA256: command.request_sha256,
    });
  }

  #validateAuthenticatedCommand(command) {
    if (!isRecord(command)) fail("deployment_provider_invalid", "authenticated command is invalid", 500);
    const connectionId = requireString(command.connection_id, "connection_id", ID_PATTERN);
    const requestSHA256 = requireString(command.request_sha256, "request_sha256", SHA256_PATTERN);
    if (connectionId !== this.connectionId || command.expected_generation !== this.connectionGeneration) {
      fail("wrong_connection", "authenticated command does not match this connection", 403);
    }
    if (!isRecord(command.approval_proof)) {
      fail("deployment_provider_invalid", "authenticated deployment command is missing its Flutter approval proof", 500);
    }
    const payload = validateDeploymentCreatePayload(command.payload, {
      approvalBinding: command.approval_binding,
      expectedGeneration: this.connectionGeneration,
    });
    if (payload.worker_artifact.ami_id !== this.workerBaseAmiId
      || payload.resource_manifest_digest !== this.workerResourceManifestDigest
      || payload.network.vpc_id !== this.workerNetwork.vpc_id
      || payload.network.subnet_id !== this.workerNetwork.subnet_id
      || payload.network.availability_zone !== this.workerNetwork.availability_zone) {
      fail("worker_configuration_mismatch", "deployment does not match this Connection Stack trusted Worker configuration", 409);
    }
    return { ...command, connection_id: connectionId, request_sha256: requestSHA256, payload };
  }

  async #getExisting(command) {
    let existing;
    try {
      existing = await this.deploymentStore.getDeployment({
        connection_id: command.connection_id,
        deployment_id: command.payload.deployment_id,
      });
    } catch (error) {
      if (error instanceof ConnectionStackV2Error) throw error;
      fail("deployment_store_unavailable", "deployment state storage is unavailable", 503);
    }
    if (!existing) return undefined;
    if (existing.request_sha256 !== command.request_sha256) {
      fail("deployment_id_conflict", "deployment id is already bound to another request", 409);
    }
    return validateDeploymentReceipt(existing, {
      connectionId: command.connection_id,
      deploymentId: command.payload.deployment_id,
      requestSHA256: command.request_sha256,
    });
  }

  async #getQuote(command) {
    try {
      const quote = await this.deploymentStore.getQuote({
        connection_id: command.connection_id,
        quote_id: command.payload.quote_id,
      });
      if (!quote) fail("quote_not_found", "the approved quote is not available", 409);
      return quote;
    } catch (error) {
      if (error instanceof ConnectionStackV2Error) throw error;
      fail("deployment_store_unavailable", "quote storage is unavailable", 503);
    }
  }

  async #putDeployment(receipt) {
    try {
      return await this.deploymentStore.putDeployment(receipt);
    } catch (error) {
      if (error instanceof ConnectionStackV2Error) throw error;
      fail("deployment_store_unavailable", "deployment state storage is unavailable", 503);
    }
  }

  async #preflightNetwork(command) {
    const subnetOutput = await this.#send("DescribeSubnetsCommand", { SubnetIds: [command.payload.network.subnet_id] });
    const subnet = subnetOutput?.Subnets?.[0];
    if (!isRecord(subnet)
      || subnet.SubnetId !== command.payload.network.subnet_id
      || subnet.VpcId !== command.payload.network.vpc_id
       || subnet.AvailabilityZone !== command.payload.network.availability_zone
       || !Number.isSafeInteger(subnet.AvailableIpAddressCount)
       || subnet.AvailableIpAddressCount < 1
       || subnet.MapPublicIpOnLaunch !== false
       || subnet.AssignIpv6AddressOnCreation === true
      || (Array.isArray(subnet.Ipv6CidrBlockAssociationSet) && subnet.Ipv6CidrBlockAssociationSet.length > 0)) {
      fail("worker_network_invalid", "the configured Worker subnet is not an eligible private IPv4 subnet", 409);
    }
    const vpcOutput = await this.#send("DescribeVpcsCommand", { VpcIds: [command.payload.network.vpc_id] });
    const vpc = vpcOutput?.Vpcs?.[0];
    if (!isRecord(vpc) || vpc.VpcId !== command.payload.network.vpc_id
      || typeof vpc.CidrBlock !== "string" || !/^\d{1,3}(?:\.\d{1,3}){3}\/\d{1,2}$/.test(vpc.CidrBlock)) {
      fail("worker_network_invalid", "the configured Worker VPC is invalid", 409);
    }
    command.worker_vpc_cidr = vpc.CidrBlock;
  }

  async #preflightImage(command, candidate) {
    const imageOutput = await this.#send("DescribeImagesCommand", { ImageIds: [command.payload.worker_artifact.ami_id] });
    const image = imageOutput?.Images?.[0];
    if (!isRecord(image)
      || image.ImageId !== command.payload.worker_artifact.ami_id
      || image.State !== "available"
      || image.Architecture !== AWS_ARCHITECTURE_BY_DIREXTALK_ARCHITECTURE.get(candidate.architecture)
      || (image.RootDeviceName !== undefined && typeof image.RootDeviceName !== "string")) {
      fail("worker_artifact_invalid", "the configured Worker AMI is unavailable or does not match the quoted architecture", 409);
    }
    command.worker_root_device_name = image.RootDeviceName || "/dev/sda1";
  }

  async #ensureSecurityGroup(command) {
    const name = securityGroupName(command);
    const expectedTags = deploymentTags(command);
    const expectedEgress = safeEgress(command.worker_vpc_cidr);
    let group = await this.#findSecurityGroup(command.payload.network.vpc_id, name);
    if (group) {
      if (!tagsMatch(group, expectedTags) || !noIngress(group)) {
        fail("worker_security_group_invalid", "the dedicated Worker security group is not safe for this deployment", 409);
      }
      return this.#finishSecurityGroupEgress(group, expectedEgress);
    }
    let created;
    try {
      created = await this.#send("CreateSecurityGroupCommand", {
        GroupName: name,
        Description: `Dirextalk isolated Worker ${command.payload.deployment_id}`,
        VpcId: command.payload.network.vpc_id,
        TagSpecifications: [{ ResourceType: "security-group", Tags: expectedTags }],
      });
    } catch (error) {
      if (!(error instanceof ConnectionStackV2Error) || error.code !== "deployment_provider_unavailable") throw error;
      group = await this.#findSecurityGroup(command.payload.network.vpc_id, name);
      if (!group || !tagsMatch(group, expectedTags) || !noIngress(group)) throw error;
      return this.#finishSecurityGroupEgress(group, expectedEgress);
    }
    const groupId = requireString(created?.GroupId, "GroupId", /^sg-[0-9a-f]{8,17}$/, "worker_security_group_invalid");
    return this.#finishSecurityGroupEgress({
      GroupId: groupId,
      IpPermissionsEgress: [{ IpProtocol: "-1", IpRanges: [{ CidrIp: "0.0.0.0/0" }] }],
    }, expectedEgress);
  }

  async #finishSecurityGroupEgress(group, expectedEgress) {
    const groupId = requireString(group.GroupId, "GroupId", /^sg-[0-9a-f]{8,17}$/, "worker_security_group_invalid");
    const state = securityGroupEgressState(group, expectedEgress);
    if (state === "expected") return groupId;
    if (state === "unsafe" || state === "invalid") {
      fail("worker_security_group_invalid", "the dedicated Worker security group is not safe for this deployment", 409);
    }
    // AWS initially grants the new group an unrestricted default egress rule.
    // Remove it before any instance can be attached, then add only HTTPS and
    // VPC DNS. A response can be lost between those two calls, so a retry may
    // observe the default rule, no rule, or a safe subset and resumes only from
    // those non-expansive states. No ingress API is ever called.
    if (state === "default") {
      await this.#send("RevokeSecurityGroupEgressCommand", {
        GroupId: groupId,
        IpPermissions: [{ IpProtocol: "-1", IpRanges: [{ CidrIp: "0.0.0.0/0" }] }],
      });
    }
    const current = new Set((group.IpPermissionsEgress ?? []).map(egressKey));
    const missing = expectedEgress.filter((permission) => !current.has(egressKey(permission)));
    if (missing.length > 0) {
      await this.#send("AuthorizeSecurityGroupEgressCommand", { GroupId: groupId, IpPermissions: missing });
    }
    return groupId;
  }

  async #findSecurityGroup(vpcId, groupName) {
    const output = await this.#send("DescribeSecurityGroupsCommand", {
      Filters: [
        { Name: "vpc-id", Values: [vpcId] },
        { Name: "group-name", Values: [groupName] },
      ],
    });
    if (!Array.isArray(output?.SecurityGroups) || output.SecurityGroups.length > 1) {
      fail("worker_security_group_invalid", "the dedicated Worker security group lookup is invalid", 409);
    }
    return output.SecurityGroups[0];
  }

  #runInput(command, candidate, groupId) {
    const tags = deploymentTags(command);
    return {
      ImageId: command.payload.worker_artifact.ami_id,
      InstanceType: candidate.instance_type,
      MinCount: 1,
      MaxCount: 1,
      ClientToken: command.request_sha256,
      InstanceInitiatedShutdownBehavior: "terminate",
      MetadataOptions: {
        HttpTokens: "required",
        HttpEndpoint: "enabled",
        HttpPutResponseHopLimit: 1,
        InstanceMetadataTags: "disabled",
      },
      BlockDeviceMappings: [{
        DeviceName: command.worker_root_device_name,
        Ebs: {
          DeleteOnTermination: false,
          Encrypted: true,
          VolumeSize: candidate.estimated_disk_gib,
          VolumeType: "gp3",
        },
      }],
      NetworkInterfaces: [{
        DeviceIndex: 0,
        SubnetId: command.payload.network.subnet_id,
        Groups: [groupId],
        AssociatePublicIpAddress: false,
        Ipv6AddressCount: 0,
        DeleteOnTermination: true,
      }],
      TagSpecifications: tagSpecifications(tags),
    };
  }

  async #send(commandName, input) {
    try {
      return await this.ec2Client.send(new this.commands[commandName](input));
    } catch (error) {
      if (error instanceof ConnectionStackV2Error) throw error;
      fail("deployment_provider_unavailable", "the EC2 deployment provider is unavailable", 503);
    }
  }
}
