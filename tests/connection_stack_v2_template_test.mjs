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

assert.equal(template.Transform, "AWS::Serverless-2016-10-31");
assert.equal(template.Metadata.DirextalkConnectionStackV2.Stage, "durable-read-only-quote");
assert.equal(template.Metadata.DirextalkConnectionStackV2.Execution, "receipt-approval-challenge-and-read-only-on-demand-quote");
assert.equal(commandSchema.properties.schema.const, "dirextalk.aws.command/v2");
assert.equal(approvalBindingSchema.properties.schema.const, "dirextalk.aws.approval-binding/v2");
assert.equal(workerSchema.properties.schema.const, "dirextalk.worker-bootstrap/v1");
assert.equal(commandSchema.additionalProperties, false);
assert.equal(approvalBindingSchema.additionalProperties, false);
assert.equal(workerSchema.additionalProperties, false);
assert.ok(commandSchema.properties.action.enum.includes("approval.challenge.request"));
assert.ok(commandSchema.properties.action.enum.includes("artifact.put"));
assert.ok(commandSchema.properties.action.enum.includes("deployment.destroy"));
assert.ok(approvalBindingSchema.required.includes("resource_scope_digest"));
assert.ok(approvalBindingSchema.required.includes("network_scope_digest"));
assert.ok(approvalBindingSchema.required.includes("secret_scope_digest"));
assert.ok(approvalBindingSchema.required.includes("integration_scope_digest"));

for (const parameter of [
  "ConnectionId",
  "NodeKeyId",
  "NodePublicKeySpkiBase64",
  "DeviceApprovalKeyId",
  "DeviceApprovalPublicKeySpkiBase64",
]) {
  assert.ok(template.Parameters[parameter], `${parameter} is required to establish the two-key boundary`);
}
assert.ok(!/access.?key|secret.?access.?key|session.?token/i.test(JSON.stringify(template.Parameters)), "bootstrap credentials must never be stack parameters");

for (const name of ["CommandReceiptsTable", "ApprovalChallengesTable", "ConnectionCountersTable"]) {
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
assert.equal(broker.Properties.Environment.Variables.CONNECTION_COUNTERS_TABLE.Ref, "ConnectionCountersTable");
assert.equal(broker.Properties.Timeout, 20, "read-only price lookups must have a bounded network timeout");

const rolePolicy = template.Resources.BrokerContractRole.Properties.Policies[0].PolicyDocument.Statement;
assert.ok(rolePolicy.some((statement) => statement.Action === "dynamodb:GetItem"));
assert.ok(rolePolicy.some((statement) => statement.Action === "dynamodb:TransactWriteItems"));
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
  "instance availability lookup must remain the only EC2 permission",
);
assert.doesNotMatch(JSON.stringify(rolePolicy), /dynamodb:(?:PutItem|UpdateItem|DeleteItem|Scan|Query)/);
assert.doesNotMatch(JSON.stringify(rolePolicy), /pricing:\*|ec2:\*/i);

const resourceText = JSON.stringify(template.Resources);
assert.doesNotMatch(resourceText, /AWS::EC2::|AWS::S3::|AWS::IAM::InstanceProfile/);
assert.doesNotMatch(resourceText, /iam:PassRole|ec2:\*|ec2:RunInstances|iam:\*|secretsmanager:GetSecretValue/i);
assert.doesNotMatch(resourceText, /ssh|keypair|user.?data/i);
assert.ok(!Object.keys(template.Outputs).some((name) => /secret|token|private/i.test(name)), "the stack must not output secrets");

const handlerText = readFileSync(new URL("scripts/connection-stack-v2/src/handler.mjs", root), "utf8");
assert.match(handlerText, /createV2ChallengeApprovalService/);
assert.match(handlerText, /DynamoV2ReceiptStore/);
assert.match(handlerText, /@aws-sdk\/client-dynamodb/);
assert.match(handlerText, /@aws-sdk\/client-ec2/);
assert.match(handlerText, /@aws-sdk\/client-pricing/);
assert.match(handlerText, /AwsOnDemandQuoteProvider/);
assert.doesNotMatch(handlerText, /@aws-sdk\/client-(?:s3|iam|secrets-manager)/);
assert.doesNotMatch(handlerText, /RunInstances|TerminateInstances|PassRole|CreateRole|GetSecretValue/);

const brokerPackage = JSON.parse(readFileSync(
  new URL("scripts/connection-stack-v2/src/package.json", root),
  "utf8",
));
assert.match(brokerPackage.dependencies["@aws-sdk/client-dynamodb"], /^\d+\.\d+\.\d+$/);
assert.match(brokerPackage.dependencies["@aws-sdk/client-ec2"], /^\d+\.\d+\.\d+$/);
assert.match(brokerPackage.dependencies["@aws-sdk/client-pricing"], /^\d+\.\d+\.\d+$/);

console.log("connection stack v2 template contract ok");
