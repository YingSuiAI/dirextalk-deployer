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
assert.equal(template.Metadata.DirextalkConnectionStackV2.Stage, "contract-only");
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
assert.deepEqual(Object.keys(broker.Properties.Events), ["PostCommand"]);
assert.equal(broker.Properties.Events.PostCommand.Properties.Path, "/v2/commands");
assert.equal(broker.Properties.Events.PostCommand.Properties.Method, "post");
assert.equal(broker.Properties.Environment.Variables.DEVICE_APPROVAL_KEY_ID.Ref, "DeviceApprovalKeyId");
assert.equal(broker.Properties.Environment.Variables.DEVICE_APPROVAL_PUBLIC_KEY_SPKI_B64.Ref, "DeviceApprovalPublicKeySpkiBase64");

const resourceText = JSON.stringify(template.Resources);
assert.doesNotMatch(resourceText, /AWS::EC2::|AWS::S3::|AWS::IAM::InstanceProfile/);
assert.doesNotMatch(resourceText, /iam:PassRole|ec2:\*|ec2:RunInstances|iam:\*|secretsmanager:GetSecretValue/i);
assert.doesNotMatch(resourceText, /ssh|keypair|user.?data/i);
assert.ok(!Object.keys(template.Outputs).some((name) => /secret|token|private/i.test(name)), "the stack must not output secrets");

const handlerText = readFileSync(new URL("scripts/connection-stack-v2/src/handler.mjs", root), "utf8");
assert.match(handlerText, /connection_stack_v2_not_activated/);
assert.doesNotMatch(handlerText, /@aws-sdk\//);
const { handler } = await import(new URL("scripts/connection-stack-v2/src/handler.mjs", root));
const wrongSchemaResponse = await handler({ body: JSON.stringify({ schema: "dirextalk.aws.command/v1" }) });
assert.equal(wrongSchemaResponse.statusCode, 400);
const v2Response = await handler({ body: JSON.stringify({ schema: "dirextalk.aws.command/v2" }) });
assert.equal(v2Response.statusCode, 503);
assert.equal(JSON.parse(v2Response.body).error.code, "connection_stack_v2_not_activated");

console.log("connection stack v2 template contract ok");
