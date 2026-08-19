#!/usr/bin/env node
import { pathToFileURL } from "node:url";

const dockerAuthUrl = "https://auth.docker.io/token";
const dockerRegistryUrl = "https://registry-1.docker.io";
const manifestAccept = [
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
].join(", ");
const manifestTypes = new Set([
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
]);
const indexTypes = new Set([
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
]);
const versionPattern = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const revisionPattern = /^[0-9a-f]{40}$/;
const digestPattern = /^sha256:[0-9a-f]{64}$/;

class MovingTagError extends Error {}

function requireDigest(value, description) {
  if (!digestPattern.test(String(value || ""))) {
    throw new Error(`${description} is not a sha256 digest`);
  }
  return value;
}

async function fetchJson(fetchImpl, url, options, description) {
  const response = await fetchImpl(url, options);
  if (!response.ok) {
    const detail = (await response.text()).trim().slice(0, 300);
    throw new Error(`${description} failed with HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error(`${description} returned invalid JSON`);
  }
  return { body, headers: response.headers };
}

async function registryToken(repository, fetchImpl, authUrl) {
  const url = new URL(authUrl);
  url.searchParams.set("service", "registry.docker.io");
  url.searchParams.set("scope", `repository:${repository}:pull`);
  const { body } = await fetchJson(fetchImpl, url, undefined, `Docker Hub token request for ${repository}`);
  if (typeof body.token !== "string" || body.token.length < 16) {
    throw new Error(`Docker Hub token response for ${repository} is invalid`);
  }
  return body.token;
}

async function registryJson(repository, path, token, fetchImpl, registryUrl, accept) {
  const url = `${registryUrl}/v2/${repository}/${path}`;
  return fetchJson(fetchImpl, url, {
    headers: {
      authorization: `Bearer ${token}`,
      ...(accept ? { accept } : {}),
    },
  }, `Docker Hub read ${repository}/${path}`);
}

function platformDescriptor(index, repository, reference) {
  const matches = (Array.isArray(index.manifests) ? index.manifests : []).filter((descriptor) =>
    descriptor?.platform?.os === "linux" &&
    descriptor?.platform?.architecture === "amd64" &&
    !descriptor?.platform?.variant
  );
  if (matches.length !== 1) {
    throw new Error(`${repository}:${reference} must contain exactly one linux/amd64 manifest`);
  }
  requireDigest(matches[0].digest, `${repository}:${reference} linux/amd64 manifest digest`);
  return matches[0];
}

async function resolveTag(repository, reference, token, options) {
  const { fetchImpl, registryUrl } = options;
  const top = await registryJson(repository, `manifests/${reference}`, token, fetchImpl, registryUrl, manifestAccept);
  const topType = String(top.body.mediaType || top.headers.get("content-type") || "").split(";")[0];
  let manifest = top.body;
  let manifestDigest;

  if (indexTypes.has(topType)) {
    const descriptor = platformDescriptor(top.body, repository, reference);
    manifestDigest = descriptor.digest;
    const selected = await registryJson(repository, `manifests/${manifestDigest}`, token, fetchImpl, registryUrl, manifestAccept);
    const selectedType = String(selected.body.mediaType || selected.headers.get("content-type") || "").split(";")[0];
    if (!manifestTypes.has(selectedType)) {
      throw new Error(`${repository}:${reference} linux/amd64 descriptor is not an image manifest`);
    }
    const selectedDigest = requireDigest(
      selected.headers.get("docker-content-digest"),
      `${repository}:${reference} linux/amd64 manifest response digest`,
    );
    if (selectedDigest !== manifestDigest) {
      throw new Error(`${repository}:${reference} linux/amd64 manifest response digest does not match its index descriptor`);
    }
    manifest = selected.body;
  } else if (manifestTypes.has(topType)) {
    manifestDigest = requireDigest(top.headers.get("docker-content-digest"), `${repository}:${reference} manifest digest`);
  } else {
    throw new Error(`${repository}:${reference} has an unsupported manifest media type: ${topType || "missing"}`);
  }

  const configDigest = requireDigest(manifest?.config?.digest, `${repository}:${reference} config digest`);
  const { body: config } = await registryJson(repository, `blobs/${configDigest}`, token, fetchImpl, registryUrl);
  if (config.os !== "linux" || config.architecture !== "amd64") {
    throw new Error(`${repository}:${reference} selected manifest config is not linux/amd64`);
  }
  const labels = config?.config?.Labels;
  const version = labels?.["org.opencontainers.image.version"];
  const sourceRevision = labels?.["org.opencontainers.image.revision"];
  if (!versionPattern.test(String(version || ""))) {
    throw new Error(`${repository}:${reference} has an invalid org.opencontainers.image.version label`);
  }
  if (!revisionPattern.test(String(sourceRevision || ""))) {
    throw new Error(`${repository}:${reference} has an invalid org.opencontainers.image.revision label`);
  }
  return { manifestDigest, version, sourceRevision };
}

function sameIdentity(left, right) {
  return left.manifestDigest === right.manifestDigest &&
    left.version === right.version &&
    left.sourceRevision === right.sourceRevision;
}

async function resolveRepositoryOnce(repository, options) {
  const token = await registryToken(repository, options.fetchImpl, options.authUrl);
  const latest = await resolveTag(repository, "latest", token, options);
  const stable = await resolveTag(repository, latest.version, token, options);
  const latestCheck = await resolveTag(repository, "latest", token, options);
  const stableCheck = await resolveTag(repository, latest.version, token, options);

  if (!sameIdentity(latest, latestCheck) || !sameIdentity(stable, stableCheck)) {
    throw new MovingTagError(`${repository} release tags moved while they were being resolved`);
  }
  if (latest.manifestDigest !== stable.manifestDigest) {
    throw new Error(`${repository}:latest and ${repository}:${latest.version} select different linux/amd64 manifests`);
  }
  if (!sameIdentity(latest, stable)) {
    throw new Error(`${repository}:latest and ${repository}:${latest.version} have different release identities`);
  }

  const image = `docker.io/${repository}:${latest.version}`;
  return {
    repository: `docker.io/${repository}`,
    version: latest.version,
    source_revision: latest.sourceRevision,
    manifest_digest: latest.manifestDigest,
    image,
    image_ref: `${image}@${latest.manifestDigest}`,
  };
}

async function resolveRepositoryVersionOnce(repository, version, options) {
  const token = await registryToken(repository, options.fetchImpl, options.authUrl);
  const first = await resolveTag(repository, version, token, options);
  const second = await resolveTag(repository, version, token, options);
  if (!sameIdentity(first, second)) {
    throw new MovingTagError(`${repository}:${version} moved while it was being resolved`);
  }
  if (first.version !== version) {
    throw new Error(`${repository}:${version} image version label does not match its tag`);
  }
  const image = `docker.io/${repository}:${version}`;
  return {
    repository: `docker.io/${repository}`,
    version,
    source_revision: first.sourceRevision,
    manifest_digest: first.manifestDigest,
    image,
    image_ref: `${image}@${first.manifestDigest}`,
  };
}

export async function resolveRepository(repository, options = {}) {
  const allowed = new Set(["dirextalk/message-server", "dirextalk/agent"]);
  if (!allowed.has(repository)) throw new Error(`unsupported production repository: ${repository}`);
  const settings = {
    fetchImpl: options.fetchImpl || globalThis.fetch,
    authUrl: options.authUrl || dockerAuthUrl,
    registryUrl: options.registryUrl || dockerRegistryUrl,
    attempts: options.attempts || 3,
  };
  if (typeof settings.fetchImpl !== "function") throw new Error("Node.js fetch is unavailable");
  let lastError;
  for (let attempt = 1; attempt <= settings.attempts; attempt += 1) {
    try {
      return await resolveRepositoryOnce(repository, settings);
    } catch (error) {
      lastError = error;
      if (!(error instanceof MovingTagError) || attempt === settings.attempts) throw error;
    }
  }
  throw lastError;
}

export async function resolveRepositoryVersion(repository, version, options = {}) {
  const allowed = new Set(["dirextalk/message-server", "dirextalk/agent"]);
  if (!allowed.has(repository)) throw new Error(`unsupported production repository: ${repository}`);
  if (!versionPattern.test(String(version || ""))) {
    throw new Error(`invalid production version for ${repository}: ${version}`);
  }
  const settings = {
    fetchImpl: options.fetchImpl || globalThis.fetch,
    authUrl: options.authUrl || dockerAuthUrl,
    registryUrl: options.registryUrl || dockerRegistryUrl,
    attempts: options.attempts || 3,
  };
  if (typeof settings.fetchImpl !== "function") throw new Error("Node.js fetch is unavailable");
  let lastError;
  for (let attempt = 1; attempt <= settings.attempts; attempt += 1) {
    try {
      return await resolveRepositoryVersionOnce(repository, version, settings);
    } catch (error) {
      lastError = error;
      if (!(error instanceof MovingTagError) || attempt === settings.attempts) throw error;
    }
  }
  throw lastError;
}

export async function resolveProductionRelease(options = {}) {
  const [message, agent] = await Promise.all([
    resolveRepository("dirextalk/message-server", options),
    resolveRepository("dirextalk/agent", options),
  ]);
  return { message, agent };
}

async function main() {
  const messageVersion = process.env.DIREXTALK_PRODUCTION_RELEASE_MESSAGE_VERSION || "";
  const agentVersion = process.env.DIREXTALK_PRODUCTION_RELEASE_AGENT_VERSION || "";
  const retainMessage = process.env.DIREXTALK_PRODUCTION_RELEASE_RETAIN_MESSAGE === "true";
  const retainAgent = process.env.DIREXTALK_PRODUCTION_RELEASE_RETAIN_AGENT === "true";
  if (retainMessage && messageVersion) throw new Error("retained Message Server cannot select a version");
  if (retainAgent && agentVersion) throw new Error("retained Agent cannot select a version");
  const [message, agent] = await Promise.all([
    retainMessage ? Promise.resolve(null) : (messageVersion ? resolveRepositoryVersion("dirextalk/message-server", messageVersion) : resolveRepository("dirextalk/message-server")),
    retainAgent ? Promise.resolve(null) : (agentVersion ? resolveRepositoryVersion("dirextalk/agent", agentVersion) : resolveRepository("dirextalk/agent")),
  ]);
  const release = { message, agent };
  process.stdout.write(`${JSON.stringify(release)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`production release resolution failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
