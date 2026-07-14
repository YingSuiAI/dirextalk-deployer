import assert from "node:assert/strict";

import {
  AwsOnDemandQuoteProvider,
} from "../scripts/connection-stack-v2/src/quote-provider.mjs";

class GetProductsCommand {
  constructor(input) {
    this.input = input;
  }
}

class DescribeInstanceTypeOfferingsCommand {
  constructor(input) {
    this.input = input;
  }
}

class DescribeInstanceTypesCommand {
  constructor(input) {
    this.input = input;
  }
}

class ScriptedClient {
  constructor(handler) {
    this.handler = handler;
    this.calls = [];
  }

  async send(command) {
    this.calls.push(command);
    return this.handler(command);
  }
}

const NOW = Date.parse("2026-07-14T07:00:00.000Z");
const REQUEST = {
  connection_id: "connection-v2-0001",
  command_id: "command-v2-quote-001",
  request_sha256: "a".repeat(64),
  now_ms: NOW,
  quote_request: {
    quote_request_id: "quote-request-v2-001",
    plan_digest: `sha256:${"b".repeat(64)}`,
    region: "ap-south-1",
    candidates: [
      {
        candidate_id: "candidate-economy-01",
        tier: "economy",
        instance_type: "t3.large",
        purchase_option: "on_demand",
        estimated_disk_gib: 40,
      },
      {
        candidate_id: "candidate-recommended-01",
        tier: "recommended",
        instance_type: "g5.xlarge",
        purchase_option: "on_demand",
        estimated_disk_gib: 80,
      },
    ],
  },
};

function priceDocument(usd) {
  return JSON.stringify({
    product: { attributes: { internal_test_price_marker: "must-not-leave-provider" } },
    terms: {
      OnDemand: {
        term: {
          priceDimensions: {
            hourly: {
              unit: "Hrs",
              beginRange: "0",
              endRange: "Inf",
              pricePerUnit: { USD: usd },
            },
          },
        },
      },
    },
  });
}

function standardOfferings() {
  return {
    InstanceTypeOfferings: [
      { InstanceType: "t3.large", Location: "ap-south-1a" },
      { InstanceType: "g5.xlarge", Location: "ap-south-1a" },
    ],
  };
}

function standardInstanceTypes({ t3Architectures = ["x86_64"] } = {}) {
  return {
    InstanceTypes: [
      {
        InstanceType: "t3.large",
        ProcessorInfo: { SupportedArchitectures: t3Architectures },
        VCpuInfo: { DefaultVCpus: 2 },
        MemoryInfo: { SizeInMiB: 8192 },
      },
      {
        InstanceType: "g5.xlarge",
        ProcessorInfo: { SupportedArchitectures: ["x86_64"] },
        VCpuInfo: { DefaultVCpus: 4 },
        MemoryInfo: { SizeInMiB: 16384 },
        GpuInfo: {
          Gpus: [{ Count: 1, MemoryInfo: { SizeInMiB: 24576 } }],
          TotalGpuMemoryInMiB: 24576,
        },
      },
    ],
  };
}

function provider({ offerings, instanceTypes = () => { throw new Error("instance type capacity must not be queried"); }, pricing }) {
  const ec2Client = new ScriptedClient((command) => {
    if (command instanceof DescribeInstanceTypeOfferingsCommand) return offerings(command.input);
    if (command instanceof DescribeInstanceTypesCommand) return instanceTypes(command.input);
    throw new Error("unexpected EC2 command");
  });
  const pricingClient = new ScriptedClient((command) => {
    assert.ok(command instanceof GetProductsCommand);
    return pricing(command.input);
  });
  return {
    provider: new AwsOnDemandQuoteProvider({
      ec2Client,
      pricingClient,
      GetProductsCommand,
      DescribeInstanceTypeOfferingsCommand,
      DescribeInstanceTypesCommand,
    }),
    ec2Client,
    pricingClient,
  };
}

