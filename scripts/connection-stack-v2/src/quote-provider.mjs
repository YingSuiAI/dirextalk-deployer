import {
  ConnectionStackV2Error,
} from "./errors.mjs";
import {
  QUOTE_INCLUDED_ITEMS,
  QUOTE_UNINCLUDED_ITEMS,
  quoteIDForRequest,
  validateIssuedQuote,
  validateQuoteRequestPayload,
} from "./quote-contract.mjs";

const HOURS_PER_THIRTY_DAYS = 24 * 30;

function fail(code, message, statusCode = 409) {
  throw new ConnectionStackV2Error(code, message, statusCode);
}

function priceFilters(region, instanceType) {
  return [
    { Type: "TERM_MATCH", Field: "productFamily", Value: "Compute Instance" },
    { Type: "TERM_MATCH", Field: "regionCode", Value: region },
    { Type: "TERM_MATCH", Field: "instanceType", Value: instanceType },
    { Type: "TERM_MATCH", Field: "tenancy", Value: "Shared" },
    { Type: "TERM_MATCH", Field: "operatingSystem", Value: "Linux" },
    { Type: "TERM_MATCH", Field: "preInstalledSw", Value: "NA" },
    { Type: "TERM_MATCH", Field: "capacitystatus", Value: "Used" },
  ];
}

function decimalMinorCeiling(value, multiplier) {
  if (typeof value !== "string" || !/^\d+(?:\.\d+)?$/.test(value)) {
    fail("quote_price_invalid", "AWS returned an invalid on-demand price", 502);
  }
  const [whole, fraction = ""] = value.split(".");
  const denominator = 10n ** BigInt(fraction.length);
  const numerator = BigInt(whole) * denominator + BigInt(fraction || "0");
  const scaled = numerator * BigInt(multiplier);
  const rounded = (scaled + denominator - 1n) / denominator;
  if (rounded > BigInt(Number.MAX_SAFE_INTEGER)) {
    fail("quote_price_invalid", "AWS returned an unsupported on-demand price", 502);
  }
  return Number(rounded);
}

function onDemandUSD(productTexts) {
  if (!Array.isArray(productTexts) || productTexts.length === 0) {
    fail("quote_price_ambiguous", "AWS returned an ambiguous on-demand price", 502);
  }
  const prices = new Set();
  for (const productText of productTexts) {
    let product;
    try {
      product = JSON.parse(productText);
    } catch {
      fail("quote_price_invalid", "AWS returned an unreadable on-demand price", 502);
    }
    for (const term of Object.values(product?.terms?.OnDemand ?? {})) {
      for (const dimension of Object.values(term?.priceDimensions ?? {})) {
        if (dimension?.unit === "Hrs" && dimension?.beginRange === "0" && dimension?.endRange === "Inf") {
          const usd = dimension?.pricePerUnit?.USD;
          if (typeof usd === "string" && /^\d+(?:\.\d+)?$/.test(usd)) prices.add(usd);
        }
      }
    }
  }
  if (prices.size !== 1) {
    fail("quote_price_ambiguous", "AWS returned an ambiguous on-demand price", 502);
  }
  return [...prices][0];
}

function availabilityByInstance(output, candidates) {
  const result = new Map(candidates.map((candidate) => [candidate.instance_type, new Set()]));
  for (const offering of output?.InstanceTypeOfferings ?? []) {
    if (typeof offering?.InstanceType === "string" && typeof offering?.Location === "string") {
      result.get(offering.InstanceType)?.add(offering.Location);
    }
  }
  for (const [instanceType, zones] of result) {
    if (zones.size === 0) {
      fail("instance_type_unavailable", `AWS reported no availability zone for ${instanceType}`);
    }
  }
  return result;
}

