#!/usr/bin/env node
import { chmodSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { randomBytes } from "node:crypto";
import path from "node:path";

import { executeJsonCommand } from "../json.mjs";

const metadataFile = process.argv[2];
if (!metadataFile) {
  console.error("usage: json-worker.mjs <metadata-file>");
  process.exit(2);
}

const token = randomBytes(32).toString("hex");
const sockets = new Set();
const server = createServer((socket) => {
  sockets.add(socket);
  let pending = Buffer.alloc(0);
  const fields = [];

  socket.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    let separator;
    while ((separator = pending.indexOf(0)) !== -1) {
      fields.push(pending.subarray(0, separator).toString("utf8"));
      pending = pending.subarray(separator + 1);
      if (fields.length < 4) continue;

      const argumentCount = Number(fields[3]);
      if (!Number.isSafeInteger(argumentCount) || argumentCount < 1) {
        respond(socket, { status: 2, stdout: "", stderr: "invalid JSON worker request\n" });
        socket.end();
        return;
      }
      if (fields.length < 4 + argumentCount) continue;
      const request = fields.splice(0, 4 + argumentCount);
      if (request[0] !== token) {
        respond(socket, { status: 77, stdout: "", stderr: "JSON worker authentication failed\n" });
        socket.end();
        return;
      }
      const [command, ...rawArgs] = request.slice(4);
      const args = normalizeFileArguments(command, rawArgs, request[2]);
      respond(socket, executeJsonCommand(command, args, { stdin: request[1] }));
    }
  });

  socket.on("error", () => {});
  socket.on("close", () => sockets.delete(socket));
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") {
    console.error("JSON worker did not receive a TCP port");
    process.exit(1);
  }
  writeFileSync(metadataFile, `${address.port} ${token}\n`, { encoding: "utf8", mode: 0o600 });
  chmodSync(metadataFile, 0o600);
});

server.on("error", (error) => {
  console.error(error.message);
  process.exit(1);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    for (const socket of sockets) socket.destroy();
    server.close(() => process.exit(0));
  });
}

function respond(socket, result) {
  socket.write(`${result.status}\0${result.stdout}\0${result.stderr}\0`);
}

function normalizeFileArguments(command, rawArgs, cwd) {
  const args = [...rawArgs];
  if (["get", "assert", "check", "entries", "length", "type", "mutate", "valid", "lightsail-availability-zone", "lightsail-bundle-select"].includes(command)) {
    if (args.length > 0) args[0] = nativePath(args[0], cwd);
  } else if (command === "operation-report") {
    if (args.length >= 3) args[2] = nativePath(args[2], cwd);
  } else if (command === "build" && args[0] === "bootstrap-normalized") {
    if (args.length >= 2) args[1] = nativePath(args[1], cwd);
  }
  return args;
}

function nativePath(value, cwd) {
  const input = String(value || "");
  const converted = absoluteNativePath(input);
  if (converted !== input || path.isAbsolute(converted) || /^[a-zA-Z]:[\\/]/.test(converted)) return converted;
  return path.resolve(absoluteNativePath(cwd), converted);
}

function absoluteNativePath(input) {
  const posixRoot = process.env.DIREXTALK_JSON_WORKER_POSIX_ROOT || "";
  const nativeRoot = process.env.DIREXTALK_JSON_WORKER_NATIVE_ROOT || "";
  if (posixRoot && nativeRoot && (input === posixRoot || input.startsWith(`${posixRoot}/`))) {
    return `${nativeRoot}${input.slice(posixRoot.length)}`.replaceAll("\\", "/");
  }
  const drivePath = input.match(/^\/([a-zA-Z])(?:\/(.*))?$/);
  if (drivePath) return `${drivePath[1].toUpperCase()}:/${drivePath[2] || ""}`;
  return input;
}
