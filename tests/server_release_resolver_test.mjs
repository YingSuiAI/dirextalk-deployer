import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { resolveServerRelease } from "../scripts/lib/server-release-resolver.mjs";

const api = "https://api.github.com/repos/YingSuiAI/dirextalk-message-server/releases/latest";
const manifestURL = "https://github.com/YingSuiAI/dirextalk-message-server/releases/download/v1.1.0/release-manifest.json";
const checksumURL = `${manifestURL}.sha256`;

function manifest(overrides = {}) {
  return {
    manifest_version: 1,
    version: "v1.1.0",
    image: "dirextalk/message-server:v1.1.0",
    image_digest: `sha256:${"a".repeat(64)}`,
    upgrade_from: [">=v1.0.0 <v1.1.0"],
    schema_version: 2,
    schema_compat_version: 1,
    minimum_client_version: "v1.0.0",
    maximum_client_version_exclusive: "v2.0.0",
    backup_required: true,
    rollback_supported: true,
    rollback_mode: "restore_backup",
    release_notes_url: "https://github.com/YingSuiAI/dirextalk-message-server/releases/tag/v1.1.0",
    ...overrides,
  };
}

function fixture({ release = {}, manifest: manifestOverrides = {}, rawManifest, checksum } = {}) {
  const manifestBytes = Buffer.from(rawManifest ?? `${JSON.stringify(manifest(manifestOverrides))}\n`);
  const digest = createHash("sha256").update(manifestBytes).digest("hex");
  const releaseBody = {
    tag_name: "v1.1.0",
    draft: false,
    prerelease: false,
    assets: [
      { name: "release-manifest.json", browser_download_url: manifestURL },
      { name: "release-manifest.json.sha256", browser_download_url: checksumURL },
    ],
    ...release,
  };
  const values = new Map([
    [api, Buffer.from(JSON.stringify(releaseBody))],
    [manifestURL, manifestBytes],
    [checksumURL, Buffer.from(checksum ?? `${digest}  release-manifest.json\n`)],
  ]);
  const calls = [];
  return {
    calls,
    get: async (url) => {
      calls.push(url);
      if (!values.has(url)) throw new Error(`unexpected URL: ${url}`);
      return values.get(url);
    },
  };
}

{
  const fake = fixture();
  const resolved = await resolveServerRelease(fake.get);
  assert.deepEqual(fake.calls, [api, manifestURL, checksumURL]);
  assert.equal(resolved.source, "github_release");
  assert.equal(resolved.version, "v1.1.0");
  assert.equal(resolved.image, "dirextalk/message-server:v1.1.0");
  assert.equal(resolved.digest, `sha256:${"a".repeat(64)}`);
  assert.equal(resolved.image_ref, `${resolved.image}@${resolved.digest}`);
  assert.match(resolved.manifest_digest, /^sha256:[0-9a-f]{64}$/);
}

for (const upgradeFrom of [
  ["~v1.0.0"],
  ["^v0.9.0"],
  ["v0.x"],
  ["v0.9.0 - v1.0.9"],
]) {
  const fake = fixture({ manifest: { upgrade_from: upgradeFrom } });
  await resolveServerRelease(fake.get);
}

const rejected = [
  fixture({ release: { draft: true } }),
  fixture({ release: { prerelease: true } }),
  fixture({ release: { tag_name: "latest" } }),
  fixture({ release: { assets: [] } }),
  fixture({ release: { assets: [
    { name: "release-manifest.json", browser_download_url: manifestURL },
    { name: "release-manifest.json", browser_download_url: manifestURL },
    { name: "release-manifest.json.sha256", browser_download_url: checksumURL },
  ] } }),
  fixture({ release: { assets: [
    { name: "release-manifest.json", browser_download_url: "https://attacker.example/release-manifest.json" },
    { name: "release-manifest.json.sha256", browser_download_url: checksumURL },
  ] } }),
  fixture({ checksum: `${"0".repeat(64)}  release-manifest.json\n` }),
  fixture({ manifest: { shell: "attacker" } }),
  fixture({ manifest: { image: "attacker/image:v1.1.0" } }),
  fixture({ manifest: { image_digest: `sha256:${"A".repeat(64)}` } }),
  fixture({ manifest: { upgrade_from: [""] } }),
  fixture({ manifest: { upgrade_from: [">=v1.0.0", ">=v1.0.0"] } }),
  fixture({ manifest: { upgrade_from: [1] } }),
  fixture({ manifest: { schema_compat_version: 3 } }),
  fixture({ manifest: { minimum_client_version: "1.0.0" } }),
  fixture({ manifest: { release_notes_url: "https://attacker.example/v1.1.0" } }),
];
for (const fake of rejected) {
  await assert.rejects(() => resolveServerRelease(fake.get));
}

console.log("server release node resolver ok");
