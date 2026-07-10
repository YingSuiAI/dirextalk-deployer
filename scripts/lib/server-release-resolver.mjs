#!/usr/bin/env node
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import semver from "semver";

export const latestReleaseAPI = "https://api.github.com/repos/YingSuiAI/dirextalk-message-server/releases/latest";
const manifestAsset = "release-manifest.json";
const checksumAsset = `${manifestAsset}.sha256`;
const allowedImage = "dirextalk/message-server";
const maximumBytes = 1024 * 1024;
const requestTimeoutMs = 30_000;
const maximumRedirects = 5;
const assetCDNHosts = new Set(["release-assets.githubusercontent.com", "objects.githubusercontent.com"]);
const assetURLPattern = /^https:\/\/github\.com\/YingSuiAI\/dirextalk-message-server\/releases\/download\/v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\/release-manifest\.json(?:\.sha256)?$/;
const versionPattern = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const digestPattern = /^sha256:[0-9a-f]{64}$/;
const manifestFields = new Set([
  "manifest_version", "version", "image", "image_digest", "upgrade_from",
  "schema_version", "schema_compat_version", "minimum_client_version",
  "maximum_client_version_exclusive", "backup_required", "rollback_supported",
  "rollback_mode", "release_notes_url",
]);

function requireObject(value, label) {
  if (value === null || Array.isArray(value) || typeof value !== "object") throw new Error(`${label} must be an object`);
  return value;
}

function parseJSON(data, label) {
  try {
    return requireObject(JSON.parse(Buffer.from(data).toString("utf8")), label);
  } catch (error) {
    throw new Error(`invalid ${label}: ${error.message}`);
  }
}

function parseVersion(value, label) {
  if (typeof value !== "string") throw new Error(`${label} must be canonical vX.Y.Z`);
  const match = versionPattern.exec(value);
  if (!match) throw new Error(`${label} must be canonical vX.Y.Z`);
  return match.slice(1).map(Number);
}

