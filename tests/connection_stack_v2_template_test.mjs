import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const template = JSON.parse(readFileSync(new URL("scripts/connection-stack-v2/template.json", root), "utf8"));
const commandSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/broker-command-v2.schema.json", root),
  "utf8",
));
const approvalBindingSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/approval-binding-v2.schema.json", root),
  "utf8",
));
const workerSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/worker-bootstrap-v1.schema.json", root),
  "utf8",
));
const registrationSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/connection-registration-v1.schema.json", root),
  "utf8",
));
const deploymentRequestSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/connection-stack-deploy-request-v1.schema.json", root),
  "utf8",
));
const registrationManifestSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/connection-registration-manifest-v1.schema.json", root),
  "utf8",
));
const approvalProofSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/approval-proof-v1.schema.json", root),
  "utf8",
));
const deploymentCreateSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/deployment-create-v1.schema.json", root),
  "utf8",
));
const deploymentReceiptSchema = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/schemas/deployment-receipt-v1.schema.json", root),
  "utf8",
));

assert.equal(template.Transform, "AWS::Serverless-2016-10-31");
assert.equal(template.Metadata.DirextalkConnectionStackV2.Stage, "durable-registration-quote-and-isolated-worker-create");
assert.equal(template.Metadata.DirextalkConnectionStackV2.Execution, "receipt-registration-attestation-approval-challenge-read-only-on-demand-quote-and-typed-worker-create");
assert.equal(commandSchema.properties.schema.const, "dirextalk.aws.command/v2");
assert.equal(approvalBindingSchema.properties.schema.const, "dirextalk.aws.approval-binding/v2");
assert.equal(workerSchema.properties.schema.const, "dirextalk.worker-bootstrap/v1");
assert.equal(registrationSchema.properties.schema.const, "dirextalk.aws.connection-registration/v1");
assert.equal(deploymentRequestSchema.properties.schema.const, "dirextalk.aws.connection-stack-deploy-request/v1");
assert.equal(registrationManifestSchema.properties.schema.const, "dirextalk.aws.connection-registration-manifest/v1");
assert.equal(approvalProofSchema.properties.schema_version.const, "cloud-orchestrator/v1");
assert.equal(deploymentCreateSchema.properties.schema.const, "dirextalk.aws.deployment-create/v1");
assert.equal(deploymentReceiptSchema.properties.schema.const, "dirextalk.aws.deployment-receipt/v1");
assert.equal(commandSchema.additionalProperties, false);
assert.equal(approvalBindingSchema.additionalProperties, false);
assert.equal(workerSchema.additionalProperties, false);
assert.equal(registrationSchema.additionalProperties, false);
assert.equal(deploymentRequestSchema.additionalProperties, false);
assert.equal(registrationManifestSchema.additionalProperties, false);
assert.equal(approvalProofSchema.additionalProperties, false);
assert.equal(deploymentCreateSchema.additionalProperties, false);
assert.equal(deploymentReceiptSchema.additionalProperties, false);
assert.ok(commandSchema.properties.action.enum.includes("approval.challenge.request"));
assert.ok(commandSchema.properties.action.enum.includes("connection.registration.verify"));
assert.ok(commandSchema.properties.action.enum.includes("artifact.put"));
assert.ok(commandSchema.properties.action.enum.includes("deployment.destroy"));
assert.ok(approvalBindingSchema.required.includes("resource_scope_digest"));
assert.ok(approvalBindingSchema.required.includes("network_scope_digest"));
assert.ok(approvalBindingSchema.required.includes("secret_scope_digest"));
assert.ok(approvalBindingSchema.required.includes("integration_scope_digest"));
assert.equal(commandSchema.properties.approval_proof.$ref, "approval-proof-v1.schema.json");
assert.equal(approvalProofSchema.properties.secret_scope.type.includes("null"), true, "ApprovalV1 nil scopes must retain CBOR null semantics");
assert.equal(approvalProofSchema.properties.integration_scope.type.includes("null"), true, "ApprovalV1 nil scopes must retain CBOR null semantics");
assert.ok(deploymentRequestSchema.required.includes("template_sha256"));
assert.ok(deploymentRequestSchema.required.includes("source_tree_sha256"));
for (const field of ["worker_base_ami_id", "worker_vpc_id", "worker_subnet_id", "worker_availability_zone", "worker_resource_manifest_digest"]) {
  assert.ok(deploymentRequestSchema.required.includes(field), `${field} must bind the private Worker placement`);
}

