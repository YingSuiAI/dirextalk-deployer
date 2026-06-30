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
  if (completed) return;
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
  child.stdin.write(`Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`);
}

function readFrames() {
  while (true) {
    if (stdout.length === 0) return;
    if (stdout[0] === 10 || stdout[0] === 13) {
      stdout = stdout.subarray(1);
      continue;
    }
    if (startsWithHeader(stdout, "Content-Length:")) {
      const header = readHeader(stdout);
      if (!header) return;
      const contentLength = parseContentLength(header.text);
      if (!Number.isSafeInteger(contentLength) || contentLength < 0) {
        finishWithError("MCP response frame is missing a valid Content-Length header");
        return;
      }
      const messageEnd = header.bodyStart + contentLength;
      if (stdout.length < messageEnd) return;
      const body = stdout.subarray(header.bodyStart, messageEnd).toString("utf8");
      stdout = stdout.subarray(messageEnd);
      handleMessage(body);
      if (completed) return;
      continue;
    }

    const lineEnd = stdout.indexOf("\n");
    if (lineEnd < 0) return;
    const line = stdout.subarray(0, lineEnd).toString("utf8").replace(/\r$/, "");
    stdout = stdout.subarray(lineEnd + 1);
    if (line.length === 0) continue;
    handleMessage(line);
    if (completed) return;
  }
}

function startsWithHeader(buffer, header) {
  return buffer.subarray(0, header.length).toString("utf8").toLowerCase() === header.toLowerCase();
}

function readHeader(buffer) {
  let marker = "\r\n\r\n";
  let headerEnd = buffer.indexOf(marker);
  if (headerEnd < 0) {
    marker = "\n\n";
    headerEnd = buffer.indexOf(marker);
  }
  if (headerEnd < 0) return null;
  return {
    text: buffer.subarray(0, headerEnd).toString("utf8"),
    bodyStart: headerEnd + marker.length
  };
}

function parseContentLength(headerText) {
  for (const line of headerText.split(/\r?\n/)) {
    const match = /^content-length:\s*(\d+)\s*$/i.exec(line);
    if (match) return Number.parseInt(match[1], 10);
  }
  return NaN;
}

function handleMessage(raw) {
  let message;
  try {
    message = JSON.parse(raw);
  } catch (error) {
    finishWithError(`invalid MCP JSON response: ${error.message}`);
    return;
  }
  if (typeof message.id !== "undefined") {
    responses.set(message.id, message);
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
