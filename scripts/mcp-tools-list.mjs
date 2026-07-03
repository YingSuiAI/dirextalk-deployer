#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const command = process.argv[2] || "dirextalk-mcp";
const timeoutMs = Number.parseInt(process.env.DIREXTALK_MCP_TOOLS_TIMEOUT_MS || "8000", 10);

const timer = setTimeout(() => {
  finishWithError(`timed out waiting for MCP tools/list after ${timeoutMs}ms`);
}, timeoutMs);

try {
  const packageRoot = resolveDirextalkMcpPackageRoot(command);
  const sdkRoot = path.join(packageRoot, "node_modules", "@modelcontextprotocol", "sdk", "dist", "esm");
  const { Client } = await import(pathToFileURL(path.join(sdkRoot, "client", "index.js")).href);
  const { StdioClientTransport } = await import(pathToFileURL(path.join(sdkRoot, "client", "stdio.js")).href);

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.join(packageRoot, "dist", "index.js")],
    env: process.env
  });
  const client = new Client({ name: "dirextalk-deployer", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  const response = await client.listTools();
  await client.close();

  const names = (Array.isArray(response?.tools) ? response.tools : [])
    .map((tool) => tool?.name)
    .filter((name) => typeof name === "string" && name.length > 0);
  finish({ tools: names, tool_count: names.length });
} catch (error) {
  finishWithError(error instanceof Error ? error.message : String(error));
}

function resolveDirextalkMcpPackageRoot(commandName) {
  const executable = resolveExecutable(commandName);
  const basedir = path.dirname(realpathSync(executable));
  const candidates = [
    path.join(basedir, "node_modules", "dirextalk-mcp"),
    path.join(basedir, "..", "node_modules", "dirextalk-mcp"),
    path.join(basedir, "..")
  ];
  for (const candidate of candidates) {
    if (existsSync(path.join(candidate, "package.json")) && existsSync(path.join(candidate, "dist", "index.js"))) {
      return realpathSync(candidate);
    }
  }
  throw new Error(`unable to locate dirextalk-mcp package root from ${executable}`);
}

function resolveExecutable(commandName) {
  const nativeCommand = nativePath(commandName);
  if (path.isAbsolute(nativeCommand) && existsSync(nativeCommand)) {
    return nativeCommand;
  }
  const lookup = process.platform === "win32"
    ? spawnSync("where.exe", [nativeCommand], { encoding: "utf8" })
    : spawnSync("sh", ["-lc", `command -v ${shellQuote(nativeCommand)}`], { encoding: "utf8" });
  if (lookup.status !== 0 || !lookup.stdout.trim()) {
    throw new Error(`unable to find ${commandName} on PATH`);
  }
  return lookup.stdout.trim().split(/\r?\n/)[0];
}

function nativePath(value) {
  if (process.platform !== "win32" || !String(value).startsWith("/")) {
    return value;
  }
  const converted = spawnSync("cygpath", ["-w", value], { encoding: "utf8" });
  if (converted.status === 0 && converted.stdout.trim()) {
    return converted.stdout.trim();
  }
  return value;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function finish(value) {
  clearTimeout(timer);
  console.log(JSON.stringify(value));
}

function finishWithError(message) {
  clearTimeout(timer);
  console.error(message);
  process.exitCode = 1;
}