const quoted = provider({
  offerings(input) {
    assert.deepEqual(input, {
      LocationType: "availability-zone",
      Filters: [{
        Name: "instance-type",
        Values: ["t3.large", "g5.xlarge"],
      }],
      MaxResults: 100,
    });
    return {
      InstanceTypeOfferings: [
        { InstanceType: "t3.large", Location: "ap-south-1c" },
        { InstanceType: "t3.large", Location: "ap-south-1a" },
        { InstanceType: "t3.large", Location: "ap-south-1a" },
        { InstanceType: "g5.xlarge", Location: "ap-south-1b" },
      ],
    };
  },
  instanceTypes(input) {
    assert.deepEqual(input, {
      InstanceTypes: ["t3.large", "g5.xlarge"],
      MaxResults: 100,
    });
    const result = standardInstanceTypes();
    result.InstanceTypes.reverse();
    return result;
  },
  pricing(input) {
    assert.equal(input.ServiceCode, "AmazonEC2");
    assert.equal(input.FormatVersion, "aws_v1");
    assert.equal(input.MaxResults, 100);
    const instanceType = input.Filters.find((filter) => filter.Field === "instanceType")?.Value;
    assert.deepEqual(input.Filters, [
      { Type: "TERM_MATCH", Field: "productFamily", Value: "Compute Instance" },
      { Type: "TERM_MATCH", Field: "regionCode", Value: "ap-south-1" },
      { Type: "TERM_MATCH", Field: "instanceType", Value: instanceType },
      { Type: "TERM_MATCH", Field: "tenancy", Value: "Shared" },
      { Type: "TERM_MATCH", Field: "operatingSystem", Value: "Linux" },
      { Type: "TERM_MATCH", Field: "preInstalledSw", Value: "NA" },
      { Type: "TERM_MATCH", Field: "capacitystatus", Value: "Used" },
    ]);
    if (instanceType === "t3.large") {
      return { PriceList: [priceDocument("0.0416000000"), priceDocument("0.0416000000")] };
    }
    if (instanceType === "g5.xlarge") {
      return { PriceList: [priceDocument("1.0064000000")] };
    }
    throw new Error("unexpected instance type");
  },
});

const quote = await quoted.provider.quote(REQUEST);
assert.equal(quoted.ec2Client.calls.length, 2);
assert.equal(quoted.pricingClient.calls.length, 2);
assert.deepEqual(quote, {
  schema: "dirextalk.aws.quote/v1",
  quote_id: `quote-${"a".repeat(32)}`,
  connection_id: REQUEST.connection_id,
  command_id: REQUEST.command_id,
  request_sha256: REQUEST.request_sha256,
  quote_request_id: REQUEST.quote_request.quote_request_id,
  plan_digest: REQUEST.quote_request.plan_digest,
  region: "ap-south-1",
  currency: "USD",
  quoted_at: "2026-07-14T07:00:00.000Z",
  valid_until: "2026-07-14T07:15:00.000Z",
  candidates: [
    {
      ...REQUEST.quote_request.candidates[0],
      architecture: "amd64",
      vcpu: 2,
      memory_mib: 8192,
      gpu_count: 0,
      gpu_memory_mib: 0,
      hourly_minor: 5,
      thirty_day_minor: 2996,
      startup_upper_minor: 0,
      availability_zones: ["ap-south-1a", "ap-south-1c"],
    },
    {
      ...REQUEST.quote_request.candidates[1],
      architecture: "amd64",
      vcpu: 4,
      memory_mib: 16384,
      gpu_count: 1,
      gpu_memory_mib: 24576,
      hourly_minor: 101,
      thirty_day_minor: 72461,
      startup_upper_minor: 0,
      availability_zones: ["ap-south-1b"],
    },
  ],
  included_items: ["ec2_linux_ondemand"],
  unincluded_items: ["cloudwatch_logs", "data_transfer", "ebs_gp3", "public_ipv4", "snapshots", "taxes"],
});
assert.doesNotMatch(JSON.stringify(quote), /internal_test_price_marker|must-not-leave-provider/);

