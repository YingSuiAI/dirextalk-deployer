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
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null

mkdir -p "$tmp/bin"
export REAL_NODE=$(json_node)
cat > "$tmp/bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1##*/}" != server-release-resolver.mjs ] || [ "${2:-}" != resolve-release ]; then
  exec "$REAL_NODE" "$@"
fi
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
chmod 0755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

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
