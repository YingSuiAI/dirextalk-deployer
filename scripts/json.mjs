#!/usr/bin/env node
import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fstatSync,
  fsyncSync,
  linkSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

class JsonCommandExit extends Error {
  constructor(status) {
    super(`JSON command exited with status ${status}`);
    this.status = status;
  }
}

let activeStdin;
let activeStdout = (value) => process.stdout.write(value);
let activeExitCode = 0;

function dispatch(command, args) {
  switch (command) {
    case "get":
      cmdGet(args);
      break;
    case "stdin-get":
      cmdStdinGet(args);
      break;
    case "assert":
      cmdAssert(args);
      break;
    case "stdin-assert":
      cmdStdinAssert(args);
      break;
    case "check":
      cmdCheck(args);
      break;
    case "entries":
      cmdEntries(args);
      break;
    case "stdin-tsv":
      cmdStdinTsv(args);
      break;
    case "stdin-join":
      cmdStdinJoin(args);
      break;
    case "stdin-route53-a-values":
      cmdStdinRoute53AValues(args);
      break;
    case "stdin-route53-a-present":
      cmdStdinRoute53APresent(args);
      break;
    case "stdin-price-usd":
      cmdStdinPriceUsd();
      break;
    case "lightsail-availability-zone":
      cmdLightsailAvailabilityZone(args);
      break;
    case "lightsail-bundle-select":
      cmdLightsailBundleSelect(args);
      break;
    case "length":
      cmdLength(args);
      break;
    case "type":
      cmdType(args);
      break;
    case "build":
      cmdBuild(args);
      break;
    case "mutate":
      cmdMutate(args);
      break;
    case "operation-report":
      cmdOperationReport(args);
      break;
    case "valid":
      readJsonFile(required(args, 0, "file"));
      break;
    case "worker-ami-publication-snapshot":
      cmdWorkerAMIPublicationSnapshot(args);
      break;
    case "deterministic-bundle":
      cmdDeterministicBundle(args);
      break;
    default:
      usage(command ? `unknown command: ${command}` : "missing command");
  }
}

export function executeJsonCommand(command, args = [], { stdin } = {}) {
  let stdout = "";
  const previousStdin = activeStdin;
  const previousStdout = activeStdout;
  const previousExitCode = activeExitCode;
  activeStdin = stdin;
  activeStdout = (value) => { stdout += String(value); };
  activeExitCode = 0;
  try {
    dispatch(command, args);
    return { status: activeExitCode, stdout, stderr: "" };
  } catch (error) {
    if (error instanceof JsonCommandExit) {
      return { status: error.status, stdout, stderr: "" };
    }
    return { status: 1, stdout, stderr: `${error instanceof Error ? error.message : String(error)}\n` };
  } finally {
    activeStdin = previousStdin;
    activeStdout = previousStdout;
    activeExitCode = previousExitCode;
  }
}

function parseCliArgs() {
  let cliArgs = process.argv.slice(2);
  if (cliArgs.length === 1 && cliArgs[0] === "--args0") {
    const input = readFileSync(0);
    cliArgs = input.toString("utf8").split("\0");
    if (cliArgs.at(-1) === "") cliArgs.pop();
  }
  return cliArgs;
}

function cmdGet(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  const fallback = args.length > 2 ? args[2] : "";
  printValue(getPath(readJsonFile(file), jsonPath, fallback));
}

function cmdStdinGet(args) {
  const jsonPath = required(args, 0, "path");
  const fallback = args.length > 1 ? args[1] : "";
  printValue(getPath(readJsonStdin(), jsonPath, fallback));
}

const workerAMIPublicationMaxBytes = 1 << 20;
const workerAMIPublicationSchema = "dirextalk.agent.worker-ami-publication/v1";
const workerAMIImageManifestSchema = "dirextalk.agent.worker-ami/v1";
const digestPattern = /^sha256:[0-9a-f]{64}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const amiPattern = /^ami-[0-9a-f]{8,17}$/;
const snapshotPattern = /^snap-[0-9a-f]{8,17}$/;
const accountPattern = /^[0-9]{12}$/;
const regionPattern = /^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$/;
const rootDevicePattern = /^\/dev\/[a-z0-9]{2,32}$/;
const rfc3339Pattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;

function workerAMIPublicationInvalid() {
  throw new Error("invalid Agent Worker-AMI publication");
}

function exactObjectKeys(value, keys) {
  if (!isObject(value)) workerAMIPublicationInvalid();
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    workerAMIPublicationInvalid();
  }
}

function requiredString(value, pattern) {
  if (typeof value !== "string" || (pattern && !pattern.test(value))) workerAMIPublicationInvalid();
}

function publicationTime(value) {
  requiredString(value, rfc3339Pattern);
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || parsed <= 0) workerAMIPublicationInvalid();
  return parsed;
}

function imageNameIsSafe(value) {
  requiredString(value);
  if (value.length > 128 || !value.startsWith("dtx-worker-ami-") ||
      !/^[A-Za-z0-9][A-Za-z0-9._+=/-]{0,255}$/.test(value)) {
    workerAMIPublicationInvalid();
  }
  const lower = value.toLowerCase();
  const forbidden = [
    "latest", "v1.0.3", ":stable", "presign", "x-amz-", "authorization",
    "credential=", "access_key", "access-key", "secret_key", "secret-key",
    "password", "passwd", "token=", "bearer ", "sessiontoken", "://", "?",
  ];
  if (forbidden.some((marker) => lower.includes(marker)) ||
      /(?:AKIA|ASIA)[0-9A-Z]{16}/.test(value)) {
    workerAMIPublicationInvalid();
  }
}

