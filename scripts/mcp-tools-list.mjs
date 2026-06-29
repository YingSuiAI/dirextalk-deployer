#!/usr/bin/env node
import { spawn } from "node:child_process";

const command = process.argv[2] || "direxio-mcp";
const timeoutMs = Number.parseInt(process.env.DIREXIO_MCP_TOOLS_TIMEOUT_MS || "8000", 10);

const child = spawn(command, {
  env: process.env,
  shell: true,
  stdio: ["pipe", "pipe", "pipe"]
});

let stdout = Buffer.alloc(0);
let stderr = "";
let completed = false;
const responses = new Map();

const timer = setTimeout(() => {
  finishWithError(`timed out waiting for MCP tools/list after ${timeoutMs}ms`);
}, timeoutMs);

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString("utf8");
});

child.stdout.on("data", (chunk) => {
  stdout = Buffer.concat([stdout, chunk]);
  readFrames();
  if (responses.has(2)) {
    const response = responses.get(2);
    const tools = Array.isArray(response?.result?.tools) ? response.result.tools : [];
    const names = tools
      .map((tool) => tool?.name)
      .filter((name) => typeof name === "string" && name.length > 0);
    finish({ tools: names, tool_count: names.length });
  }
});

child.on("error", (error) => {
  finishWithError(error.message);
});

child.on("exit", (code) => {
  if (!completed && code !== 0) {
    finishWithError(`MCP server exited with code ${code}${stderr ? `: ${stderr.trim()}` : ""}`);
  }
});

send({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "direxio-deployer", version: "0.0.0" }
  }
});
send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });

function send(message) {
  const body = JSON.stringify(message);
  child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

function readFrames() {
  while (true) {
    const headerEnd = stdout.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const header = stdout.subarray(0, headerEnd).toString("utf8");
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) {
      finishWithError("MCP response missing Content-Length header");
      return;
    }
    const length = Number.parseInt(match[1], 10);
    const frameStart = headerEnd + 4;
    const frameEnd = frameStart + length;
    if (stdout.length < frameEnd) return;
    const body = stdout.subarray(frameStart, frameEnd).toString("utf8");
    stdout = stdout.subarray(frameEnd);
    const message = JSON.parse(body);
    if (typeof message.id !== "undefined") {
      responses.set(message.id, message);
    }
  }
}

function finish(value) {
  if (completed) return;
  completed = true;
  clearTimeout(timer);
  console.log(JSON.stringify(value));
  child.kill();
}

function finishWithError(message) {
  if (completed) return;
  completed = true;
  clearTimeout(timer);
  console.error(message);
  child.kill();
  process.exitCode = 1;
}
