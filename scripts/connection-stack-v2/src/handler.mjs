import { COMMAND_V2_SCHEMA } from "./command-contract.mjs";

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

function parseBody(event) {
  if (typeof event?.body !== "string") return undefined;
  const body = event.isBase64Encoded ? Buffer.from(event.body, "base64") : Buffer.from(event.body, "utf8");
  if (body.length > 256 * 1024) return undefined;
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    return undefined;
  }
}

// This contract-only handler deliberately has no AWS SDK client, database access,
// mutation permission, or worker bootstrap path. It must stay fail-closed until
// the receipt/challenge executor and its tests are separately approved.
export async function handler(event) {
  const command = parseBody(event);
  if (!command || command.schema !== COMMAND_V2_SCHEMA) {
    return response(400, {
      error: {
        code: "invalid_command_schema",
        message: "only dirextalk.aws.command/v2 envelopes are accepted",
      },
    });
  }
  return response(503, {
    error: {
      code: "connection_stack_v2_not_activated",
      message: "Connection Stack V2 is contract-only and cannot execute cloud actions",
    },
  });
}