function parseJSONWithoutDuplicateKeys(input) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(input);
  } catch {
    workerAMIPublicationInvalid();
  }
  let cursor = 0;
  const whitespace = () => {
    while (cursor < text.length && /[\u0020\u0009\u000a\u000d]/.test(text[cursor])) cursor += 1;
  };
  const string = () => {
    if (text[cursor] !== '"') workerAMIPublicationInvalid();
    const start = cursor++;
    while (cursor < text.length) {
      const code = text.charCodeAt(cursor);
      if (code === 0x22) {
        cursor += 1;
        try {
          return JSON.parse(text.slice(start, cursor));
        } catch {
          workerAMIPublicationInvalid();
        }
      }
      if (code <= 0x1f) workerAMIPublicationInvalid();
      if (code === 0x5c) {
        cursor += 1;
        const escape = text[cursor];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.slice(cursor + 1, cursor + 5))) workerAMIPublicationInvalid();
          cursor += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape || "")) workerAMIPublicationInvalid();
      }
      cursor += 1;
    }
    workerAMIPublicationInvalid();
  };
  const value = () => {
    whitespace();
    const token = text[cursor];
    if (token === "{") {
      cursor += 1;
      whitespace();
      const keys = new Set();
      if (text[cursor] === "}") {
        cursor += 1;
        return;
      }
      while (cursor < text.length) {
        const key = string();
        if (keys.has(key)) workerAMIPublicationInvalid();
        keys.add(key);
        whitespace();
        if (text[cursor++] !== ":") workerAMIPublicationInvalid();
        value();
        whitespace();
        const separator = text[cursor++];
        if (separator === "}") return;
        if (separator !== ",") workerAMIPublicationInvalid();
        whitespace();
      }
      workerAMIPublicationInvalid();
    }
    if (token === "[") {
      cursor += 1;
      whitespace();
      if (text[cursor] === "]") {
        cursor += 1;
        return;
      }
      while (cursor < text.length) {
        value();
        whitespace();
        const separator = text[cursor++];
        if (separator === "]") return;
        if (separator !== ",") workerAMIPublicationInvalid();
        whitespace();
      }
      workerAMIPublicationInvalid();
    }
    if (token === '"') {
      string();
      return;
    }
    for (const literal of ["true", "false", "null"]) {
      if (text.startsWith(literal, cursor)) {
        cursor += literal.length;
        return;
      }
    }
    const number = text.slice(cursor).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (!number) workerAMIPublicationInvalid();
    cursor += number[0].length;
  };
  try {
    value();
    whitespace();
    if (cursor !== text.length) workerAMIPublicationInvalid();
    return JSON.parse(text);
  } catch {
    workerAMIPublicationInvalid();
  }
}

function validateWorkerAMIPublication(input) {
  const publication = parseJSONWithoutDuplicateKeys(input);
  exactObjectKeys(publication, ["schema_version", "image_manifest", "image_digest", "attestation"]);
  if (publication.schema_version !== workerAMIPublicationSchema) workerAMIPublicationInvalid();
  requiredString(publication.image_digest, digestPattern);

  const image = publication.image_manifest;
  exactObjectKeys(image, [
    "schema_version", "agent_instance_id", "image_id", "image_name", "root_snapshot_id",
    "account_id", "region", "architecture", "base_ami_id", "base_ami_owner_id",
    "root_device_name", "release_manifest_digest", "worker_rootfs_digest",
    "worker_binary_digest", "created_at",
  ]);
  if (image.schema_version !== workerAMIImageManifestSchema) workerAMIPublicationInvalid();
  requiredString(image.agent_instance_id, uuidPattern);
  requiredString(image.image_id, amiPattern);
  imageNameIsSafe(image.image_name);
  requiredString(image.root_snapshot_id, snapshotPattern);
  requiredString(image.account_id, accountPattern);
  requiredString(image.region, regionPattern);
  if (image.architecture !== "amd64" && image.architecture !== "arm64") workerAMIPublicationInvalid();
  requiredString(image.base_ami_id, amiPattern);
  requiredString(image.base_ami_owner_id, accountPattern);
  requiredString(image.root_device_name, rootDevicePattern);
  requiredString(image.release_manifest_digest, digestPattern);
  requiredString(image.worker_rootfs_digest, digestPattern);
  requiredString(image.worker_binary_digest, digestPattern);
  const createdAt = publicationTime(image.created_at);

  const attestation = publication.attestation;
  exactObjectKeys(attestation, [
    "schema_version", "agent_instance_id", "ami_id", "root_snapshot_id", "account_id",
    "region", "architecture", "release_manifest_digest", "worker_rootfs_digest",
    "worker_binary_digest", "observed_at",
  ]);
  if (attestation.schema_version !== 1) workerAMIPublicationInvalid();
  requiredString(attestation.agent_instance_id, uuidPattern);
  requiredString(attestation.ami_id, amiPattern);
  requiredString(attestation.root_snapshot_id, snapshotPattern);
  requiredString(attestation.account_id, accountPattern);
  requiredString(attestation.region, regionPattern);
  if (attestation.architecture !== "amd64" && attestation.architecture !== "arm64") workerAMIPublicationInvalid();
  requiredString(attestation.release_manifest_digest, digestPattern);
  requiredString(attestation.worker_rootfs_digest, digestPattern);
  requiredString(attestation.worker_binary_digest, digestPattern);
  const observedAt = publicationTime(attestation.observed_at);
  if (observedAt < createdAt ||
      image.agent_instance_id !== attestation.agent_instance_id ||
      image.image_id !== attestation.ami_id ||
      image.root_snapshot_id !== attestation.root_snapshot_id ||
      image.account_id !== attestation.account_id ||
      image.region !== attestation.region ||
      image.architecture !== attestation.architecture ||
      image.release_manifest_digest !== attestation.release_manifest_digest ||
      image.worker_rootfs_digest !== attestation.worker_rootfs_digest ||
      image.worker_binary_digest !== attestation.worker_binary_digest) {
    workerAMIPublicationInvalid();
  }
}

function sameRegularFile(opened, current) {
  return opened.isFile() && current.isFile() &&
    opened.dev === current.dev && opened.ino === current.ino &&
    opened.size === current.size && opened.mtimeNs === current.mtimeNs;
}