for (const parameter of [
  "ConnectionId",
  "NodeKeyId",
  "NodePublicKeySpkiBase64",
  "DeviceApprovalKeyId",
  "DeviceApprovalPublicKeySpkiBase64",
  "WorkerBaseAmiId",
  "WorkerVpcId",
  "WorkerSubnetId",
  "WorkerAvailabilityZone",
  "WorkerResourceManifestDigest",
]) {
  assert.ok(template.Parameters[parameter], `${parameter} is required to establish the two-key boundary`);
}
assert.ok(!/access.?key|secret.?access.?key|session.?token/i.test(JSON.stringify(template.Parameters)), "bootstrap credentials must never be stack parameters");

for (const name of [
  "CommandReceiptsTable",
  "ApprovalChallengesTable",
  "ApprovalProofsTable",
  "IssuedQuotesTable",
  "DeploymentReceiptsTable",
  "ConnectionCountersTable",
]) {
  const resource = template.Resources[name];
  assert.equal(resource.Type, "AWS::DynamoDB::Table");
  assert.equal(resource.DeletionPolicy, "Retain");
  assert.equal(resource.UpdateReplacePolicy, "Retain");
  assert.equal(resource.Properties.BillingMode, "PAY_PER_REQUEST");
  assert.equal(resource.Properties.DeletionProtectionEnabled, true);
  assert.equal(resource.Properties.PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled, true);
  assert.equal(resource.Properties.SSESpecification.SSEType, "KMS");
}

const broker = template.Resources.BrokerCommandFunction;
assert.equal(broker.Type, "AWS::Serverless::Function");
assert.equal(broker.Metadata.BuildProperties.UseNpmCi, true, "SAM must install the lockfile-pinned DynamoDB SDK into deployment artifacts");
assert.deepEqual(Object.keys(broker.Properties.Events), ["PostCommand"]);
assert.equal(broker.Properties.Events.PostCommand.Properties.Path, "/v2/commands");
assert.equal(broker.Properties.Events.PostCommand.Properties.Method, "post");
assert.equal(broker.Properties.Environment.Variables.DEVICE_APPROVAL_KEY_ID.Ref, "DeviceApprovalKeyId");
assert.equal(broker.Properties.Environment.Variables.DEVICE_APPROVAL_PUBLIC_KEY_SPKI_B64.Ref, "DeviceApprovalPublicKeySpkiBase64");
assert.equal(broker.Properties.Environment.Variables.COMMAND_RECEIPTS_TABLE.Ref, "CommandReceiptsTable");
assert.equal(broker.Properties.Environment.Variables.APPROVAL_CHALLENGES_TABLE.Ref, "ApprovalChallengesTable");
assert.equal(broker.Properties.Environment.Variables.APPROVAL_PROOFS_TABLE.Ref, "ApprovalProofsTable");
assert.equal(broker.Properties.Environment.Variables.ISSUED_QUOTES_TABLE.Ref, "IssuedQuotesTable");
assert.equal(broker.Properties.Environment.Variables.DEPLOYMENT_RECEIPTS_TABLE.Ref, "DeploymentReceiptsTable");
assert.equal(broker.Properties.Environment.Variables.CONNECTION_COUNTERS_TABLE.Ref, "ConnectionCountersTable");
assert.equal(broker.Properties.Environment.Variables.STACK_ACCOUNT_ID.Ref, "AWS::AccountId");
assert.equal(broker.Properties.Environment.Variables.STACK_REGION.Ref, "AWS::Region");
assert.equal(broker.Properties.Environment.Variables.STACK_ARN.Ref, "AWS::StackId");
assert.equal(broker.Properties.Environment.Variables.AWS_URL_SUFFIX.Ref, "AWS::URLSuffix");
assert.equal(broker.Properties.Environment.Variables.BROKER_STAGE_NAME.Ref, "StageName");
assert.equal(broker.Properties.Environment.Variables.WORKER_BASE_AMI_ID.Ref, "WorkerBaseAmiId");
assert.equal(broker.Properties.Environment.Variables.WORKER_VPC_ID.Ref, "WorkerVpcId");
assert.equal(broker.Properties.Environment.Variables.WORKER_SUBNET_ID.Ref, "WorkerSubnetId");
assert.equal(broker.Properties.Environment.Variables.WORKER_AVAILABILITY_ZONE.Ref, "WorkerAvailabilityZone");
assert.equal(broker.Properties.Environment.Variables.WORKER_RESOURCE_MANIFEST_DIGEST.Ref, "WorkerResourceManifestDigest");
assert.equal(broker.Properties.Timeout, 30, "typed EC2 creation must retain a bounded Lambda timeout");