function compareVersion(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

function validateUpgradeFrom(values, targetVersion) {
  if (!Array.isArray(values)) throw new Error("release manifest upgrade_from must be an array");
  const unique = new Set();
  for (const value of values) {
    if (typeof value !== "string" || value.trim() === "") throw new Error("release manifest upgrade_from entries must be non-empty strings");
    if (unique.has(value)) throw new Error("release manifest upgrade_from entries must be unique");
    unique.add(value);
    let constraint;
    try {
      constraint = new semver.Range(value.trim(), { loose: false, includePrerelease: false });
    } catch {
      throw new Error(`release manifest upgrade_from constraint is invalid: ${value}`);
    }
    if (constraint.test(targetVersion.slice(1))) {
      throw new Error(`release manifest upgrade_from constraint includes target ${targetVersion}: ${value}`);
    }
  }
}

function validateManifest(manifest) {
  for (const field of Object.keys(manifest)) {
    if (!manifestFields.has(field)) throw new Error(`release manifest contains unknown field ${field}`);
  }
  if (Object.keys(manifest).length !== manifestFields.size || manifest.manifest_version !== 1) throw new Error("release manifest fields/version are invalid");
  parseVersion(manifest.version, "manifest version");
  if (manifest.image !== `${allowedImage}:${manifest.version}`) throw new Error("release manifest image is inconsistent");
  if (!digestPattern.test(manifest.image_digest)) throw new Error("release manifest image_digest is invalid");
  validateUpgradeFrom(manifest.upgrade_from, manifest.version);
  if (!Number.isInteger(manifest.schema_version) || !Number.isInteger(manifest.schema_compat_version)
      || manifest.schema_version < 1 || manifest.schema_compat_version < 1 || manifest.schema_compat_version > manifest.schema_version) {
    throw new Error("release manifest schema window is invalid");
  }
  const minimum = parseVersion(manifest.minimum_client_version, "minimum_client_version");
  const maximum = parseVersion(manifest.maximum_client_version_exclusive, "maximum_client_version_exclusive");
  if (compareVersion(minimum, maximum) >= 0) throw new Error("release manifest client window is invalid");
  if (manifest.backup_required !== true) throw new Error("release manifest must require backup");
  if (typeof manifest.rollback_supported !== "boolean"
      || (manifest.rollback_supported && manifest.rollback_mode !== "restore_backup")
      || (!manifest.rollback_supported && manifest.rollback_mode !== "")) {
    throw new Error("release manifest rollback contract is invalid");
  }
  const notes = `https://github.com/YingSuiAI/dirextalk-message-server/releases/tag/${manifest.version}`;
  if (manifest.release_notes_url !== notes) throw new Error("release manifest notes URL is invalid");
}

function releaseAssetURL(tag, name) {
  return `https://github.com/YingSuiAI/dirextalk-message-server/releases/download/${tag}/${name}`;
}

export async function resolveServerRelease(getBytes) {
  if (typeof getBytes !== "function") throw new Error("release byte source is required");
  const release = parseJSON(await getBytes(latestReleaseAPI), "release metadata");
  parseVersion(release.tag_name, "release tag");
  if (release.draft !== false || release.prerelease !== false || !Array.isArray(release.assets)) throw new Error("latest release is not a published stable release");
  const URLs = new Map();
  for (const asset of release.assets) {
    if (!asset || (asset.name !== manifestAsset && asset.name !== checksumAsset)) continue;
    if (URLs.has(asset.name)) throw new Error(`duplicate release asset ${asset.name}`);
    const expected = releaseAssetURL(release.tag_name, asset.name);
    if (asset.browser_download_url !== expected) throw new Error(`release asset ${asset.name} URL is invalid`);
    URLs.set(asset.name, expected);
  }
  if (!URLs.has(manifestAsset) || !URLs.has(checksumAsset)) throw new Error("formal release assets are incomplete");
  const manifestData = Buffer.from(await getBytes(URLs.get(manifestAsset)));
  const checksumData = Buffer.from(await getBytes(URLs.get(checksumAsset))).toString("utf8");
  const checksumMatch = /^([0-9a-f]{64})  release-manifest\.json\n?$/.exec(checksumData);
  const manifestHash = createHash("sha256").update(manifestData).digest("hex");
  if (!checksumMatch || checksumMatch[1] !== manifestHash) throw new Error("release manifest checksum mismatch");
  const manifest = parseJSON(manifestData, "release manifest");
  validateManifest(manifest);
  if (manifest.version !== release.tag_name) throw new Error("release tag and manifest version differ");
  return {
    source: "github_release",
    version: manifest.version,
    image: manifest.image,
    digest: manifest.image_digest,
    image_ref: `${manifest.image}@${manifest.image_digest}`,
    manifest_digest: `sha256:${manifestHash}`,
  };
}

function classifyInitialURL(value) {
  if (value === latestReleaseAPI) return "metadata";
  if (assetURLPattern.test(value)) return "asset";
  throw new Error("release request URL is outside the fixed GitHub contract");
}

function validateHop(value, kind, initial) {
  let parsed;
  try { parsed = new URL(value); } catch { throw new Error("release redirect URL is invalid"); }
  if (parsed.protocol !== "https:" || parsed.username !== "" || parsed.password !== "" || parsed.hash !== "" || parsed.port !== "") {
    throw new Error("release redirect URL must be credential-free fragment-free HTTPS on the default port");
  }
  if (kind === "metadata") {
    if (parsed.href !== initial) throw new Error("release metadata redirects may not leave the exact API URL");
    return parsed.href;
  }
  if (parsed.href === initial) return parsed.href;
  if (!assetCDNHosts.has(parsed.hostname)) throw new Error("release asset redirect host is not GitHub-owned");
  return parsed.href;
}

async function readBoundedBody(response) {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^(0|[1-9][0-9]*)$/.test(contentLength)) throw new Error("release response Content-Length is invalid");
    if (Number(contentLength) > maximumBytes) throw new Error(`release response Content-Length exceeds ${maximumBytes} bytes`);
  }
  if (!response.body || typeof response.body.getReader !== "function") throw new Error("release response body is not readable");
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!(value instanceof Uint8Array)) throw new Error("release response yielded an invalid body chunk");
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      throw new Error(`release response exceeds ${maximumBytes} bytes`);
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, total);
}

export async function fetchBytes(url, options = {}) {
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const timeoutMs = options.timeoutMs ?? requestTimeoutMs;
  const maxRedirects = options.maxRedirects ?? maximumRedirects;
  const kind = classifyInitialURL(url);
  const initial = url;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(new Error(`release request timed out after ${timeoutMs}ms`)), timeoutMs);
  let current = validateHop(url, kind, initial);
  let redirects = 0;
  try {
    while (true) {
      let response;
      try {
        response = await fetchImpl(current, {
          headers: { Accept: "application/vnd.github+json", "User-Agent": "dirextalk-deployer" },
          redirect: "manual",
          signal: controller.signal,
        });
      } catch (error) {
        if (controller.signal.aborted) throw controller.signal.reason;
        throw error;
      }
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        if (kind === "metadata") throw new Error("release metadata redirects are forbidden");
        if (redirects >= maxRedirects) throw new Error("release request has too many redirects");
        const location = response.headers.get("location");
        if (!location) throw new Error("release redirect is missing Location");
        current = validateHop(new URL(location, current).href, kind, initial);
        redirects += 1;
        continue;
      }
      if (!response.ok) throw new Error(`release request failed with HTTP ${response.status}`);
      return await readBoundedBody(response);
    }
  } finally {
    clearTimeout(timeout);
  }
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  if (process.argv.length !== 3 || process.argv[2] !== "resolve-release") {
    console.error("usage: server-release-resolver.mjs resolve-release");
    process.exitCode = 2;
  } else {
    try {
      process.stdout.write(`${JSON.stringify(await resolveServerRelease(fetchBytes))}\n`);
    } catch (error) {
      console.error(error.message);
      process.exitCode = 1;
    }
  }
}
