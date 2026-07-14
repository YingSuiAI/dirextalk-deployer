import {
  validateWorkerBootstrapManifest,
} from "./worker-contract.mjs";

const MANIFEST_PATH = "/etc/dirextalk-cloud-worker/bootstrap-manifest.json";
const ENVIRONMENT_PATH = "/etc/dirextalk-cloud-worker/bootstrap.env";
const SERVICE_NAME = "dirextalk-cloud-worker.service";
const MAX_BOOTSTRAP_LIFETIME_MS = 10 * 60 * 1000;

function requireSession(session) {
  if (!session || typeof session !== "object" || Array.isArray(session)) {
    throw new TypeError("a worker bootstrap session is required");
  }
  return session;
}

function decodeSafeScriptPayload(value) {
  return Buffer.from(value, "utf8").toString("base64");
}

function bootstrapManifest(session, nowMs) {
  const source = requireSession(session);
  return validateWorkerBootstrapManifest({
    schema: "dirextalk.worker-bootstrap/v1",
    connection_id: source.connection_id,
    deployment_id: source.deployment_id,
    bootstrap_session_id: source.bootstrap_session_id,
    bootstrap_endpoint: source.bootstrap_endpoint,
    worker_image_digest: source.worker_image_digest,
    artifact_manifest_digest: source.artifact_manifest_digest,
    expires_at: source.expires_at,
  }, {
    nowMs,
    maxLifetimeMs: MAX_BOOTSTRAP_LIFETIME_MS,
    expectedConnectionId: source.connection_id,
    expectedBootstrapEndpoint: source.bootstrap_endpoint,
  });
}

// The fixed Worker AMI owns the systemd unit. This Stack-generated cloud-init
// payload only writes the strict non-secret bootstrap manifest/environment and
// restarts that fixed unit. It intentionally has no caller command, token,
// AWS credential, or mutable image reference.
export function buildWorkerBootstrapUserData(session, { nowMs } = {}) {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
    throw new TypeError("a valid bootstrap clock is required");
  }
  const manifest = bootstrapManifest(session, nowMs);
  const manifestBase64 = decodeSafeScriptPayload(`${JSON.stringify(manifest)}\n`);
  const environmentBase64 = decodeSafeScriptPayload([
    `CLOUD_WORKER_BOOTSTRAP_MANIFEST_FILE=${MANIFEST_PATH}`,
    `CLOUD_WORKER_EXPECTED_CONNECTION_ID=${manifest.connection_id}`,
    `CLOUD_WORKER_EXPECTED_BOOTSTRAP_ENDPOINT=${manifest.bootstrap_endpoint}`,
    "",
  ].join("\n"));
  const script = [
    "#!/bin/sh",
    "set -eu",
    "install -d -o root -g root -m 0755 /etc/dirextalk-cloud-worker",
    `printf '%s' '${manifestBase64}' | base64 --decode > ${MANIFEST_PATH}.tmp`,
    `chmod 0644 ${MANIFEST_PATH}.tmp`,
    `mv ${MANIFEST_PATH}.tmp ${MANIFEST_PATH}`,
    `printf '%s' '${environmentBase64}' | base64 --decode > ${ENVIRONMENT_PATH}.tmp`,
    `chmod 0644 ${ENVIRONMENT_PATH}.tmp`,
    `mv ${ENVIRONMENT_PATH}.tmp ${ENVIRONMENT_PATH}`,
    `systemctl restart ${SERVICE_NAME}`,
    "",
  ].join("\n");
  return Buffer.from(script, "utf8").toString("base64");
}

export const WORKER_BOOTSTRAP_MANIFEST_PATH = MANIFEST_PATH;
export const WORKER_BOOTSTRAP_ENVIRONMENT_PATH = ENVIRONMENT_PATH;
export const WORKER_BOOTSTRAP_SERVICE_NAME = SERVICE_NAME;