function normalizedProviderRequest(request) {
  if (!request || typeof request !== "object") {
    fail("quote_provider_invalid_request", "quote provider request is invalid", 500);
  }
  const quoteRequest = validateQuoteRequestPayload(request.quote_request);
  for (const field of ["connection_id", "command_id", "request_sha256"]) {
    if (typeof request[field] !== "string") {
      fail("quote_provider_invalid_request", "quote provider request is invalid", 500);
    }
  }
  if (!Number.isSafeInteger(request.now_ms) || request.now_ms < 0) {
    fail("quote_provider_invalid_request", "quote provider request is invalid", 500);
  }
  return { ...request, quote_request: quoteRequest };
}

// AwsOnDemandQuoteProvider has only two read-only provider clients. It cannot
// create, change, or destroy resources. Its result explicitly excludes costs
// that this stage cannot price accurately enough for an approval surface.
export class AwsOnDemandQuoteProvider {
  constructor({ pricingClient, ec2Client, GetProductsCommand, DescribeInstanceTypeOfferingsCommand }) {
    if (!pricingClient?.send || !ec2Client?.send || !GetProductsCommand || !DescribeInstanceTypeOfferingsCommand) {
      throw new TypeError("read-only Pricing and EC2 clients are required");
    }
    this.pricingClient = pricingClient;
    this.ec2Client = ec2Client;
    this.GetProductsCommand = GetProductsCommand;
    this.DescribeInstanceTypeOfferingsCommand = DescribeInstanceTypeOfferingsCommand;
  }

  async quote(input) {
    const request = normalizedProviderRequest(input);
    let offerings;
    try {
      offerings = await this.ec2Client.send(new this.DescribeInstanceTypeOfferingsCommand({
        LocationType: "availability-zone",
        Filters: [{ Name: "instance-type", Values: request.quote_request.candidates.map((candidate) => candidate.instance_type) }],
        MaxResults: 100,
      }));
    } catch (error) {
      if (error instanceof ConnectionStackV2Error) throw error;
      fail("quote_provider_unavailable", "AWS instance offering lookup is unavailable", 503);
    }
    const zones = availabilityByInstance(offerings, request.quote_request.candidates);
    const candidates = [];
    for (const candidate of request.quote_request.candidates) {
      let result;
      try {
        result = await this.pricingClient.send(new this.GetProductsCommand({
          ServiceCode: "AmazonEC2",
          FormatVersion: "aws_v1",
          MaxResults: 100,
          Filters: priceFilters(request.quote_request.region, candidate.instance_type),
        }));
      } catch (error) {
        if (error instanceof ConnectionStackV2Error) throw error;
        fail("quote_provider_unavailable", "AWS Price List lookup is unavailable", 503);
      }
      if (result?.NextToken || !Array.isArray(result?.PriceList) || result.PriceList.length === 0) {
        fail("quote_price_ambiguous", "AWS returned an ambiguous on-demand price", 502);
      }
      const hourlyUSD = onDemandUSD(result.PriceList);
      candidates.push({
        ...candidate,
        hourly_minor: decimalMinorCeiling(hourlyUSD, 100),
        thirty_day_minor: decimalMinorCeiling(hourlyUSD, 100 * HOURS_PER_THIRTY_DAYS),
        // This is zero only because this stage models no one-off cost. The
        // explicitly listed exclusions are never represented as a hard cap.
        startup_upper_minor: 0,
        availability_zones: [...zones.get(candidate.instance_type)].sort(),
      });
    }
    const quotedAt = new Date(request.now_ms).toISOString();
    const quote = {
      schema: "dirextalk.aws.quote/v1",
      quote_id: quoteIDForRequest(request),
      connection_id: request.connection_id,
      command_id: request.command_id,
      request_sha256: request.request_sha256,
      quote_request_id: request.quote_request.quote_request_id,
      plan_digest: request.quote_request.plan_digest,
      region: request.quote_request.region,
      currency: "USD",
      quoted_at: quotedAt,
      valid_until: new Date(request.now_ms + 15 * 60 * 1000).toISOString(),
      candidates,
      included_items: [...QUOTE_INCLUDED_ITEMS],
      unincluded_items: [...QUOTE_UNINCLUDED_ITEMS],
    };
    return validateIssuedQuote(quote, request);
  }
}
