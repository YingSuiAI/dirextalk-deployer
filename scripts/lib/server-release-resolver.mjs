#!/usr/bin/env node
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const latestReleaseAPI = "https://api.github.com/repos/YingSuiAI/dirextalk-message-server/releases/latest";
const manifestAsset = "release-manifest.json";
const checksumAsset = `${manifestAsset}.sha256`;
const allowedImage = "dirextalk/message-server";
const maximumBytes = 1024 * 1024;
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

function comparatorMatches(version, token) {
  const match = /^(<=|>=|<|>|=)?(v?(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$/.exec(token);
  if (!match) throw new Error(`unsupported upgrade_from comparator: ${token}`);
  const target = parseVersion(match[2].startsWith("v") ? match[2] : `v${match[2]}`, "upgrade_from version");
  const comparison = compareVersion(version, target);
  switch (match[1] || "=") {
    case "<": return comparison < 0;
    case "<=": return comparison <= 0;
    case ">": return comparison > 0;
    case ">=": return comparison >= 0;
    default: return comparison === 0;
  }
}

function constraintMatches(version, constraint) {
  const groups = constraint.split("||").map((group) => group.trim()).filter(Boolean);
  if (groups.length === 0) throw new Error("upgrade_from constraint is empty");
  return groups.some((group) => {
    const tokens = group.replaceAll(",", " ").split(/\s+/).filter(Boolean);
    if (tokens.length === 0) throw new Error("upgrade_from constraint is empty");
    return tokens.every((token) => comparatorMatches(version, token));
  });
}

function validateManifest(manifest) {
  for (const field of Object.keys(manifest)) {
    if (!manifestFields.has(field)) throw new Error(`release manifest contains unknown field ${field}`);
  }
  if (Object.keys(manifest).length !== manifestFields.size || manifest.manifest_version !== 1) throw new Error("release manifest fields/version are invalid");
  const target = parseVersion(manifest.version, "manifest version");
  if (manifest.image !== `${allowedImage}:${manifest.version}`) throw new Error("release manifest image is inconsistent");
  if (!digestPattern.test(manifest.image_digest)) throw new Error("release manifest image_digest is invalid");
  if (!Array.isArray(manifest.upgrade_from) || manifest.upgrade_from.some((value) => typeof value !== "string" || constraintMatches(target, value))) {
    throw new Error("release manifest upgrade_from is invalid or includes the target");
  }
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

async function fetchBytes(url) {
  const response = await fetch(url, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "dirextalk-deployer" },
    redirect: "follow",
  });
  if (!response.ok) throw new Error(`release request failed with HTTP ${response.status}`);
  const data = Buffer.from(await response.arrayBuffer());
  if (data.length > maximumBytes) throw new Error(`release response exceeds ${maximumBytes} bytes`);
  return data;
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
