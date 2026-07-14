import {
  randomUUID,
} from "node:crypto";

import {
  ConnectionStackV2Error,
  createV2ChallengeApprovalService,
} from "./command-contract.mjs";
import {
  DynamoV2ReceiptStore,
} from "./dynamo-receipt-store.mjs";
import {
  AwsOnDemandQuoteProvider,
} from "./quote-provider.mjs";
import {
  validateConnectionRegistrationConfig,
} from "./registration-contract.mjs";

function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
    body: `${JSON.stringify(body)}\n`,
  };
}

function errorResponse(error) {
  if (error instanceof ConnectionStackV2Error) {
    return response(error.statusCode, { error: { code: error.code } });
  }
  return response(500, { error: { code: "connection_stack_unavailable" } });
}

function parseBody(event) {
  if (typeof event?.body !== "string") {
    throw new ConnectionStackV2Error("invalid_request", "JSON request body is required", 400);
  }
  let body;
  try {
    body = event.isBase64Encoded ? Buffer.from(event.body, "base64") : Buffer.from(event.body, "utf8");
  } catch {
    throw new ConnectionStackV2Error("invalid_request", "JSON request body is invalid", 400);
  }
  if (body.length > 256 * 1024) {
    throw new ConnectionStackV2Error("request_too_large", "request body is too large", 413);
  }
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    throw new ConnectionStackV2Error("invalid_request", "request body must be JSON", 400);
  }
}

function resultStatusCode(status) {
  if (status === "challenge_issued") return 201;
  if (status === "quote_issued") return 200;
  if (status === "connection_registered") return 200;
  if (status === "idempotent") return 200;
  if (status === "read_only_validated" || status === "approval_consumed") return 202;
  throw new ConnectionStackV2Error("receipt_store_invalid", "receipt store returned an invalid result", 500);
}

function publicResult(result) {
  if (!result || typeof result !== "object" || typeof result.status !== "string" || !result.receipt) {
    throw new ConnectionStackV2Error("receipt_store_invalid", "receipt store returned an invalid result", 500);
  }
  const receipt = result.registration
    ? Object.fromEntries(Object.entries(result.receipt).filter(([key]) => key !== "registration"))
    : result.receipt;
  return {
    status: result.status,
    receipt,
    ...(result.challenge ? { challenge: result.challenge } : {}),
    ...(result.quote ? { quote: result.quote } : {}),
    ...(result.registration ? { registration: result.registration } : {}),
  };
}

function registrationRuntimeContext(event, registrationConfig) {
  const configured = validateConnectionRegistrationConfig(registrationConfig);
  const domainName = event?.requestContext?.domainName;
  const stage = event?.requestContext?.stage;
  if (typeof domainName !== "string" || typeof stage !== "string") return undefined;
  const expectedSuffix = `.execute-api.${configured.region}.${configured.api_gateway_url_suffix}`;
  const apiId = domainName.endsWith(expectedSuffix)
    ? domainName.slice(0, -expectedSuffix.length)
    : "";
  if (!/^[a-z0-9]{10}$/.test(apiId) || stage !== configured.stage_name) {
    throw new ConnectionStackV2Error("registration_config_invalid", "Broker API event does not match this stack", 500);
  }
  return {
    broker_command_url: `https://${domainName}/${stage}/v2/commands`,
  };
}

// createV2BrokerHandler is exported for in-process boundary tests. It exposes
// only the durable receipt/challenge projection: no signed command payload,
// approval blob, or internal runtime error is returned to the caller.
export function createV2BrokerHandler(service, { registrationConfig } = {}) {
  if (!service || typeof service.accept !== "function") {
    throw new TypeError("a V2 broker acceptance service is required");
  }
  return async function brokerHandler(event) {
    try {
      const result = await service.accept(
        parseBody(event),
        registrationConfig ? registrationRuntimeContext(event, registrationConfig) : undefined,
      );
      return response(resultStatusCode(result.status), publicResult(result));
    } catch (error) {
      return errorResponse(error);
    }
  };
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function positiveGeneration(value) {
  const generation = Number(value);
  if (!Number.isSafeInteger(generation) || generation < 1) {
    throw new Error("CONNECTION_GENERATION must be a positive integer");
  }
  return generation;
}

function registrationConfigFromEnvironment() {
  return {
    account_id: requiredEnvironment("STACK_ACCOUNT_ID"),
    region: requiredEnvironment("STACK_REGION"),
    stack_arn: requiredEnvironment("STACK_ARN"),
    api_gateway_url_suffix: requiredEnvironment("AWS_URL_SUFFIX"),
    stage_name: requiredEnvironment("BROKER_STAGE_NAME"),
  };
}

let productionHandlerPromise;

async function productionHandler() {
  if (!productionHandlerPromise) {
    productionHandlerPromise = (async () => {
      const {
        DynamoDBClient,
        GetItemCommand,
        TransactWriteItemsCommand,
      } = await import("@aws-sdk/client-dynamodb");
      const {
        EC2Client,
        DescribeInstanceTypeOfferingsCommand,
        DescribeInstanceTypesCommand,
      } = await import("@aws-sdk/client-ec2");
      const {
        PricingClient,
        GetProductsCommand,
      } = await import("@aws-sdk/client-pricing");
      const dynamodb = new DynamoDBClient({});
      const quoteProvider = new AwsOnDemandQuoteProvider({
        pricingClient: new PricingClient({ region: "us-east-1" }),
        ec2Client: new EC2Client({}),
        GetProductsCommand,
        DescribeInstanceTypeOfferingsCommand,
        DescribeInstanceTypesCommand,
      });
      const receiptStore = new DynamoV2ReceiptStore({
        client: dynamodb,
        receiptsTableName: requiredEnvironment("COMMAND_RECEIPTS_TABLE"),
        challengesTableName: requiredEnvironment("APPROVAL_CHALLENGES_TABLE"),
        countersTableName: requiredEnvironment("CONNECTION_COUNTERS_TABLE"),
        GetItemCommand,
        TransactWriteItemsCommand,
      });
      const registrationConfig = registrationConfigFromEnvironment();
      const service = createV2ChallengeApprovalService({
        clock: Date.now,
        createChallengeId: () => `challenge-${randomUUID()}`,
        receiptStore,
        quoteProvider,
        connectionId: requiredEnvironment("CONNECTION_ID"),
        connectionGeneration: positiveGeneration(requiredEnvironment("CONNECTION_GENERATION")),
        nodeKeyId: requiredEnvironment("NODE_KEY_ID"),
        nodePublicKeySpkiBase64: requiredEnvironment("NODE_PUBLIC_KEY_SPKI_B64"),
        deviceKeyId: requiredEnvironment("DEVICE_APPROVAL_KEY_ID"),
        devicePublicKeySpkiBase64: requiredEnvironment("DEVICE_APPROVAL_PUBLIC_KEY_SPKI_B64"),
        registration: registrationConfig,
      });
      return createV2BrokerHandler(service, {
        registrationConfig,
      });
    })();
  }
  return productionHandlerPromise;
}

// handler is the production Lambda entry point. This stage activates only the
// signed DynamoDB receipt/challenge fence plus read-only AWS on-demand quote
// lookup. It has no EC2/EBS/IAM/S3 mutation, Worker, secret-read, or generic
// AWS API capability.
export async function handler(event) {
  try {
    return await (await productionHandler())(event);
  } catch (error) {
    return errorResponse(error);
  }
}
