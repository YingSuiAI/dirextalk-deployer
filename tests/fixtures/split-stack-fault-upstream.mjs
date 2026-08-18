import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [role, portText, readyFile, disconnectFile = ""] = process.argv.slice(2);
const port = Number.parseInt(portText, 10);
if (!["message", "agent"].includes(role) || !Number.isInteger(port) || port < 1 || !readyFile) {
  throw new Error("usage: split-stack-fault-upstream.mjs <message|agent> <port> <ready-file> [disconnect-file]");
}

const server = createServer((request, response) => {
  if (role === "message") {
    if (request.url === "/_p2p/health") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"status":"ok"}\n');
      return;
    }
    if (request.url?.startsWith("/_matrix/client/v3/sync")) {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"next_batch":"fault-gate","rooms":{"join":{}}}\n');
      return;
    }
    response.writeHead(404).end();
    return;
  }

  if (request.headers.authorization !== "Bearer fault-gate-ticket") {
    response.writeHead(401, { "content-type": "application/json" });
    response.end('{"error":"missing forwarded authorization"}\n');
    return;
  }
  if (request.url === "/agent/v1/status") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end('{"status":"ok"}\n');
    return;
  }
  if (request.url !== "/agent/v1/events") {
    response.writeHead(404).end();
    return;
  }

  response.writeHead(200, {
    "cache-control": "no-cache",
    "content-type": "text/event-stream",
  });
  response.write("event: progress\ndata: first\n\n");
  const delayed = setTimeout(() => {
    response.write("event: progress\ndata: delayed\n\n");
  }, 2000);
  request.once("close", () => {
    clearTimeout(delayed);
    if (disconnectFile) appendFileSync(disconnectFile, "closed\n");
  });
});

server.listen(port, "127.0.0.1", () => writeFileSync(readyFile, `${process.pid}\n`));
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
