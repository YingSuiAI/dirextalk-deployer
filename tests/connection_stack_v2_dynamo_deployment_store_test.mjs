import assert from "node:assert/strict";

import {
  DynamoDeploymentStore,
} from "../scripts/connection-stack-v2/src/dynamo-deployment-store.mjs";
import {
  cloudOrchestratorQuoteDigest,
} from "../scripts/connection-stack-v2/src/quote-contract.mjs";

class GetItemCommand {
  constructor(input) { this.input = input; }
}

class UpdateItemCommand {
  constructor(input) { this.input = input; }
}

const NOW = Date.parse("2026-07-14T07:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const QUOTE_ID = `quote-${"b".repeat(32)}`;
const DEPLOYMENT_ID = "deployment-v2-001";
const REQUEST_SHA256 = "a".repeat(64);
const BOOTSTRAP_SESSION_ID = "worker-session-v2-001";

function quote() {
  return {
    schema: "dirextalk.aws.quote/v1",
    quote_id: QUOTE_ID,
    connection_id: CONNECTION_ID,
    command_id: "command-v2-quote-001",
    request_sha256: "b".repeat(64),
    quote_request_id: "quote-request-v2-001",
    plan_digest: `sha256:${"c".repeat(64)}`,
    region: "ap-south-1",
    currency: "USD",
    quoted_at: "2026-07-14T07:00:00.000Z",
    valid_until: "2026-07-14T07:15:00.000Z",
    candidates: [{
      candidate_id: "candidate-recommended-001",
      tier: "recommended",
      instance_type: "m7i.xlarge",
      purchase_option: "on_demand",
      estimated_disk_gib: 80,
      architecture: "amd64",
      vcpu: 4,
      memory_mib: 16384,
      gpu_count: 0,
      gpu_memory_mib: 0,
      hourly_minor: 2016,
      thirty_day_minor: 1451520,
      startup_upper_minor: 0,
      availability_zones: ["ap-south-1a", "ap-south-1b"],
    }],
    included_items: ["ec2_linux_ondemand"],
    unincluded_items: ["cloudwatch_logs", "data_transfer", "ebs_gp3", "public_ipv4", "snapshots", "taxes"],
  };
}

function quoteContext(value) {
  return {
    connection_id: value.connection_id,
    command_id: value.command_id,
    request_sha256: value.request_sha256,
    quote_request: {
      quote_request_id: value.quote_request_id,
      plan_digest: value.plan_digest,
      region: value.region,
      candidates: value.candidates.map(({ candidate_id, tier, instance_type, purchase_option, estimated_disk_gib }) => ({
        candidate_id, tier, instance_type, purchase_option, estimated_disk_gib,
      })),
    },
    issued_at: value.quoted_at,
    expires_at: value.quoted_at,
  };
}

function quoteItem(value = quote()) {
  return {
    connection_id: { S: value.connection_id },
    quote_id: { S: value.quote_id },
    quote_digest: { S: cloudOrchestratorQuoteDigest(value, quoteContext(value)) },
    plan_digest: { S: value.plan_digest },
    valid_until: { S: value.valid_until },
    command_id: { S: value.command_id },
    request_sha256: { S: value.request_sha256 },
    quote_json: { S: JSON.stringify(value) },
  };
}

function receipt(requestSHA256 = REQUEST_SHA256) {
  return {
    schema: "dirextalk.aws.deployment-receipt/v1",
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: requestSHA256,
    resource_status: "provisioning",
    instance_id: "i-0123456789abcdef0",
    volume_ids: ["vol-0123456789abcdef0"],
    network_interface_ids: ["eni-0123456789abcdef0"],
  };
}

function deploymentItem(value = receipt()) {
  return {
    connection_id: { S: value.connection_id },
    deployment_id: { S: value.deployment_id },
    request_sha256: { S: value.request_sha256 },
    receipt_json: { S: JSON.stringify(value) },
  };
}

function reservedDeploymentItem(requestSHA256 = REQUEST_SHA256) {
  return {
    connection_id: { S: CONNECTION_ID },
    deployment_id: { S: DEPLOYMENT_ID },
    request_sha256: { S: requestSHA256 },
    command_id: { S: "command-v2-deployment-001" },
    bootstrap_session_id: { S: BOOTSTRAP_SESSION_ID },
    reservation_state: { S: "accepted" },
    reserved_at: { S: "2026-07-14T07:00:00.000Z" },
  };
}

class ScriptedDynamo {
  constructor({ quote = quoteItem(), deployment = undefined, updateError = undefined } = {}) {
    this.quote = quote;
    this.deployment = deployment;
    this.updateError = updateError;
    this.gets = [];
    this.updates = [];
  }

  async send(command) {
    if (command instanceof GetItemCommand) {
      this.gets.push(command.input);
      if (command.input.TableName === "issued-quotes") return { Item: this.quote };
      if (command.input.TableName === "deployments") return { Item: this.deployment };
      throw new Error("unexpected table");
    }
    if (command instanceof UpdateItemCommand) {
      this.updates.push(command.input);
      if (this.updateError) throw this.updateError;
      const values = command.input.ExpressionAttributeValues;
      const promoted = {
        ...this.deployment,
        ...command.input.Key,
        request_sha256: values[":request_sha256"],
        resource_status: values[":resource_status"],
        instance_id: values[":instance_id"],
        receipt_json: values[":receipt_json"],
        recorded_at: values[":recorded_at"],
      };
      delete promoted.reservation_state;
      delete promoted.command_id;
      delete promoted.reserved_at;
      this.deployment = promoted;
      return {};
    }
    throw new Error("unexpected command");
  }
}

function store(client) {
  return new DynamoDeploymentStore({
    client,
    issuedQuotesTableName: "issued-quotes",
    deploymentReceiptsTableName: "deployments",
    GetItemCommand,
    UpdateItemCommand,
    nowMs: () => NOW,
  });
}

const quoteClient = new ScriptedDynamo();
const durableQuote = await store(quoteClient).getQuote({ connection_id: CONNECTION_ID, quote_id: QUOTE_ID });
assert.equal(durableQuote.quote_id, QUOTE_ID);
assert.match(durableQuote.quote_digest, /^sha256:[0-9a-f]{64}$/);
assert.equal(quoteClient.gets[0].ConsistentRead, true);
for (const field of ["user_data", "worker_token", "secret_ref"]) assert.equal(Object.hasOwn(durableQuote, field), false);

const reservationClient = new ScriptedDynamo({ deployment: reservedDeploymentItem() });
assert.equal(
  await store(reservationClient).getDeployment({ connection_id: CONNECTION_ID, deployment_id: DEPLOYMENT_ID }),
  undefined,
  "a same-request reservation must not masquerade as a completed EC2 receipt before the provisioner runs",
);
assert.equal(reservationClient.gets.at(-1).ConsistentRead, true);
assert.deepEqual(
  await store(reservationClient).getDeploymentBootstrap({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: REQUEST_SHA256,
  }),
  {
    bootstrap_session_id: BOOTSTRAP_SESSION_ID,
    request_sha256: REQUEST_SHA256,
  },
  "the provisioner must be able to recover the durable bootstrap session id before EC2 is created",
);
await assert.rejects(
  () => store(reservationClient).getDeployment({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: "d".repeat(64),
  }),
  (error) => error?.code === "deployment_id_conflict",
  "a different request must not pass through an existing deployment reservation before EC2 provisioning",
);

const createClient = new ScriptedDynamo({ deployment: reservedDeploymentItem() });
const persisted = await store(createClient).putDeployment(receipt());
assert.deepEqual(persisted, receipt());
assert.equal(createClient.updates.length, 1);
const write = createClient.updates[0];
assert.equal(write.TableName, "deployments");
assert.equal(write.ConditionExpression, "request_sha256 = :request_sha256 AND reservation_state = :reservation_state AND attribute_exists(bootstrap_session_id)");
assert.match(write.UpdateExpression, /REMOVE reservation_state, command_id, reserved_at$/);
assert.doesNotMatch(write.UpdateExpression, /bootstrap_session_id/, "promotion must retain the durable bootstrap session id");
assert.equal(write.ExpressionAttributeValues[":reservation_state"].S, "accepted");
assert.equal(write.ExpressionAttributeValues[":receipt_json"].S, JSON.stringify(receipt()));
assert.equal(createClient.deployment.bootstrap_session_id.S, BOOTSTRAP_SESSION_ID, "Dynamo promotion must retain the bootstrap session id beside the immutable receipt");
assert.deepEqual(
  await store(createClient).getDeploymentBootstrap({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: REQUEST_SHA256,
  }),
  {
    bootstrap_session_id: BOOTSTRAP_SESSION_ID,
    request_sha256: REQUEST_SHA256,
  },
  "recovery after receipt promotion must observe the original bootstrap session id",
);
for (const field of ["user_data", "worker_token", "secret_ref"]) assert.equal(Object.hasOwn(write.ExpressionAttributeValues, `:${field}`), false);

const conditional = new Error("existing");
conditional.name = "ConditionalCheckFailedException";
const replayClient = new ScriptedDynamo({ deployment: deploymentItem(), updateError: conditional });
assert.deepEqual(await store(replayClient).putDeployment(receipt()), receipt(), "conditional replay must resolve to the immutable same-request receipt");

const conflictClient = new ScriptedDynamo({ deployment: deploymentItem(receipt("d".repeat(64))), updateError: conditional });
await assert.rejects(
  () => store(conflictClient).putDeployment(receipt()),
  (error) => error?.code === "deployment_id_conflict",
);

const reservationConflictClient = new ScriptedDynamo({
  deployment: reservedDeploymentItem("d".repeat(64)),
  updateError: conditional,
});
await assert.rejects(
  () => store(reservationConflictClient).putDeployment(receipt()),
  (error) => error?.code === "deployment_id_conflict",
  "a final receipt must not overwrite another request's accepted deployment reservation",
);

const missingReservationClient = new ScriptedDynamo({ updateError: conditional });
await assert.rejects(
  () => store(missingReservationClient).putDeployment(receipt()),
  (error) => error?.code === "deployment_store_unavailable",
  "a deployment receipt must fail closed when no accepted reservation exists",
);

const legacyReceiptClient = new ScriptedDynamo({ deployment: deploymentItem() });
assert.deepEqual(
  await store(legacyReceiptClient).getDeployment({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: REQUEST_SHA256,
  }),
  receipt(),
  "completed deployments that predate Worker sessions remain readable",
);
await assert.rejects(
  () => store(legacyReceiptClient).getDeploymentBootstrap({
    connection_id: CONNECTION_ID,
    deployment_id: DEPLOYMENT_ID,
    request_sha256: REQUEST_SHA256,
  }),
  (error) => error?.code === "deployment_bootstrap_unavailable",
  "a historical receipt without a durable session id cannot become a Worker bootstrap source",
);

console.log("connection stack v2 Dynamo deployment store boundary ok");
