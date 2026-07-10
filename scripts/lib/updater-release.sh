#!/usr/bin/env bash
# Frozen independent dirextalk-updater Release consumed by this deployer.

UPDATER_RELEASE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$UPDATER_RELEASE_LIB_DIR/../updater/release.env"

updater_release_validate_pin() {
  printf '%s\n' "$UPDATER_PIN_VERSION" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || return 1
  printf '%s\n' "$UPDATER_PIN_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || return 1
  printf '%s\n' "$UPDATER_PIN_SHA256" | grep -Eq '^[0-9a-f]{64}$' || return 1
  [ "$UPDATER_PIN_ASSET" = dirextalk-updater-linux-amd64 ] || return 1
  [ "$UPDATER_PIN_OS" = linux ] && [ "$UPDATER_PIN_ARCH" = amd64 ] && [ "$UPDATER_PIN_UBUNTU_VERSION" = 24.04 ] || return 1
  [ "$UPDATER_PIN_URL" = "https://github.com/YingSuiAI/dirextalk-updater/releases/download/$UPDATER_PIN_VERSION/$UPDATER_PIN_ASSET" ] || return 1
}

updater_release_record_state() {
  updater_release_validate_pin || {
    warn "The deployer-owned updater Release pin is invalid."
    return 1
  }
  local release_json
  release_json=$(json_build object \
    "version=$UPDATER_PIN_VERSION" \
    "commit=$UPDATER_PIN_COMMIT" \
    "url=$UPDATER_PIN_URL" \
    "asset=$UPDATER_PIN_ASSET" \
    "sha256=$UPDATER_PIN_SHA256" \
    "os=$UPDATER_PIN_OS" \
    "arch=$UPDATER_PIN_ARCH" \
    "ubuntu_version=$UPDATER_PIN_UBUNTU_VERSION") || return 1
  state_set_raw updater_release "$release_json"
}
