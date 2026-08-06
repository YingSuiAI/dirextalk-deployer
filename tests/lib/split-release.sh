#!/usr/bin/env bash

dirextalk_test_prepare_split_release() {
  local root=$1 bundle_root bundle sha_file
  unset MESSAGE_SERVER_IMAGE DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE
  # shellcheck disable=SC1090
  source "$ROOT/scripts/cloud-init/split/release.env"
  export DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE DIREXTALK_AGENT_IMAGE_IMMUTABLE
  export DIREXTALK_CADDY_IMAGE_IMMUTABLE DIREXTALK_MESSAGE_SOURCE_REVISION
  export DIREXTALK_COTURN_IMAGE_IMMUTABLE
  export DIREXTALK_SPLIT_SOURCE_REVISION DIREXTALK_AGENT_SOURCE_REVISION

  bundle_root=$root/split-bundle-root
  mkdir -p "$bundle_root/deploy/split-agent"
  printf '%s\n' "$DIREXTALK_SPLIT_SOURCE_REVISION" >"$bundle_root/deploy/split-agent/SOURCE_REVISION"
  printf 'fixture\n' >"$bundle_root/deploy/split-agent/compose.yaml"
  bundle=$root/canonical-bundle.tar.gz
  tar -C "$bundle_root" -czf "$bundle" deploy
  sha_file=$bundle.sha256
  sha256sum "$bundle" >"$sha_file"
  export DIREXTALK_SPLIT_BUNDLE_FILE=$bundle
  export DIREXTALK_SPLIT_BUNDLE_SHA256_FILE=$sha_file
}
