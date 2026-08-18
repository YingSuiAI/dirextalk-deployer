import assert from "node:assert/strict";
import {
  resolveProductionRelease,
  resolveRepository,
} from "../scripts/lib/production-release-resolver.mjs";

const sha = (character) => `sha256:${character.repeat(64)}`;
const revision = (character) => character.repeat(40);

function jsonResponse(body, { status = 200, headers = {} } = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function release(version, manifestCharacter, revisionCharacter) {
  return {
    version,
    revision: revision(revisionCharacter),
    manifestDigest: sha(manifestCharacter),
    configDigest: sha(revisionCharacter),
  };
}

function registryFixture({
  repository = "dirextalk/message-server",
  latest,
  stable = latest,
  duplicateAmd64 = false,
  latestSequence,
  failToken = false,
  manifestResponseDigest,
} = {}) {
  let latestReads = 0;
  let calls = 0;
  const releases = [...new Set([latest, stable, ...(latestSequence || [])])];
  const byManifest = new Map(releases.map((item) => [item.manifestDigest, item]));
  const byConfig = new Map(releases.map((item) => [item.configDigest, item]));

  const fetchImpl = async (input) => {
    calls += 1;
    const url = new URL(String(input));
    if (url.hostname === "auth.test") {
      if (failToken) return jsonResponse({ errors: ["unavailable"] }, { status: 503 });
      return jsonResponse({ token: "fixture-token-value" });
    }

    const marker = `/v2/${repository}/`;
    if (!url.pathname.includes(marker)) return jsonResponse({}, { status: 404 });
    const route = url.pathname.slice(url.pathname.indexOf(marker) + marker.length);
    if (route === "manifests/latest") {
      const selected = latestSequence?.[Math.min(latestReads, latestSequence.length - 1)] || latest;
      latestReads += 1;
      const manifests = [{
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        digest: selected.manifestDigest,
        platform: { os: "linux", architecture: "amd64" },
      }];
      if (duplicateAmd64) manifests.push({ ...manifests[0], digest: sha("f") });
      return jsonResponse({ mediaType: "application/vnd.oci.image.index.v1+json", manifests });
    }
    if (route.startsWith("manifests/v")) {
      const version = decodeURIComponent(route.slice("manifests/".length));
      const selected = releases.find((item) => item.version === version && item === stable) ||
        releases.find((item) => item.version === version);
      if (!selected) return jsonResponse({}, { status: 404 });
      return jsonResponse({
        mediaType: "application/vnd.oci.image.index.v1+json",
        manifests: [{
          mediaType: "application/vnd.oci.image.manifest.v1+json",
          digest: selected.manifestDigest,
          platform: { os: "linux", architecture: "amd64" },
        }],
      });
    }
    if (route.startsWith("manifests/sha256:")) {
      const selected = byManifest.get(route.slice("manifests/".length));
      if (!selected) return jsonResponse({}, { status: 404 });
      return jsonResponse({
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        config: { digest: selected.configDigest },
      }, {
        headers: { "docker-content-digest": manifestResponseDigest || selected.manifestDigest },
      });
    }
    if (route.startsWith("blobs/sha256:")) {
      const selected = byConfig.get(route.slice("blobs/".length));
      if (!selected) return jsonResponse({}, { status: 404 });
      return jsonResponse({
        os: "linux",
        architecture: "amd64",
        config: { Labels: {
          "org.opencontainers.image.version": selected.version,
          "org.opencontainers.image.revision": selected.revision,
        } },
      });
    }
    return jsonResponse({}, { status: 404 });
  };
  return { fetchImpl, calls: () => calls };
}

const good = release("v1.2.3", "a", "1");
{
  const fixture = registryFixture({ latest: good });
  const result = await resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  });
  assert.deepEqual(result, {
    repository: "docker.io/dirextalk/message-server",
    version: good.version,
    source_revision: good.revision,
    manifest_digest: good.manifestDigest,
    image: `docker.io/dirextalk/message-server:${good.version}`,
    image_ref: `docker.io/dirextalk/message-server:${good.version}@${good.manifestDigest}`,
  });
}

{
  const message = release("v1.8.4", "c", "3");
  const agent = release("v2.6.1", "d", "4");
  const messageFixture = registryFixture({
    repository: "dirextalk/message-server",
    latest: message,
  });
  const agentFixture = registryFixture({
    repository: "dirextalk/agent",
    latest: agent,
  });
  const fetchImpl = (input, options) => {
    const url = new URL(String(input));
    if (url.hostname === "auth.test") {
      return jsonResponse({ token: "fixture-token-value" });
    }
    if (url.pathname.includes("/v2/dirextalk/message-server/")) {
      return messageFixture.fetchImpl(input, options);
    }
    if (url.pathname.includes("/v2/dirextalk/agent/")) {
      return agentFixture.fetchImpl(input, options);
    }
    return jsonResponse({}, { status: 404 });
  };

  const result = await resolveProductionRelease({
    fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  });
  assert.equal(result.message.version, message.version);
  assert.equal(result.message.source_revision, message.revision);
  assert.equal(result.message.manifest_digest, message.manifestDigest);
  assert.equal(result.agent.version, agent.version);
  assert.equal(result.agent.source_revision, agent.revision);
  assert.equal(result.agent.manifest_digest, agent.manifestDigest);
  assert.notEqual(result.message.version, result.agent.version);
  assert.notEqual(result.message.source_revision, result.agent.source_revision);
}

{
  const fixture = registryFixture({ latest: good, stable: release("v1.2.3", "b", "1") });
  await assert.rejects(() => resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  }), /select different linux\/amd64 manifests/);
}

{
  const fixture = registryFixture({ latest: good, duplicateAmd64: true });
  await assert.rejects(() => resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  }), /exactly one linux\/amd64 manifest/);
}

{
  const fixture = registryFixture({ latest: good, manifestResponseDigest: sha("f") });
  await assert.rejects(() => resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  }), /manifest response digest does not match its index descriptor/);
}

{
  const invalid = { ...good, version: "1.2.3" };
  const fixture = registryFixture({ latest: invalid });
  await assert.rejects(() => resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  }), /invalid org\.opencontainers\.image\.version label/);
}

{
  const invalid = { ...good, revision: "ABC" };
  const fixture = registryFixture({ latest: invalid });
  await assert.rejects(() => resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  }), /invalid org\.opencontainers\.image\.revision label/);
}

{
  const moved = release("v1.2.4", "b", "2");
  const fixture = registryFixture({ latest: good, stable: good, latestSequence: [good, moved, moved, moved] });
  const result = await resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  });
  assert.equal(result.version, moved.version);
  assert.equal(result.manifest_digest, moved.manifestDigest);
}

{
  const fixture = registryFixture({ latest: good, failToken: true });
  await assert.rejects(() => resolveRepository("dirextalk/message-server", {
    fetchImpl: fixture.fetchImpl,
    authUrl: "https://auth.test/token",
    registryUrl: "https://registry.test",
  }), /HTTP 503/);
}

await assert.rejects(() => resolveRepository("library/alpine"), /unsupported production repository/);

console.log("production release resolver ok");