function readStableRegularFile(file, maxBytes = workerAMIPublicationMaxBytes) {
  const target = String(file || "").trim();
  if (!target) workerAMIPublicationInvalid();
  let before;
  try {
    before = lstatSync(target, { bigint: true });
  } catch {
    workerAMIPublicationInvalid();
  }
  if (!before.isFile() || before.isSymbolicLink() || before.size <= 0n || before.size > BigInt(maxBytes)) {
    workerAMIPublicationInvalid();
  }
  let descriptor;
  try {
    descriptor = openSync(target, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const opened = fstatSync(descriptor, { bigint: true });
    if (!sameRegularFile(opened, before)) workerAMIPublicationInvalid();
    const input = readFileSync(descriptor);
    const afterRead = fstatSync(descriptor, { bigint: true });
    const afterPath = lstatSync(target, { bigint: true });
    if (BigInt(input.length) !== opened.size ||
        !sameRegularFile(opened, afterRead) ||
        !sameRegularFile(opened, afterPath) ||
        afterPath.isSymbolicLink()) {
      workerAMIPublicationInvalid();
    }
    return input;
  } catch {
    workerAMIPublicationInvalid();
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
  }
}

function fsyncSnapshotDirectory(directory) {
  let descriptor;
  try {
    descriptor = openSync(directory, constants.O_RDONLY);
    fsyncSync(descriptor);
  } catch (error) {
    // Windows does not expose a flushable directory handle through Node. The
    // file and no-clobber hard-link are still flushed; POSIX must durably flush
    // both directory-entry creation and temp cleanup.
    if (process.platform !== "win32") throw error;
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
  }
}

function snapshotPathEntryExists(file) {
  try {
    lstatSync(file);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function unlinkSnapshotTemp(temp, directory) {
  if (!snapshotPathEntryExists(temp)) return;
  unlinkSync(temp);
  fsyncSnapshotDirectory(directory);
}

function validateExactPublicationFile(file, input) {
  const existing = readStableRegularFile(file);
  validateWorkerAMIPublication(existing);
  if (!existing.equals(input)) workerAMIPublicationInvalid();
}

function fsyncSnapshotTemp(temp) {
  let descriptor;
  try {
    descriptor = openSync(temp, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    fsyncSync(descriptor);
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
  }
}

function secureExactPublishedSnapshot(snapshot, input) {
  validateExactPublicationFile(snapshot, input);
  chmodSync(snapshot, 0o600);
  fsyncSnapshotTemp(snapshot);
  validateExactPublicationFile(snapshot, input);
}

function prepareSnapshotTemp(temp, directory, input) {
  if (snapshotPathEntryExists(temp)) {
    try {
      validateExactPublicationFile(temp, input);
      chmodSync(temp, 0o600);
      fsyncSnapshotTemp(temp);
      validateExactPublicationFile(temp, input);
      fsyncSnapshotDirectory(directory);
      return;
    } catch {
      // This exact private path is owned by the snapshot transaction. A crash
      // during its write may leave partial bytes; remove them durably and
      // restart from the already-validated source.
      unlinkSnapshotTemp(temp, directory);
    }
  }
  let descriptor;
  let created = false;
  try {
    descriptor = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW || 0), 0o600);
    created = true;
    writeFileSync(descriptor, input);
    fsyncSync(descriptor);
  } catch {
    if (typeof descriptor === "number") {
      closeSync(descriptor);
      descriptor = undefined;
    }
    if (created) {
      try {
        unlinkSnapshotTemp(temp, directory);
      } catch {
        // The operation still fails closed; a later retry will recover the
        // fixed private temp before publishing anything.
      }
    }
    workerAMIPublicationInvalid();
  } finally {
    if (typeof descriptor === "number") closeSync(descriptor);
  }
  try {
    chmodSync(temp, 0o600);
    validateExactPublicationFile(temp, input);
    fsyncSnapshotDirectory(directory);
  } catch {
    try {
      unlinkSnapshotTemp(temp, directory);
    } catch {
      // A later retry will recover the fixed private temp before publishing.
    }
    workerAMIPublicationInvalid();
  }
}

function cmdWorkerAMIPublicationSnapshot(args) {
  const source = required(args, 0, "publication source");
  const snapshot = String(required(args, 1, "publication snapshot")).trim();
  const expectedDigest = String(args[2] || "");
  if (!snapshot) workerAMIPublicationInvalid();
  const input = readStableRegularFile(source);
  validateWorkerAMIPublication(input);
  const digest = createHash("sha256").update(input).digest("hex");
  if (expectedDigest && (!/^[0-9a-f]{64}$/.test(expectedDigest) || digest !== expectedDigest)) {
    workerAMIPublicationInvalid();
  }
  const directory = path.dirname(snapshot);
  const temp = path.join(directory, `.${path.basename(snapshot)}.tmp`);
  if (snapshotPathEntryExists(snapshot)) {
    try {
      secureExactPublishedSnapshot(snapshot, input);
    } catch {
      try {
        unlinkSnapshotTemp(temp, directory);
      } catch {
        // Never alter the conflicting snapshot even if temp cleanup also fails.
      }
      workerAMIPublicationInvalid();
    }
    fsyncSnapshotDirectory(directory);
    unlinkSnapshotTemp(temp, directory);
    writeOutput(`${digest}\n`);
    return;
  }
  prepareSnapshotTemp(temp, directory, input);
  try {
    linkSync(temp, snapshot);
  } catch (error) {
    if (error?.code !== "EEXIST") {
      try {
        unlinkSnapshotTemp(temp, directory);
      } catch {
        // Preserve the original fail-closed publication failure.
      }
      workerAMIPublicationInvalid();
    }
    try {
      secureExactPublishedSnapshot(snapshot, input);
    } catch {
      try {
        unlinkSnapshotTemp(temp, directory);
      } catch {
        // Never alter the conflicting snapshot even if temp cleanup also fails.
      }
      workerAMIPublicationInvalid();
    }
  }
  fsyncSnapshotDirectory(directory);
  secureExactPublishedSnapshot(snapshot, input);
  unlinkSnapshotTemp(temp, directory);
  writeOutput(`${digest}\n`);
}

function tarString(header, offset, length, value) {
  const encoded = Buffer.from(String(value), "utf8");
  if (encoded.length > length) throw new Error("deterministic bundle path or field is too long");
  encoded.copy(header, offset);
}

function tarOctal(header, offset, length, value) {
  const encoded = Math.trunc(value).toString(8).padStart(length - 1, "0");
  if (encoded.length >= length) throw new Error("deterministic bundle numeric field is too large");
  tarString(header, offset, length, `${encoded}\0`);
}

function tarHeader(name, mode, size, type) {
  const header = Buffer.alloc(512);
  tarString(header, 0, 100, name);
  tarOctal(header, 100, 8, mode);
  tarOctal(header, 108, 8, 0);
  tarOctal(header, 116, 8, 0);
  tarOctal(header, 124, 12, size);
  tarOctal(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  tarString(header, 156, 1, type);
  tarString(header, 257, 6, "ustar\0");
  tarString(header, 263, 2, "00");
  tarString(header, 265, 32, "root");
  tarString(header, 297, 32, "root");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  const encoded = checksum.toString(8).padStart(6, "0");
  tarString(header, 148, 8, `${encoded}\0 `);
  return header;
}

function deterministicBundleEntries(root, requested) {
  const entries = [];
  const visit = (relative) => {
    if (!relative || path.isAbsolute(relative) || relative.split(/[\\/]/).includes("..")) {
      throw new Error("invalid deterministic bundle entry");
    }
    const normalized = relative.replaceAll("\\", "/").replace(/\/+$/, "");
    const absolute = path.join(root, ...normalized.split("/"));
    const info = lstatSync(absolute);
    if (info.isSymbolicLink()) throw new Error("deterministic bundle rejects symlinks");
    if (info.isDirectory()) {
      entries.push({ name: `${normalized}/`, absolute, directory: true });
      for (const child of readdirSync(absolute).sort()) visit(`${normalized}/${child}`);
      return;
    }
    if (!info.isFile()) throw new Error("deterministic bundle accepts only regular files");
    entries.push({ name: normalized, absolute, directory: false, executable: (info.mode & 0o111) !== 0 });
  };
  for (const entry of requested) visit(entry);
  return entries.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
}

function cmdDeterministicBundle(args) {
  const root = required(args, 0, "bundle root");
  const output = required(args, 1, "bundle output");
  const requested = args.slice(2);
  if (!requested.length || existsSync(output)) throw new Error("invalid deterministic bundle destination or entry list");
  const chunks = [];
  for (const entry of deterministicBundleEntries(root, requested)) {
    if (entry.directory) {
      chunks.push(tarHeader(entry.name, 0o755, 0, "5"));
      continue;
    }
    const content = readStableRegularFile(entry.absolute, 16 << 20);
    chunks.push(tarHeader(entry.name, entry.executable ? 0o755 : 0o644, content.length, "0"));
    chunks.push(content);
    const padding = (512 - (content.length % 512)) % 512;
    if (padding) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  const compressed = gzipSync(Buffer.concat(chunks), { level: 9, mtime: 0 });
  compressed.fill(0, 4, 8);
  compressed[9] = 255;
  writeFileSync(output, compressed, { flag: "wx", mode: 0o600 });
}

function cmdLightsailAvailabilityZone(args) {
  const file = required(args, 0, "file");
  const regionName = required(args, 1, "region");
  const suffix = args[2] || "a";
  const data = readJsonFile(file);
  const defaultZone = `${regionName}${suffix}`;
  const region = (Array.isArray(data.regions) ? data.regions : [])
    .find((item) => item.name === regionName);
  if (!region) {
    writeOutput(["", defaultZone, "", "", `Lightsail region ${regionName} was not returned by get-regions`].join("|"));
    setExitCode(2);
    return;
  }
  const zones = Array.isArray(region.availabilityZones) ? region.availabilityZones : [];
  const available = zones
    .filter((zone) => String(zone.zoneName || "") && String(zone.state || "").toLowerCase() !== "unavailable")
    .map((zone) => String(zone.zoneName));
  const unavailable = zones
    .filter((zone) => String(zone.zoneName || "") && String(zone.state || "").toLowerCase() === "unavailable")
    .map((zone) => String(zone.zoneName));
  const selected = available.includes(defaultZone) ? defaultZone : (available[0] || "");
  const reason = selected
    ? (selected === defaultZone ? "" : `default Lightsail zone ${defaultZone} is unavailable; selected ${selected}`)
    : `no available Lightsail availability zone found for region ${regionName}`;
  writeOutput([selected, defaultZone, available.join(","), unavailable.join(","), reason].join("|"));
  if (!selected) setExitCode(2);
}

function cmdLightsailBundleSelect(args) {
  const file = required(args, 0, "file");
  const targetPrice = numberValue(required(args, 1, "target price"));
  const targetRam = numberValue(required(args, 2, "target RAM"));
  const targetDisk = numberValue(required(args, 3, "target disk"));
  const preferredID = String(args[4] || "");
  const data = readJsonFile(file);
  const platformOk = (bundle) => {
    const platform = String(bundle.supportedPlatforms || bundle.supportedPlatform || bundle.platform || "").toLowerCase();
    return platform === "" || platform.includes("linux") || platform.includes("unix");
  };
  const candidates = (Array.isArray(data.bundles) ? data.bundles : [])
    .filter(platformOk)
    .map((bundle) => ({
      id: String(bundle.bundleId || ""),
      price: numberValue(bundle.price),
      ram: numberValue(bundle.ramSizeInGb),
      disk: numberValue(bundle.diskSizeInGb),
      transfer: numberValue(bundle.transferPerMonthInGb),
      cpu: numberValue(bundle.cpuCount),
      active: bundle.isActive !== false
    }))
    .filter((bundle) => bundle.id && bundle.price > 0 && bundle.active);
  const exact = candidates.filter((bundle) => Math.abs(bundle.price - targetPrice) < 0.01 && bundle.ram >= targetRam && bundle.disk >= targetDisk);
  const fallback = candidates.filter((bundle) => bundle.price >= targetPrice && bundle.ram >= targetRam);
  const preferred = preferredID ? candidates.find((bundle) => bundle.id === preferredID) : null;
  const selected = preferred || (exact.length ? exact : fallback)
    .sort((left, right) => left.price - right.price || left.ram - right.ram || left.disk - right.disk)[0];
  if (!selected) {
    setExitCode(1);
    return;
  }
  writeOutput([selected.id, selected.price, selected.ram, selected.disk, selected.transfer, selected.cpu].join("\t"));
}

function cmdAssert(args) {
  const file = required(args, 0, "file");
  const preset = required(args, 1, "preset");
  const data = readJsonFile(file);
  assertPreset(data, preset, args.slice(2));
}

function cmdStdinAssert(args) {
  const preset = required(args, 0, "preset");
  const data = readJsonStdin();
  assertPreset(data, preset, args.slice(1));
}

function assertPreset(data, preset, rest) {
  let ok = false;

  switch (preset) {
    case "path-equals": {
      const jsonPath = required(rest, 0, "path");
      const expected = required(rest, 1, "expected");
      ok = String(getPath(data, jsonPath, "")) === expected;
      break;
    }
    case "path-missing": {
      const jsonPath = required(rest, 0, "path");
      ok = !hasPath(data, jsonPath);
      break;
    }
    case "messages-list":
      ok = Array.isArray(data.messages) && typeof data.room_id === "undefined";
      if (!ok && Array.isArray(data.messages) && typeof data.room_id === "string") ok = true;
      break;
    case "messages-response":
      ok = Array.isArray(data.messages) && typeof data.room_id === "string";
      break;
    case "tools-list":
      ok = Array.isArray(data.tools) && typeof data.tool_count === "number";
      break;
    case "matrix-session":
      ok = Boolean(data.access_token && data.device_id && data.user_id && data.homeserver);
      break;
    case "well-known-server": {
      const expected = required(rest, 0, "expected");
      ok = data["m.server"] === expected;
      break;
    }
    case "turn-credentials":
      ok = Array.isArray(data.uris) &&
        data.uris.length > 0 &&
        data.uris.some((uri) => /^turns?:/.test(String(uri))) &&
        String(data.username || "").length > 0 &&
        String(data.password || "").length > 0 &&
        Number(data.ttl) > 0;
      break;
    case "bootstrap-normalized":
      ok = typeof data.password === "string" &&
        /^[0-9]{8}$/.test(data.password) &&
        typeof data.agent_token === "string" &&
        data.agent_token.length > 0 &&
        typeof data.access_token === "string" &&
        data.access_token.length > 0;
      break;
    default:
      usage(`unknown assert preset: ${preset}`);
  }

  if (!ok) commandExit(1);
}

function cmdCheck(args) {
  const file = required(args, 0, "file");
  const expression = required(args, 1, "expression");
  const data = readJsonFile(file);
  const ok = Boolean(Function("data", `"use strict"; return (${expression});`)(data));
  if (!ok) commandExit(1);
}

function cmdEntries(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  const value = getPath(readJsonFile(file), jsonPath, {});
  if (!isObject(value)) return;
  for (const [key, entryValue] of Object.entries(value)) {
    printLine(`${key}=${formatEntryValue(entryValue)}`);
  }
}

function cmdStdinTsv(args) {
  const arrayPath = required(args, 0, "array_path");
  const fields = args.slice(1);
  if (fields.length === 0) usage("stdin-tsv requires at least one field");
  const value = getPath(readJsonStdin(), arrayPath, []);
  if (!Array.isArray(value)) return;
  for (const entry of value) {
    printLine(fields.map((field) => stringValue(getPath(entry, field, ""))).join("\t"));
  }
}

function cmdStdinJoin(args) {
  const jsonPath = required(args, 0, "path");
  const separator = args.length > 1 ? args[1] : ",";
  const value = getPath(readJsonStdin(), jsonPath, []);
  if (!Array.isArray(value)) return;
  printLine(value.map((item) => stringValue(item)).join(separator));
}

function cmdStdinRoute53AValues(args) {
  const name = required(args, 0, "record_name");
  const data = readJsonStdin();
  const rrsets = Array.isArray(data.ResourceRecordSets) ? data.ResourceRecordSets : [];
  const values = [];
  for (const rrset of rrsets) {
    if (rrset?.Name !== name || rrset?.Type !== "A") continue;
    for (const record of Array.isArray(rrset.ResourceRecords) ? rrset.ResourceRecords : []) {
      if (typeof record?.Value !== "undefined") values.push(String(record.Value));
    }
  }
  printLine(values.join(","));
}

function cmdStdinRoute53APresent(args) {
  const name = required(args, 0, "record_name");
  const ip = required(args, 1, "ip");
  const data = readJsonStdin();
  const rrsets = Array.isArray(data.ResourceRecordSets) ? data.ResourceRecordSets : [];
  const present = rrsets.some((rrset) =>
    rrset?.Name === name &&
    rrset?.Type === "A" &&
    (Array.isArray(rrset.ResourceRecords) ? rrset.ResourceRecords : []).some((record) => String(record?.Value) === ip)
  );
  printLine(String(present));
}

function cmdStdinPriceUsd() {
  const data = readJsonStdin();
  const firstPrice = data.PriceList?.[0];
  if (typeof firstPrice !== "string") return;
  const product = JSON.parse(firstPrice);
  const onDemand = Object.values(product.terms?.OnDemand || {})[0];
  const dimension = Object.values(onDemand?.priceDimensions || {})[0];
  printValue(dimension?.pricePerUnit?.USD || "");
}

function cmdLength(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  const value = getPath(readJsonFile(file), jsonPath, null);
  if (Array.isArray(value) || typeof value === "string") {
    printLine(String(value.length));
    return;
  }
  if (isObject(value)) {
    printLine(String(Object.keys(value).length));
    return;
  }
  printLine("0");
}

function cmdType(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  printLine(jsonType(getPath(readJsonFile(file), jsonPath, undefined)));
}

function cmdBuild(args) {
  const preset = required(args, 0, "preset");
  let data;

  switch (preset) {
    case "simple-state":
      data = {};
      for (const [key, value] of parsePairs(args.slice(1))) setPath(data, key, parseScalar(value));
      break;
    case "object":
      data = {};
      for (const [key, value] of parsePairs(args.slice(1))) setPath(data, key, parseScalar(value));
      break;
    case "matrix-session-create":
      data = { action: "agent.matrix_session.create", params: { device_id: required(args, 1, "device_id") } };
      writeOutput(`${JSON.stringify(data)}\n`);
      return;
    case "portal-auth":
      data = { action: "portal.auth", params: { password: required(args, 1, "password") } };
      writeOutput(`${JSON.stringify(data)}\n`);
      return;
    case "mcp-jsonrpc-initialize":
      data = {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-06-18",
          capabilities: {},
          clientInfo: {
            name: "dirextalk-deployer",
            version: "0.0.0"
          }
        }
      };
      writeOutput(`${JSON.stringify(data)}\n`);
      return;
    case "mcp-jsonrpc-tools-list":
      data = { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} };
      writeOutput(`${JSON.stringify(data)}\n`);
      return;
    case "mcp-jsonrpc-messages-list-call":
      data = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "dirextalk_messages_list",
          arguments: {
            room_id: required(args, 1, "room_id"),
            limit: 1
          }
        }
      };
      writeOutput(`${JSON.stringify(data)}\n`);
      return;
    case "credentials-profile": {
      const asUrl = required(args, 2, "as_url").replace(/\/+$/, "");
      data = {
        profiles: {
          default: {
            domain: required(args, 1, "domain"),
            password: required(args, 4, "password"),
            access_token: required(args, 5, "access_token"),
            agent_token: required(args, 3, "agent_token"),
            agent_room_id: required(args, 6, "agent_room_id"),
            agent_node_id: required(args, 7, "node_id"),
            mcp_url: `${asUrl}/mcp`
          }
        }
      };
      break;
    }
    case "openclaw-mcp-patch": {
      const credentials = readJsonFile(required(args, 1, "credentials_file"));
      const profile = credentials?.profiles?.default;
      const serverName = required(args, 2, "server_name");
      const envKey = required(args, 3, "env_key");
      const endpoint = stringValue(profile?.mcp_url);
      const token = stringValue(profile?.agent_token);
      if (!/^https:\/\/[^\s]+\/mcp$/.test(endpoint) || token.length === 0) {
        commandExit(2);
        return;
      }
      data = {
        mcp: {
          servers: {
            [serverName]: {
              url: endpoint,
              transport: "streamable-http",
              headers: { Authorization: `Bearer \${${envKey}}` }
            }
          }
        },
        env: { vars: { [envKey]: token } }
      };
      break;
    }
    case "openclaw-mcp-cleanup-patch": {
      const serverName = required(args, 1, "server_name");
      const envKey = required(args, 2, "env_key");
      data = {
        mcp: { servers: { [serverName]: null } },
        env: { vars: { [envKey]: null } }
      };
      break;
    }
    case "pricing-estimate":
      data = buildPricingEstimate(args.slice(1));
      break;
    case "bootstrap-normalized":
      data = normalizeBootstrap(required(args, 1, "file"), required(args, 2, "domain"));
      break;
    default:
      usage(`unknown build preset: ${preset}`);
  }

  writeOutput(`${JSON.stringify(data, null, 2)}\n`);
}

