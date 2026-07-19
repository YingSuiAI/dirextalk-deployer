#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  fsyncSync,
  linkSync,
  lstatSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import net from "node:net";
import path from "node:path";

const [mode, lockFile, statusSuffix] = process.argv.slice(2);
if (mode !== "hold" || !lockFile || !/^[0-9A-Za-z.-]{1,96}$/.test(statusSuffix || "")) {
  console.error("usage: agent-aws-import-lock.mjs hold <lock-file> <status-suffix>");
  process.exit(2);
}

const lockDirectory = path.dirname(lockFile);
const statusFile = `${lockFile}.holder-status.${statusSuffix}`;
const token = randomBytes(24).toString("hex");
let server;
let ownedIdentity;

function sameFile(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.isFile() && right.isFile();
}

function fsyncDirectory() {
  let descriptor;
  try {
    descriptor = openSync(lockDirectory, constants.O_RDONLY);
    fsyncSync(descriptor);
  } catch (error) {
    if (process.platform !== "win32") throw error;
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
  }
}

function stableLockRecord() {
  const before = lstatSync(lockFile);
  if (!before.isFile() || before.isSymbolicLink()) throw new Error("unsafe Agent AWS-control import lock");
  const record = JSON.parse(readFileSync(lockFile, "utf8"));
  const after = lstatSync(lockFile);
  if (!sameFile(before, after)) throw new Error("Agent AWS-control import lock changed during readback");
  if (!Number.isInteger(record.port) || record.port < 1 || record.port > 65535 || !/^[0-9a-f]{48}$/.test(record.token || "")) {
    throw new Error("invalid Agent AWS-control import lock record");
  }
  return { identity: before, record };
}

function writeStatus(status, message = "") {
  const temp = `${statusFile}.tmp.${process.pid}`;
  let descriptor;
  try {
    descriptor = openSync(
      temp,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW || 0),
      0o600,
    );
    writeFileSync(descriptor, `${JSON.stringify({ status, message })}\n`, "utf8");
    chmodSync(temp, 0o600);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temp, statusFile);
    fsyncDirectory();
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
    try {
      unlinkSync(temp);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
}

function probeOwner(record) {
  return new Promise((resolve) => {
    let response = "";
    let complete = false;
    const finish = (active) => {
      if (complete) return;
      complete = true;
      socket.destroy();
      resolve(active);
    };
    const socket = net.createConnection({ host: "127.0.0.1", port: record.port });
    socket.setEncoding("utf8");
    socket.setTimeout(750);
    socket.on("data", (chunk) => {
      response += chunk;
      if (response.length >= record.token.length) finish(response === record.token);
    });
    socket.on("end", () => finish(response === record.token));
    socket.on("timeout", () => finish(false));
    socket.on("error", () => finish(false));
  });
}

function unlinkIfSame(identity) {
  let current;
  try {
    current = lstatSync(lockFile);
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
  if (!sameFile(identity, current)) return false;
  unlinkSync(lockFile);
  fsyncDirectory();
  return true;
}

async function acquire() {
  server = net.createServer((socket) => socket.end(token));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const candidate = `${lockFile}.candidate.${process.pid}.${token}`;
  let descriptor;
  try {
    descriptor = openSync(
      candidate,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW || 0),
      0o600,
    );
    writeFileSync(descriptor, `${JSON.stringify({ port: address.port, token })}\n`, "utf8");
    chmodSync(candidate, 0o600);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    fsyncDirectory();

    for (;;) {
      try {
        linkSync(candidate, lockFile);
        ownedIdentity = lstatSync(lockFile);
        fsyncDirectory();
        return;
      } catch (error) {
        if (error?.code !== "EEXIST") throw error;
      }

      let existing;
      try {
        existing = stableLockRecord();
      } catch (error) {
        let identity;
        try {
          identity = lstatSync(lockFile);
        } catch (readError) {
          if (readError?.code === "ENOENT") continue;
          throw readError;
        }
        if (!identity.isFile() || identity.isSymbolicLink()) throw error;
        unlinkIfSame(identity);
        continue;
      }
      if (await probeOwner(existing.record)) {
        throw new Error("another Agent AWS-control import is already running for this service");
      }
      unlinkIfSame(existing.identity);
    }
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
    try {
      unlinkSync(candidate);
      fsyncDirectory();
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
}

function release() {
  if (ownedIdentity) {
    try {
      const current = stableLockRecord();
      if (sameFile(ownedIdentity, current.identity) && current.record.token === token) {
        unlinkSync(lockFile);
        fsyncDirectory();
      }
    } catch (error) {
      if (error?.code !== "ENOENT") console.error(`failed to release Agent AWS-control import lock: ${error.message}`);
    }
  }
  if (server) server.close();
}

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    release();
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
  });
}

try {
  await acquire();
  writeStatus("acquired");
} catch (error) {
  if (server) server.close();
  writeStatus("failed", error.message);
  process.exit(73);
}

process.stdin.resume();
await new Promise((resolve) => {
  process.stdin.once("end", resolve);
  process.stdin.once("close", resolve);
  process.stdin.once("error", resolve);
});
release();
