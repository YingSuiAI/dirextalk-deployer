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
case "${1:-}" in
  *server-release-resolver.mjs*)
    echo "default image selection must not invoke a GitHub release resolver" >&2
    exit 97
    ;;
esac
exec "$REAL_NODE" "$@"
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
export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/server-release.sh"

server_release_prepare_state
json_test_check "$STATE_JSON" 'data.server_release.source === "default_latest" && data.server_release.version === "latest" && data.server_release.image === "dirextalk/message-server:latest" && data.server_release.image_ref === "dirextalk/message-server:latest" && data.server_release.digest === "" && data.server_release.manifest_digest === ""'

state_set server_release.image attacker/image:v1.1.0
server_release_prepare_state
json_test_check "$STATE_JSON" 'data.server_release.source === "default_latest" && data.server_release.image === "dirextalk/message-server:latest" && data.server_release.image_ref === "dirextalk/message-server:latest"'

res_set instance_id i-existing
if MESSAGE_SERVER_IMAGE=dirextalk/message-server:debug DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
  server_release_prepare_state 2>"$tmp/frozen-latest.err"; then
  echo "existing infrastructure must freeze the selected latest image" >&2
  exit 1
fi
json_test_check "$STATE_JSON" 'data.server_release.source === "default_latest" && data.server_release.image_ref === "dirextalk/message-server:latest"'

# Existing nodes created by older deployer versions remain resumable without
# performing release discovery or switching their recorded image.
state_set_raw server_release '{"source":"github_release","version":"v1.1.0","image":"dirextalk/message-server:v1.1.0","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_ref":"dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifest_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
server_release_prepare_state
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
  echo "MESSAGE_SERVER_IMAGE must not silently replace the default image policy" >&2
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

echo "server image selection ok"