function cmdMutate(args) {
  const file = required(args, 0, "file");
  const preset = required(args, 1, "preset");
  const data = existsSync(file) ? readJsonFileOrEmptyObject(file) : {};

  switch (preset) {
    case "set-string": {
      setPath(data, required(args, 2, "path"), required(args, 3, "value"));
      break;
    }
    case "set-json": {
      setPath(data, required(args, 2, "path"), JSON.parse(required(args, 3, "json")));
      break;
    }
    case "state-init": {
      const runId = required(args, 2, "run_id");
      const region = required(args, 3, "region");
      const ts = required(args, 4, "timestamp");
      const phases = args.slice(5);
      const phaseState = {};
      for (const phase of phases) phaseState[phase] = { status: "pending" };
      Object.assign(data, {
        run_id: runId,
        region: region === "" ? null : region,
        domain_mode: null,
        domain: null,
        domain_confirmed_irreversible: false,
        instance_type: null,
        dns_ready: false,
        existing_state_confirmed: false,
        phase: "S0_PREREQ_AWS",
        created_at: ts,
        phases: phaseState,
        resources: {}
      });
      break;
    }
    case "phase-set": {
      const phase = required(args, 2, "phase");
      const status = required(args, 3, "status");
      const ts = required(args, 4, "timestamp");
      const evidence = args[5] || "";
      if (!isObject(data.phases)) data.phases = {};
      if (!isObject(data.phases[phase])) data.phases[phase] = {};
      data.phases[phase].status = status;
      data.phases[phase].ts = ts;
      if (evidence !== "") data.phases[phase].evidence = evidence;
      data.phase = phase;
      break;
    }
    case "ops-refresh-pending": {
      const startPhase = required(args, 2, "start_phase");
      const ts = required(args, 3, "timestamp");
      for (const key of [
        "password",
        "access_token",
        "agent_token",
        "agent_room_id",
        "user_confirmations",
        "runtime_checks",
        "mcp_daemon_install_status",
        "mcp_daemon_install_command",
        "mcp_daemon_status_command",
        "mcp_daemon_url",
        "mcp_daemon_proxy_command",
        "mcp_host_probe_status"
      ]) {
        delete data[key];
      }
      data.connect_install_status = "refresh_pending";
      data.mcp_install_status = "refresh_pending";
      data.phase = startPhase;
      if (!isObject(data.phases)) data.phases = {};
      if (startPhase === "S4_BOOTSTRAP_STACK") {
        data.phases.S4_BOOTSTRAP_STACK = {
          status: "pending",
          ts,
          evidence: "existing node operation requires fresh health check"
        };
      }
      data.phases.S5_INIT_TOKENS = {
        status: "pending",
        ts,
        evidence: "existing node operation requires fresh bootstrap credentials"
      };
      data.phases.S6_WIRE_LOCAL = {
        status: "pending",
        ts,
        evidence: "existing node operation requires local credentials and MCP refresh"
      };
      data.phases.S7_VERIFY_E2E = {
        status: "pending",
        ts,
        evidence: "existing node operation requires fresh verification"
      };
      break;
    }
    case "delete": {
      deletePath(data, required(args, 2, "path"));
      break;
    }
    case "destroy-evidence": {
      const key = required(args, 2, "key");
      if (!isObject(data.destroy_evidence)) data.destroy_evidence = {};
      data.destroy_evidence[key] = {
        status: required(args, 3, "status"),
        detail: args[4] || "",
        checked_at: required(args, 5, "checked_at")
      };
      break;
    }
    default:
      usage(`unknown mutate preset: ${preset}`);
  }

  atomicWriteJson(file, data);
}