const arm64Request = {
  ...REQUEST,
  command_id: "command-v2-quote-arm-001",
  request_sha256: "d".repeat(64),
  quote_request: {
    ...REQUEST.quote_request,
    quote_request_id: "quote-request-v2-arm-01",
    candidates: [{
      candidate_id: "candidate-arm64-01",
      tier: "economy",
      instance_type: "t4g.large",
      purchase_option: "on_demand",
      estimated_disk_gib: 40,
    }],
  },
};
const arm64 = provider({
  offerings: () => ({ InstanceTypeOfferings: [
    { InstanceType: "t4g.large", Location: "ap-south-1a" },
  ] }),
  instanceTypes: () => ({ InstanceTypes: [{
    InstanceType: "t4g.large",
    ProcessorInfo: { SupportedArchitectures: ["arm64"] },
    VCpuInfo: { DefaultVCpus: 2 },
    MemoryInfo: { SizeInMiB: 8192 },
  }] }),
  pricing: () => ({ PriceList: [priceDocument("0.0416000000")] }),
});
const arm64Quote = await arm64.provider.quote(arm64Request);
assert.deepEqual(arm64Quote.candidates[0], {
  ...arm64Request.quote_request.candidates[0],
  architecture: "arm64",
  vcpu: 2,
  memory_mib: 8192,
  gpu_count: 0,
  gpu_memory_mib: 0,
  hourly_minor: 5,
  thirty_day_minor: 2996,
  startup_upper_minor: 0,
  availability_zones: ["ap-south-1a"],
});

const legacyX86Request = {
  ...arm64Request,
  command_id: "command-v2-quote-legacy-x86-001",
  request_sha256: "e".repeat(64),
  quote_request: {
    ...arm64Request.quote_request,
    quote_request_id: "quote-request-v2-legacy-x86-01",
    candidates: [{
      ...arm64Request.quote_request.candidates[0],
      candidate_id: "candidate-legacy-x86-01",
      instance_type: "t2.micro",
    }],
  },
};
const legacyX86 = provider({
  offerings: () => ({ InstanceTypeOfferings: [
    { InstanceType: "t2.micro", Location: "ap-south-1a" },
  ] }),
  instanceTypes: () => ({ InstanceTypes: [{
    InstanceType: "t2.micro",
    ProcessorInfo: { SupportedArchitectures: ["i386", "x86_64"] },
    VCpuInfo: { DefaultVCpus: 1 },
    MemoryInfo: { SizeInMiB: 1024 },
  }] }),
  pricing: () => ({ PriceList: [priceDocument("0.0116000000")] }),
});
const legacyX86Quote = await legacyX86.provider.quote(legacyX86Request);
assert.equal(legacyX86Quote.candidates[0].architecture, "amd64");

const unavailable = provider({
  offerings: () => ({ InstanceTypeOfferings: [] }),
  instanceTypes: () => {
    throw new Error("capacity must not be queried for an unavailable type");
  },
  pricing: () => {
    throw new Error("pricing must not be queried for an unavailable type");
  },
});
await assert.rejects(
  () => unavailable.provider.quote(REQUEST),
  (error) => error?.code === "instance_type_unavailable" && error?.statusCode === 409,
);
assert.equal(unavailable.pricingClient.calls.length, 0);

const ambiguous = provider({
  offerings: standardOfferings,
  instanceTypes: standardInstanceTypes,
  pricing: () => ({ PriceList: [priceDocument("0.0416000000"), priceDocument("0.0512000000")] }),
});
await assert.rejects(
  () => ambiguous.provider.quote(REQUEST),
  (error) => error?.code === "quote_price_ambiguous" && error?.statusCode === 502,
);

const capacityAmbiguous = provider({
  offerings: standardOfferings,
  instanceTypes: () => standardInstanceTypes({ t3Architectures: ["x86_64", "arm64"] }),
  pricing: () => {
    throw new Error("pricing must not be queried when capacity cannot bind one architecture");
  },
});
await assert.rejects(
  () => capacityAmbiguous.provider.quote(REQUEST),
  (error) => error?.code === "instance_type_capacity_invalid" && error?.statusCode === 502,
);
assert.equal(capacityAmbiguous.pricingClient.calls.length, 0);

const spotRequest = structuredClone(REQUEST);
spotRequest.quote_request.candidates[0].purchase_option = "spot";
const spot = provider({
  offerings: () => ({ InstanceTypeOfferings: [] }),
  pricing: () => ({ PriceList: [] }),
});
await assert.rejects(
  () => spot.provider.quote(spotRequest),
  (error) => error?.code === "spot_quote_not_enabled" && error?.statusCode === 409,
);
assert.equal(spot.ec2Client.calls.length, 0, "Spot must fail before any AWS provider lookup");
assert.equal(spot.pricingClient.calls.length, 0, "Spot must fail before any AWS provider lookup");

console.log("connection stack v2 read-only quote provider boundary ok");
