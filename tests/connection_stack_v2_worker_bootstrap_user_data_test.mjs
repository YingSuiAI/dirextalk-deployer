import assert from "node:assert/strict";

import {
  WORKER_BOOTSTRAP_ENVIRONMENT_PATH,
  WORKER_BOOTSTRAP_MANIFEST_PATH,
  WORKER_BOOTSTRAP_SERVICE_NAME,
  buildWorkerBootstrapUserData,
} from "../scripts/connection-stack-v2/src/worker-bootstrap-user-data.mjs";

const NOW = Date.parse("2026-07-15T01:00:00.000Z");
const DIGEST = `sha256:${"a".repeat(64)}`;
const session = {
  connection_id: "connection-v2-0001",
  deployment_id: "deployment-v2-001",
  bootstrap_session_id: "worker-session-v2-001",
  bootstrap_endpoint: "https://a1b2c3d4e5.execute-api.ap-northeast-1.amazonaws.com/prod/v2/worker-sessions",
  worker_image_digest: DIGEST,
  artifact_manifest_digest: DIGEST,
  expires_at: "2026-07-15T01:10:00.000Z",
};

const script = Buffer.from(buildWorkerBootstrapUserData(session, { nowMs: NOW }), "base64").toString("utf8");
assert.match(script, /^#!\/bin\/sh\nset -eu\n/);
assert.match(script, new RegExp(`systemctl restart ${WORKER_BOOTSTRAP_SERVICE_NAME}`));
assert.match(script, new RegExp(`${WORKER_BOOTSTRAP_MANIFEST_PATH.replaceAll("/", "\\/")}\\.tmp`));
assert.match(script, new RegExp(`${WORKER_BOOTSTRAP_ENVIRONMENT_PATH.replaceAll("/", "\\/")}\\.tmp`));
assert.ok(!script.includes("access_token"), "cloud-init must not carry a worker bearer token");
assert.ok(!script.includes("aws_access_key"), "cloud-init must not carry cloud credentials");

const encodedManifest = script.match(/printf '%s' '([A-Za-z0-9+/=]+)' \| base64 --decode > \/etc\/dirextalk-cloud-worker\/bootstrap-manifest\.json\.tmp/)?.[1];
assert.ok(encodedManifest, "UserData must contain only the fixed manifest payload");
assert.deepEqual(JSON.parse(Buffer.from(encodedManifest, "base64").toString("utf8")), {
  schema: "dirextalk.worker-bootstrap/v1",
  connection_id: session.connection_id,
  deployment_id: session.deployment_id,
  bootstrap_session_id: session.bootstrap_session_id,
  bootstrap_endpoint: session.bootstrap_endpoint,
  worker_image_digest: DIGEST,
  artifact_manifest_digest: DIGEST,
  expires_at: session.expires_at,
});

assert.throws(
  () => buildWorkerBootstrapUserData({ ...session, bootstrap_endpoint: "http://example.invalid/v2/worker-sessions" }, { nowMs: NOW }),
  (error) => error?.code === "invalid_worker_manifest",
  "the Stack must never write an unencrypted or redirectable bootstrap endpoint into an EC2 VM",
);

console.log("connection stack v2 worker bootstrap user data boundary ok");