function cmdOperationReport(args) {
  const operation = required(args, 0, "operation");
  const status = required(args, 1, "status");
  const stateFile = required(args, 2, "state");
  const generatedAt = required(args, 3, "generated_at");
  const st = readJsonFile(stateFile);
  writeOutput(`${JSON.stringify(buildOperationReport(operation, status, stateFile, generatedAt, st), null, 2)}\n`);
}

function buildOperationReport(operation, status, stateFile, generatedAt, st) {
  const redactedStatus = stringValue(st.password).length > 0 ? "available_in_state_password_field_redacted" : "missing";
  const cloudProvider = stringValue(st.cloud_provider || "");
  const phaseStatuses = {};
  for (const [key, value] of Object.entries(objectValue(st.phases))) {
    phaseStatuses[key] = stringValue(value?.status || "unknown");
  }
  const localRefreshStatus = st.connect_install_status === "refresh_pending" ? "refresh_pending" : "current_or_not_recorded";
  const billable = compact([
    stringValue(st.resources?.lightsail_instance_name) ? `Lightsail instance ${st.resources.lightsail_instance_name}` : "",
    stringValue(st.resources?.lightsail_static_ip_name) ? `Lightsail static IP ${st.resources.lightsail_static_ip_name}` : "",
    cloudProvider !== "lightsail" && stringValue(st.resources?.instance_id) ? `EC2 ${st.resources.instance_id}` : "",
    cloudProvider !== "lightsail" && stringValue(st.resources?.root_volume_id) ? `EBS root volume ${st.resources.root_volume_id}` : "",
    stringValue(st.resources?.public_ip) ? `public IPv4 ${st.resources.public_ip}` : "",
    cloudProvider !== "lightsail" && stringValue(st.resources?.eip_id) ? `Elastic IP ${st.resources.eip_id}` : "",
    stringValue(st.resources?.route53_zone_id) ? `Route53 hosted zone ${st.resources.route53_zone_id}` : ""
  ]);
  const destroyStatus = (key) => st.destroy_evidence?.[key]?.status || "not_checked";
  const statusNotIn = (value, safe) => !safe.includes(value);
  const destroyBillableResidue = compact([
    stringValue(st.resources?.lightsail_instance_name) && statusNotIn(destroyStatus("lightsail_instance"), ["deleted", "not_found", "skipped"])
      ? `Lightsail instance ${st.resources.lightsail_instance_name} status=${destroyStatus("lightsail_instance")}` : "",
    stringValue(st.resources?.lightsail_static_ip_name) && statusNotIn(destroyStatus("lightsail_static_ip"), ["released", "not_found", "skipped"])
      ? `Lightsail static IP ${st.resources.lightsail_static_ip_name} status=${destroyStatus("lightsail_static_ip")}` : "",
    cloudProvider !== "lightsail" && stringValue(st.resources?.instance_id) && statusNotIn(destroyStatus("ec2_instance"), ["terminated", "not_found", "skipped"])
      ? `EC2 ${st.resources.instance_id} status=${destroyStatus("ec2_instance")}` : "",
    cloudProvider !== "lightsail" && stringValue(st.resources?.root_volume_id) && statusNotIn(destroyStatus("ebs_root_volume"), ["deleted", "skipped"])
      ? `EBS root volume ${st.resources.root_volume_id} status=${destroyStatus("ebs_root_volume")}` : "",
    cloudProvider !== "lightsail" && stringValue(st.resources?.eip_id) && statusNotIn(destroyStatus("elastic_ip"), ["released", "skipped"])
      ? `Elastic IP ${st.resources.eip_id} status=${destroyStatus("elastic_ip")}` : "",
    stringValue(st.resources?.route53_zone_id) && statusNotIn(destroyStatus("route53_hosted_zone"), ["deleted", "skipped"])
      ? `Route53 hosted zone ${st.resources.route53_zone_id} status=${destroyStatus("route53_hosted_zone")}` : ""
  ]);

  const report = {
    operation_type: operation,
    status,
    generated_at: generatedAt,
    domain: st.domain || "",
    service_id: st.agent_service_id || st.domain || "",
    service_dir: st.agent_service_dir || "",
    state_json: stateFile,
    delivery: {
      app_domain: st.domain || "",
      product_completion_status: status,
      init_code_status: redactedStatus,
      init_code_secret_redacted: true,
      user_path: "enter app_domain and the eight-digit initialization code in the App"
    },
    agent: {
      node_id: st.agent_node_id || "",
      room_id: st.agent_room_id || "",
      runtime: st.agent_runtime || "unknown",
      service_id: st.agent_service_id || st.domain || "",
      credentials_file: st.agent_credentials_file || ""
    },
    gates: {
      automated: phaseStatuses
    },
    runtime_checks: {
      summary: st.runtime_checks?.summary || { status: "not_run" },
      connect_daemon: st.runtime_checks?.connect_daemon || { status: "not_run" },
      mcp_doctor: st.runtime_checks?.mcp_doctor || { status: "not_run" },
      mcp_smoke: st.runtime_checks?.mcp_smoke || { status: "not_run" },
      mcp_tools: st.runtime_checks?.mcp_tools || { status: "not_run" }
    },
    credentials: {
      status: localRefreshStatus,
      credentials_file: st.agent_credentials_file || "",
      contains_secrets: true,
      values_redacted: true
    },
    connect: {
      package: st.connect_npm_package || "dirextalk-connect@latest",
      agent: st.connect_agent || "",
      config: st.connect_config || "",
      install_status: st.connect_install_status || ""
    },
    release: {
      source: st.server_release?.source || "unknown",
      version: st.server_release?.version || "",
      image: st.server_release?.image || "",
      digest: st.server_release?.digest || "",
      image_ref: st.server_release?.image_ref || "",
      manifest_digest: st.server_release?.manifest_digest || ""
    },
    updater_release: {
      version: st.updater_release?.version || "",
      commit: st.updater_release?.commit || "",
      sha256: st.updater_release?.sha256 || "",
      asset: st.updater_release?.asset || "",
      os: st.updater_release?.os || "",
      arch: st.updater_release?.arch || "",
      ubuntu_version: st.updater_release?.ubuntu_version || ""
    },
    mcp: {
      status: localRefreshStatus,
      install_status: st.mcp_install_status || "",
      host_probe_status: st.mcp_host_probe_status || "not_recorded",
      capability: st.mcp_capability || "undeclared",
      transport: st.mcp_transport || "http",
      endpoint_url: st.mcp_endpoint_url || "",
      server_name: st.mcp_server_name || "",
      config_dir: st.mcp_config_dir || "",
      selected_config_type: st.mcp_selected_config_type || "none",
      selected_config: st.mcp_selected_config || "",
      openclaw: st.mcp_openclaw_config || "",
      hermes: st.mcp_hermes_config || "",
      doctor: st.mcp_doctor_command || ""
    },
    resources: {
      region: st.region || "",
      cloud_provider: st.cloud_provider || "",
      domain_mode: st.domain_mode || "",
      instance_type: st.instance_type || "",
      instance_id: st.resources?.instance_id || "",
      root_volume_id: st.resources?.root_volume_id || "",
      public_ip: st.resources?.public_ip || "",
      eip_id: st.resources?.eip_id || "",
      lightsail_instance_name: st.resources?.lightsail_instance_name || "",
      lightsail_static_ip_name: st.resources?.lightsail_static_ip_name || "",
      lightsail_bundle_id: st.resources?.lightsail_bundle_id || "",
      lightsail_bundle_price_usd: st.resources?.lightsail_bundle_price_usd || "",
      route53_zone_id: st.resources?.route53_zone_id || "",
      route53_zone_name: st.resources?.route53_zone_name || "",
      route53_zone_created_by_deployer: st.resources?.route53_zone_created_by_deployer || "",
      route53_name_servers: st.resources?.route53_name_servers || "",
      route53_existing_a_value: st.resources?.route53_existing_a_value || "",
      route53_pending_a_value: st.resources?.route53_pending_a_value || "",
      route53_overwrite_confirmed: st.resources?.route53_overwrite_confirmed || "",
      sg_id: st.resources?.sg_id || "",
      key_name: st.resources?.key_name || ""
    },
    billing: {
      keeps_billing_until_destroy: operation !== "destroy",
      recorded_billable_resources: billable,
      cost_estimate: typeof st.cost_estimate === "undefined" ? null : st.cost_estimate,
      destroy_cleanup_status: operation !== "destroy"
        ? "not_destroy"
        : destroyBillableResidue.length === 0
          ? "no_recorded_billable_resource_residue"
          : "possible_billable_resource_residue",
      possible_remaining_billable_resources: operation === "destroy" ? destroyBillableResidue : []
    },
    security: {
      secrets_included: false,
      values_redacted: true,
      root_access_key_allowed: true,
      temporary_iam_cleanup_required: true,
      temporary_iam_cleanup_action: "if a temporary DirextalkDeployer access key was used, delete or disable it after deployment, or reduce it to a maintenance-only policy"
    }
  };

  if (operation === "destroy") {
    report.destroy = {
      resources_processed_from_state: true,
      user_managed_dns_not_removed: true,
      purchased_domain_not_removed: true,
      local_service_dir: st.agent_service_dir || "",
      evidence: st.destroy_evidence || {}
    };
  }

  return report;
}