const rolePolicy = template.Resources.BrokerContractRole.Properties.Policies[0].PolicyDocument.Statement;
assert.ok(rolePolicy.some((statement) => statement.Action === "dynamodb:GetItem"));
assert.ok(rolePolicy.some((statement) => statement.Action === "dynamodb:TransactWriteItems"));
assert.ok(rolePolicy.some((statement) => statement.Action === "dynamodb:PutItem"), "only the private deployment receipt needs a direct DynamoDB write");
assert.deepEqual(
  rolePolicy.find((statement) => statement.Action === "pricing:GetProducts"),
  {
    Sid: "ReadOnDemandPriceListOnly",
    Effect: "Allow",
    Action: "pricing:GetProducts",
    Resource: "*",
  },
  "AWS Price List lookup must remain its only pricing permission",
);
assert.deepEqual(
  rolePolicy.find((statement) => statement.Action === "ec2:DescribeInstanceTypeOfferings"),
  {
    Sid: "ReadInstanceTypeOfferingsOnly",
    Effect: "Allow",
    Action: "ec2:DescribeInstanceTypeOfferings",
    Resource: "*",
  },
  "instance availability lookup must remain read-only",
);
assert.deepEqual(
  rolePolicy.find((statement) => statement.Action === "ec2:DescribeInstanceTypes"),
  {
    Sid: "ReadInstanceTypeCapacityOnly",
    Effect: "Allow",
    Action: "ec2:DescribeInstanceTypes",
    Resource: "*",
  },
  "instance capacity lookup must remain read-only",
);
const providerPolicy = JSON.stringify(rolePolicy);
assert.doesNotMatch(providerPolicy, /dynamodb:(?:UpdateItem|DeleteItem|Scan|Query|BatchWriteItem)/);
assert.doesNotMatch(JSON.stringify(rolePolicy), /pricing:\*|ec2:\*/i);
const typedWorkerStatement = rolePolicy.find((statement) => statement.Sid === "CreateDedicatedWorkerOnly");
assert.deepEqual(typedWorkerStatement.Action, [
  "ec2:CreateSecurityGroup",
  "ec2:RevokeSecurityGroupEgress",
  "ec2:AuthorizeSecurityGroupEgress",
  "ec2:RunInstances",
]);
assert.equal(typedWorkerStatement.Condition.StringEquals["aws:RequestedRegion"].Ref, "AWS::Region");
assert.deepEqual(
  rolePolicy.find((statement) => statement.Sid === "TagDedicatedWorkerAtCreateOnly").Condition.StringEquals["ec2:CreateAction"],
  ["CreateSecurityGroup", "RunInstances"],
);
assert.doesNotMatch(providerPolicy, /ec2:(?:TerminateInstances|CreateVpc|CreateNatGateway|AllocateAddress|AssociateAddress|CreateKeyPair)|iam:PassRole|iam:\*|secretsmanager:GetSecretValue/i);

const resourceText = JSON.stringify(template.Resources);
assert.doesNotMatch(resourceText, /AWS::EC2::|AWS::S3::|AWS::IAM::InstanceProfile/);
assert.doesNotMatch(resourceText, /iam:PassRole|ec2:\*|iam:\*|secretsmanager:GetSecretValue/i);
assert.doesNotMatch(resourceText, /ssh|keypair|user.?data/i);
assert.ok(!Object.keys(template.Outputs).some((name) => /secret|token|private/i.test(name)), "the stack must not output secrets");
assert.deepEqual(Object.keys(template.Outputs), [
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
], "the Stack must expose only the nonsecret registration-manifest values");
assert.doesNotMatch(JSON.stringify(template.Outputs), /NodePublicKey|DeviceApproval|TableArn|ReceiptSigningKeyArn/);

const handlerText = readFileSync(new URL("scripts/connection-stack-v2/src/handler.mjs", root), "utf8");
assert.match(handlerText, /createV2ChallengeApprovalService/);
assert.match(handlerText, /DynamoV2ReceiptStore/);
assert.match(handlerText, /@aws-sdk\/client-dynamodb/);
assert.match(handlerText, /@aws-sdk\/client-ec2/);
assert.match(handlerText, /@aws-sdk\/client-pricing/);
assert.match(handlerText, /AwsOnDemandQuoteProvider/);
assert.match(handlerText, /registrationRuntimeContext/);
assert.match(handlerText, /DynamoDeploymentStore/);
assert.match(handlerText, /Ec2DedicatedWorkerProvisioner/);
assert.match(handlerText, /RunInstancesCommand/);
assert.doesNotMatch(handlerText, /@aws-sdk\/client-(?:s3|iam|secrets-manager)/);
assert.doesNotMatch(handlerText, /TerminateInstances|PassRole|CreateRole|GetSecretValue/);

const brokerPackage = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/src/package.json", root),
  "utf8",
));
assert.match(brokerPackage.dependencies["@aws-sdk/client-dynamodb"], /^\d+\.\d+\.\d+$/);
assert.match(brokerPackage.dependencies["@aws-sdk/client-ec2"], /^\d+\.\d+\.\d+$/);
assert.match(brokerPackage.dependencies["@aws-sdk/client-pricing"], /^\d+\.\d+\.\d+$/);

console.log("connection stack v2 template contract ok");
