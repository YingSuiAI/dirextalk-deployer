#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export DIREXTALK_WORKDIR="$tmp/work"
export RUN_ID=ticket3-release-test
export AWS_DEFAULT_REGION=us-east-1
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
unset NODE_USE_ENV_PROXY
export DIREXTALK_RELEASE_HTTP_PROXY_INPUT=http://release-proxy.example.test:8080
export DIREXTALK_RELEASE_HTTPS_PROXY_INPUT=http://release-proxy.example.test:8080
export DIREXTALK_RELEASE_NO_PROXY_INPUT=localhost,127.0.0.1
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
aws_env_prep

mkdir -p "$tmp/bin"
export REAL_NODE=$(json_node)
cat > "$tmp/bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1##*/}" != server-release-resolver.mjs ] || [ "${2:-}" != resolve-release ]; then
  exec "$REAL_NODE" "$@"
fi
[ "${HTTP_PROXY:-}" = "http://release-proxy.example.test:8080" ] || {
  echo "release resolver must receive the original HTTP proxy" >&2
  exit 97
}
[ "${HTTPS_PROXY:-}" = "http://release-proxy.example.test:8080" ] || {
  echo "release resolver must receive the original HTTPS proxy" >&2
  exit 97
}
[ "${NO_PROXY:-}" = "localhost,127.0.0.1" ] || {
  echo "release resolver must receive the original NO_PROXY value" >&2
  exit 97
}
[ "${NODE_USE_ENV_PROXY:-}" = "1" ] || {
  echo "release resolver must enable Node proxy support when a proxy is configured" >&2
  exit 97
}
cat <<'JSON'
{
  "source": "github_release",
  "version": "v1.1.0",
  "image": "dirextalk/message-server:v1.1.0",
  "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "image_ref": "dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "manifest_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
JSON
EOF
cat > "$tmp/bin/go" <<'EOF'
#!/usr/bin/env bash
echo "server release resolution must not require local Go" >&2
exit 99
EOF
cat > "$tmp/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
echo "server release resolution must not depend on a shell temp path" >&2
exit 98
EOF
chmod 0755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
# Git Bash can resolve a native node.exe before an extensionless shim on PATH.
# Pin the JSON/runtime selector to the shim so this test is fully offline.
export NODE="$tmp/bin/node"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/server-release.sh"

server_release_prepare_state
json_test_check "$STATE_JSON" 'data.server_release.source === "github_release" && data.server_release.version === "v1.1.0" && data.server_release.image === "dirextalk/message-server:v1.1.0" && data.server_release.digest === "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && data.server_release.image_ref === "dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && data.server_release.manifest_digest === "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'

state_set server_release.image attacker/image:v1.1.0
server_release_prepare_state
json_test_check "$STATE_JSON" 'data.server_release.image === "dirextalk/message-server:v1.1.0" && data.server_release.image_ref === "dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'

res_set instance_id i-existing
if MESSAGE_SERVER_IMAGE=dirextalk/message-server:debug DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
  server_release_prepare_state 2>"$tmp/frozen-formal.err"; then
  echo "existing infrastructure must freeze the formal release choice" >&2
  exit 1
fi
json_test_check "$STATE_JSON" 'data.server_release.source === "github_release" && data.server_release.version === "v1.1.0"'

res_set instance_id ""
state_set_raw server_release '{}'
MESSAGE_SERVER_IMAGE=dirextalk/message-server:debug DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
  server_release_prepare_state
res_set instance_id i-debug-existing
unset MESSAGE_SERVER_IMAGE DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE
server_release_prepare_state
json_test_check "$STATE_JSON" 'data.server_release.source === "debug_override" && data.server_release.image_ref === "dirextalk/message-server:debug"'
if MESSAGE_SERVER_IMAGE=dirextalk/message-server:other DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
  server_release_prepare_state 2>"$tmp/frozen-debug.err"; then
  echo "existing infrastructure must reject a different debug override" >&2
  exit 1
fi

state_set_raw server_release '{}'
res_set instance_id ""
if MESSAGE_SERVER_IMAGE=dirextalk/message-server:latest server_release_prepare_state 2>"$tmp/override.err"; then
  echo "MESSAGE_SERVER_IMAGE must not silently bypass formal release resolution" >&2
  exit 1
fi
grep -q 'DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1' "$tmp/override.err"

if MESSAGE_SERVER_IMAGE=$'dirextalk/message-server:debug\nINJECTED=true' \
  DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
  server_release_prepare_state 2>"$tmp/invalid-override.err"; then
  echo "debug image override must reject multiline or shell-sensitive input" >&2
  exit 1
fi

MESSAGE_SERVER_IMAGE=dirextalk/message-server:debug \
  DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
  server_release_prepare_state
json_test_check "$STATE_JSON" 'data.server_release.source === "debug_override" && data.server_release.image === "dirextalk/message-server:debug" && data.server_release.image_ref === "dirextalk/message-server:debug" && data.server_release.digest === "" && data.server_release.manifest_digest === ""'

echo "server release resolution ok"