function readJsonFile(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function readJsonFileOrEmptyObject(file) {
  const raw = readFileSync(file, "utf8");
  return raw.trim().length === 0 ? {} : JSON.parse(raw);
}

function readJsonStdin() {
  return JSON.parse(typeof activeStdin === "string" ? activeStdin : readFileSync(0, "utf8"));
}

function atomicWriteJson(file, data) {
  const tmp = `${file}.tmp.${process.pid}`;
  const directory = path.dirname(file);
  let descriptor;
  try {
    descriptor = openSync(
      tmp,
      constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | (constants.O_NOFOLLOW || 0),
      0o600,
    );
    writeFileSync(descriptor, `${JSON.stringify(data, null, 2)}\n`, { encoding: "utf8" });
    chmodSync(tmp, 0o600);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(tmp, file);
    fsyncSnapshotDirectory(directory);
  } catch (error) {
    if (typeof descriptor === "number") closeSync(descriptor);
    try {
      if (snapshotPathEntryExists(tmp)) unlinkSync(tmp);
    } catch {
      // Preserve the original mutation failure. A later atomic write replaces
      // this private per-process temp before publishing another state value.
    }
    throw error;
  }
}

function getPath(data, jsonPath, fallback = "") {
  const result = resolvePath(data, jsonPath);
  return result.exists ? result.value : fallback;
}

function hasPath(data, jsonPath) {
  return resolvePath(data, jsonPath).exists;
}

function setPath(data, jsonPath, value) {
  const segments = parsePath(jsonPath);
  let current = data;
  for (let i = 0; i < segments.length - 1; i += 1) {
    const segment = segments[i];
    if (!isObject(current[segment])) current[segment] = {};
    current = current[segment];
  }
  current[segments[segments.length - 1]] = value;
}

function deletePath(data, jsonPath) {
  const segments = parsePath(jsonPath);
  let current = data;
  for (let i = 0; i < segments.length - 1; i += 1) {
    current = current?.[segments[i]];
    if (!isObject(current)) return;
  }
  delete current[segments[segments.length - 1]];
}

function resolvePath(data, jsonPath) {
  if (jsonPath === "." || jsonPath === "") return { exists: true, value: data };
  let current = data;
  for (const segment of parsePath(jsonPath)) {
    if (!isObject(current) && !Array.isArray(current)) return { exists: false, value: undefined };
    if (!(segment in current)) return { exists: false, value: undefined };
    current = current[segment];
  }
  return { exists: true, value: current };
}

function parsePath(jsonPath) {
  return String(jsonPath)
    .split(".")
    .filter((segment) => segment.length > 0);
}

function parsePairs(args) {
  return args.map((pair) => {
    const index = pair.indexOf("=");
    if (index < 0) usage(`expected key=value, got: ${pair}`);
    return [pair.slice(0, index), pair.slice(index + 1)];
  });
}

function parseScalar(value) {
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null") return null;
  if (/^-?\d+(\.\d+)?$/.test(value)) return Number(value);
  if ((value.startsWith("{") && value.endsWith("}")) || (value.startsWith("[") && value.endsWith("]"))) {
    return JSON.parse(value);
  }
  return value;
}

function buildPricingEstimate(args) {
  const [
    pricingStatus,
    region,
    location,
    instanceType,
    domainMode,
    ec2Source,
    gp3Source,
    ipv4Source,
    warningsJson,
    hours,
    diskGb,
    ec2Hourly,
    ec2Monthly,
    gp3Rate,
    gp3Monthly,
    ipv4Hourly,
    ipv4Monthly,
    route53Monthly
  ] = args;
  const components = {
    ec2_instance: {
      instance_type: required(args, 3, "instance_type"),
      hourly_usd: numberValue(ec2Hourly),
      monthly_usd: numberValue(ec2Monthly),
      source: ec2Source
    },
    ebs_gp3: {
      storage_gb: numberValue(diskGb),
      gb_month_usd: numberValue(gp3Rate),
      monthly_usd: numberValue(gp3Monthly),
      source: gp3Source
    },
    public_ipv4: {
      hourly_usd: numberValue(ipv4Hourly),
      monthly_usd: numberValue(ipv4Monthly),
      billed_even_when_attached: true,
      source: ipv4Source
    },
    route53_hosted_zone: {
      monthly_usd: numberValue(route53Monthly),
      included: domainMode === "route53"
    }
  };
  const total = components.ec2_instance.monthly_usd +
    components.ebs_gp3.monthly_usd +
    components.public_ipv4.monthly_usd +
    components.route53_hosted_zone.monthly_usd;
  return {
    provider: "ec2",
    pricing_status: pricingStatus,
    region,
    location,
    hours_per_month: numberValue(hours),
    warnings: unique(JSON.parse(warningsJson || "[]")),
    components,
    notes: [
      "Estimate excludes data transfer, TURN relay traffic, domain registration, taxes, and AWS credit eligibility.",
      "Public IPv4 is billed hourly by AWS even when attached to a running instance.",
      "AWS credits may reduce charges only when the account, plan, region, and service usage are eligible; verify in AWS Billing Console."
    ],
    recommendations: [
      "Set an AWS Budget or billing alert before leaving the node running.",
      "Review AWS Billing Console after deployment and after destroy to confirm actual charges."
    ],
    total_monthly_usd: Math.round(total * 100) / 100
  };
}

function normalizeBootstrap(file, domain) {
  const src = readJsonFile(file);
  const asUrl = `https://${domain}`;
  return {
    ...src,
    domain: src.domain || domain,
    as_url: src.as_url || asUrl,
    p2p_url: src.p2p_url || asUrl,
    user_id: src.user_id || src.owner_user_id || "",
    bot_mxid: src.bot_mxid || src.owner_user_id || src.user_id || `@owner:${domain}`,
    access_token: src.access_token || "",
    agent_token: src.agent_token || "",
    agent_room_id: src.agent_room_id || ""
  };
}

function numberValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function unique(values) {
  return Array.from(new Set(values));
}

function printValue(value) {
  if (value === null || typeof value === "undefined") {
    writeOutput("\n");
    return;
  }
  if (typeof value === "object") {
    writeOutput(`${JSON.stringify(value)}\n`);
    return;
  }
  writeOutput(`${String(value)}\n`);
}

function printLine(value) {
  writeOutput(`${value}\n`);
}

function formatEntryValue(value) {
  if (value === null || typeof value === "undefined") return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function jsonType(value) {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  if (typeof value === "undefined") return "missing";
  return typeof value;
}

function required(args, index, name) {
  const value = args[index];
  if (typeof value === "undefined") usage(`missing ${name}`);
  return value;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function usage(message) {
  throw new Error(`${message}\nUsage: scripts/json.mjs <get|stdin-get|assert|stdin-assert|check|entries|stdin-tsv|stdin-join|stdin-route53-a-values|stdin-route53-a-present|stdin-price-usd|lightsail-availability-zone|lightsail-bundle-select|length|type|build|mutate|operation-report|valid|worker-ami-publication-snapshot|deterministic-bundle> ...`);
}

function writeOutput(value) {
  activeStdout(String(value));
}

function setExitCode(status) {
  activeExitCode = Number(status) || 0;
}

function commandExit(status) {
  throw new JsonCommandExit(Number(status) || 1);
}

function compact(values) {
  return values.filter((value) => String(value || "").length > 0);
}

function objectValue(value) {
  return isObject(value) ? value : {};
}

function stringValue(value) {
  return typeof value === "undefined" || value === null ? "" : String(value);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, ...args] = parseCliArgs();
  const result = executeJsonCommand(command, args);
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  process.exitCode = result.status;
}
