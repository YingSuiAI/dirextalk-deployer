#!/usr/bin/env bash

dirextalk_test_prepare_split_release() {
  local root=$1 bundle_root bundle sha_file resolver
  unset MESSAGE_SERVER_IMAGE DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE
  # shellcheck disable=SC1090
  source "$ROOT/scripts/cloud-init/split/release.env"
  DIREXTALK_MESSAGE_SERVER_VERSION=v1.1.62
  DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.62
  DIREXTALK_MESSAGE_SOURCE_REVISION=725933abea4d4de42a07cd937e65a4d94098c007
  DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  DIREXTALK_AGENT_VERSION=v1.0.162
  DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.162
  DIREXTALK_AGENT_SOURCE_REVISION=6d0461c71178c1b087314ecca30ba0fa7047f06d
  DIREXTALK_AGENT_MANIFEST_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export DIREXTALK_MESSAGE_SERVER_IMAGE DIREXTALK_AGENT_IMAGE
  export DIREXTALK_MESSAGE_SERVER_VERSION DIREXTALK_AGENT_VERSION
  export DIREXTALK_POSTGRES_IMAGE_IMMUTABLE
  export DIREXTALK_CADDY_IMAGE_IMMUTABLE DIREXTALK_MESSAGE_SOURCE_REVISION
  export DIREXTALK_COTURN_IMAGE_IMMUTABLE
  export DIREXTALK_RELEASE_CATALOG_ORIGIN
  export DIREXTALK_SPLIT_SOURCE_REVISION DIREXTALK_AGENT_SOURCE_REVISION
  export DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST DIREXTALK_AGENT_MANIFEST_DIGEST

  resolver=$root/production-release-resolver.mjs
  cat >"$resolver" <<EOF
process.stdout.write(JSON.stringify({
  message: { version: "$DIREXTALK_MESSAGE_SERVER_VERSION", image: "$DIREXTALK_MESSAGE_SERVER_IMAGE", image_ref: "$DIREXTALK_MESSAGE_SERVER_IMAGE@$DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST", source_revision: "$DIREXTALK_MESSAGE_SOURCE_REVISION", manifest_digest: "$DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST" },
  agent: { version: "$DIREXTALK_AGENT_VERSION", image: "$DIREXTALK_AGENT_IMAGE", image_ref: "$DIREXTALK_AGENT_IMAGE@$DIREXTALK_AGENT_MANIFEST_DIGEST", source_revision: "$DIREXTALK_AGENT_SOURCE_REVISION", manifest_digest: "$DIREXTALK_AGENT_MANIFEST_DIGEST" }
}) + "\\n");
EOF
  export DIREXTALK_PRODUCTION_RELEASE_RESOLVER=$resolver

  bundle_root=$root/split-bundle-root
  mkdir -p "$bundle_root/deploy/split-agent/scripts"
  printf '%s\n' "$DIREXTALK_SPLIT_SOURCE_REVISION" >"$bundle_root/deploy/split-agent/SOURCE_REVISION"
  printf 'fixture\n' >"$bundle_root/deploy/split-agent/compose.yaml"
  printf 'services: {}\n' >"$bundle_root/deploy/split-agent/compose.production.yaml"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle_root/deploy/split-agent/scripts/prepare-agent-start-local.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle_root/deploy/split-agent/scripts/refresh-message-mcp-token.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle_root/deploy/split-agent/scripts/update-message-server-local.sh"
  chmod 0755 \
    "$bundle_root/deploy/split-agent/scripts/prepare-agent-start-local.sh" \
    "$bundle_root/deploy/split-agent/scripts/refresh-message-mcp-token.sh" \
    "$bundle_root/deploy/split-agent/scripts/update-message-server-local.sh"
  (cd "$bundle_root/deploy/split-agent" && find . -type f ! -name SOURCE_FILES.sha256 -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum >SOURCE_FILES.sha256)
  bundle=$root/canonical-bundle.tar.gz
  tar -C "$bundle_root" -czf "$bundle" deploy
  sha_file=$bundle.sha256
  sha256sum "$bundle" >"$sha_file"
  export DIREXTALK_SPLIT_BUNDLE_FILE=$bundle
  export DIREXTALK_SPLIT_BUNDLE_SHA256_FILE=$sha_file
}
