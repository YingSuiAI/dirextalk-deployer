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

class PutItemCommand {
  constructor(input) { this.input = input; }
}

const NOW = Date.parse("2026-07-14T07:00:00.000Z");
const CONNECTION_ID = "connection-v2-0001";
const QUOTE_ID = `quote-${"b".repeat(32)}`;
const DEPLOYMENT_ID = "deployment-v2-001";
const REQUEST_SHA256 = "a".repeat(64);

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

class ScriptedDynamo {
  constructor({ quote = quoteItem(), deployment = undefined, putError = undefined } = {}) {
    this.quote = quote;
    this.deployment = deployment;
    this.putError = putError;
    this.gets = [];
    this.puts = [];
  }

  async send(command) {
    if (command instanceof GetItemCommand) {
      this.gets.push(command.input);
      if (command.input.TableName === "issued-quotes") return { Item: this.quote };
      if (command.input.TableName === "deployments") return { Item: this.deployment };
      throw new Error("unexpected table");
    }
    if (command instanceof PutItemCommand) {
      this.puts.push(command.input);
      if (this.putError) throw this.putError;
      this.deployment = command.input.Item;
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
    PutItemCommand,
    nowMs: () => NOW,
  });
}

const quoteClient = new ScriptedDynamo();
const durableQuote = await store(quoteClient).getQuote({ connection_id: CONNECTION_ID, quote_id: QUOTE_ID });
assert.equal(durableQuote.quote_id, QUOTE_ID);
assert.match(durableQuote.quote_digest, /^sha256:[0-9a-f]{64}$/);
assert.equal(quoteClient.gets[0].ConsistentRead, true);
for (const field of ["user_data", "worker_token", "secret_ref"]) assert.equal(Object.hasOwn(durableQuote, field), false);

const createClient = new ScriptedDynamo();
const persisted = await store(createClient).putDeployment(receipt());
assert.deepEqual(persisted, receipt());
assert.equal(createClient.puts.length, 1);
const write = createClient.puts[0];
assert.equal(write.TableName, "deployments");
assert.equal(write.ConditionExpression, "attribute_not_exists(connection_id) AND attribute_not_exists(deployment_id)");
assert.equal(write.Item.receipt_json.S, JSON.stringify(receipt()));
for (const field of ["user_data", "worker_token", "secret_ref"]) assert.equal(Object.hasOwn(write.Item, field), false);

const conditional = new Error("existing");
conditional.name = "ConditionalCheckFailedException";
const replayClient = new ScriptedDynamo({ deployment: deploymentItem(), putError: conditional });
assert.deepEqual(await store(replayClient).putDeployment(receipt()), receipt(), "conditional replay must resolve to the immutable same-request receipt");

const conflictClient = new ScriptedDynamo({ deployment: deploymentItem(receipt("d".repeat(64))), putError: conditional });
await assert.rejects(
  () => store(conflictClient).putDeployment(receipt()),
  (error) => error?.code === "deployment_id_conflict",
);

console.log("connection stack v2 Dynamo deployment store boundary ok");
