#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export DIREXTALK_WORKDIR="$tmp/work"
export RUN_ID=production-split-release-test
export AWS_DEFAULT_REGION=ap-east-1
export TEST_RESOLVER_CALLS="$tmp/resolver-calls"
export DIREXTALK_PRODUCTION_RELEASE_RESOLVER="$tmp/resolver.mjs"
cat >"$DIREXTALK_PRODUCTION_RELEASE_RESOLVER" <<'EOF'
import { appendFileSync } from "node:fs";
appendFileSync(process.env.TEST_RESOLVER_CALLS, "resolve\n");
const digest = (value) => `sha256:${value.repeat(64)}`;
process.stdout.write(JSON.stringify({
  message: {
    version: "v1.2.3",
    image: "docker.io/dirextalk/message-server:v1.2.3",
    image_ref: `docker.io/dirextalk/message-server:v1.2.3@${digest("a")}`,
    source_revision: "1".repeat(40),
    manifest_digest: digest("a")
  },
  agent: {
    version: "v2.3.4",
    image: "docker.io/dirextalk/agent:v2.3.4",
    image_ref: `docker.io/dirextalk/agent:v2.3.4@${digest("b")}`,
    source_revision: "2".repeat(40),
    manifest_digest: digest("b")
  }
}) + "\n");
EOF

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null
warn() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/server-release.sh"

server_release_validate_pin
if grep -Eq '^DIREXTALK_(MESSAGE_SERVER|MESSAGE_SOURCE|AGENT_)' "$SERVER_RELEASE_PIN"; then
  echo 'repository release settings still contain application pins' >&2
  exit 1
fi

# First fresh pass resolves exactly once and atomically records both receipts.
server_release_prepare_state
[ "$(wc -l <"$TEST_RESOLVER_CALLS")" -eq 1 ]
message_digest=sha256:$(printf 'a%.0s' {1..64})
agent_digest=sha256:$(printf 'b%.0s' {1..64})
json_test_check "$STATE_JSON" "data.server_release.source === 'production_split' && data.server_release.version === 'v1.2.3' && data.server_release.image === 'docker.io/dirextalk/message-server:v1.2.3' && data.server_release.image_ref === data.server_release.image && data.server_release.digest === '$message_digest' && data.server_release.manifest_digest === '$message_digest'"
json_test_check "$STATE_JSON" "data.split_release.message_version === 'v1.2.3' && data.split_release.message_image === 'docker.io/dirextalk/message-server:v1.2.3' && data.split_release.message_source_revision === '${DIREXTALK_MESSAGE_SOURCE_REVISION}' && data.split_release.message_manifest_digest === '$message_digest' && data.split_release.agent_version === 'v2.3.4' && data.split_release.agent_image === 'docker.io/dirextalk/agent:v2.3.4' && data.split_release.agent_manifest_digest === '$agent_digest'"
json_test_check "$STATE_JSON" "data.split_release.split_source_revision === '$DIREXTALK_SPLIT_SOURCE_REVISION' && data.split_release.postgres_image === '$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE' && data.split_release.caddy_image === '$DIREXTALK_CADDY_IMAGE_IMMUTABLE' && data.split_release.coturn_image === '$DIREXTALK_COTURN_IMAGE_IMMUTABLE'"

# A fresh retry reuses the complete frozen snapshot without registry access.
server_release_prepare_state
[ "$(wc -l <"$TEST_RESOLVER_CALLS")" -eq 1 ]
[ "$DIREXTALK_MESSAGE_SERVER_VERSION" = v1.2.3 ]
[ "$DIREXTALK_AGENT_VERSION" = v2.3.4 ]

# Existing infrastructure preserves its recorded application release while the
# Deployer-owned split source can advance.
res_set instance_id i-existing
old_split_revision=1111111111111111111111111111111111111111
state_set split_release.split_source_revision "$old_split_revision"
state_set split_release.message_version v8.8.8
state_set split_release.message_image docker.io/dirextalk/message-server:v8.8.8
state_set split_release.message_source_revision 8888888888888888888888888888888888888888
state_set split_release.message_manifest_digest "sha256:$(printf '8%.0s' {1..64})"
state_set server_release.version v8.8.8
state_set server_release.image docker.io/dirextalk/message-server:v8.8.8
state_set server_release.image_ref docker.io/dirextalk/message-server:v8.8.8
state_set server_release.digest "sha256:$(printf '8%.0s' {1..64})"
state_set server_release.manifest_digest "sha256:$(printf '8%.0s' {1..64})"
state_set split_release.agent_version v9.9.9
state_set split_release.agent_image docker.io/dirextalk/agent:v9.9.9
state_set split_release.agent_source_revision 9999999999999999999999999999999999999999
state_set split_release.agent_manifest_digest "sha256:$(printf '9%.0s' {1..64})"
server_release_prepare_state
[ "$(wc -l <"$TEST_RESOLVER_CALLS")" -eq 1 ]
[ "$DIREXTALK_MESSAGE_SERVER_VERSION" = v8.8.8 ]
[ "$DIREXTALK_AGENT_VERSION" = v9.9.9 ]
server_release_advance_split_state "$old_split_revision"
[ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ]
[ "$(state_get split_release.message_version)" = v8.8.8 ]
[ "$(state_get split_release.agent_version)" = v9.9.9 ]

# Resolver failure cannot leave either half of the release snapshot behind.
export DIREXTALK_WORKDIR="$tmp/failure"
STATE_JSON="$DIREXTALK_WORKDIR/state.json"
state_init >/dev/null
cat >"$tmp/failing-resolver.mjs" <<'EOF'
process.stderr.write("registry unavailable\n");
process.exitCode = 1;
EOF
SERVER_RELEASE_RESOLVER="$tmp/failing-resolver.mjs"
if server_release_prepare_state >/dev/null 2>&1; then
  echo 'fresh release resolution accepted a registry failure' >&2
  exit 1
fi
[ -z "$(state_get server_release)" ]
[ -z "$(state_get split_release)" ]

# A partial receipt is a local failure and is never repaired by another read.
state_set_raw server_release '{}'
SERVER_RELEASE_RESOLVER="$DIREXTALK_PRODUCTION_RELEASE_RESOLVER"
calls_before=$(wc -l <"$TEST_RESOLVER_CALLS")
if server_release_prepare_state >/dev/null 2>&1; then
  echo 'fresh release accepted a partial frozen snapshot' >&2
  exit 1
fi
[ "$(wc -l <"$TEST_RESOLVER_CALLS")" -eq "$calls_before" ]

for variable in MESSAGE_SERVER_IMAGE DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE; do
  if env "$variable=forbidden" bash -c '
    set -euo pipefail
    warn() { printf "%s\n" "$*" >&2; }
    source "$1/scripts/lib/json.sh"
    source "$1/scripts/lib/state.sh"
    source "$1/scripts/lib/server-release.sh"
    server_release_validate_override
  ' bash "$ROOT" 2>"$tmp/override.err"; then
    echo "$variable override was accepted" >&2
    exit 1
  fi
done

echo "production split dynamic release ok"
