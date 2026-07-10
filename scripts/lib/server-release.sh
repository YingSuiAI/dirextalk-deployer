#!/usr/bin/env bash
# Resolve the normal server target through a formal GitHub Release. A mutable
# MESSAGE_SERVER_IMAGE is accepted only behind the explicit debug/legacy gate.

SERVER_RELEASE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SERVER_RELEASE_SCRIPTS_DIR=$(cd "$SERVER_RELEASE_LIB_DIR/.." && pwd)
server_release_validate_override() {
  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ] && [ "${DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE:-0}" != "1" ]; then
    warn "MESSAGE_SERVER_IMAGE is a debug/legacy override and is disabled for normal production installs."
    warn "Use formal GitHub Release resolution, or explicitly set DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 for a debug/legacy deployment."
    return 1
  fi
  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ]; then
    case "$MESSAGE_SERVER_IMAGE" in
      *$'\n'*|*$'\r'*|*$'\t'*|*' '*)
        warn "MESSAGE_SERVER_IMAGE contains invalid characters for a debug/legacy image reference."
        return 1
        ;;
    esac
    if ! printf '%s' "$MESSAGE_SERVER_IMAGE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'; then
      warn "MESSAGE_SERVER_IMAGE contains invalid characters for a debug/legacy image reference."
      return 1
    fi
  fi
}

server_release_updater_binary() {
  local output
  if [ -n "${DIREXTALK_UPDATER_BINARY:-}" ]; then
    [ -x "$DIREXTALK_UPDATER_BINARY" ] || {
      warn "DIREXTALK_UPDATER_BINARY is not executable: $DIREXTALK_UPDATER_BINARY"
      return 1
    }
    printf '%s\n' "$DIREXTALK_UPDATER_BINARY"
    return 0
  fi
  : "${DIREXTALK_WORKDIR:?DIREXTALK_WORKDIR is required to build the updater}"
  output="$DIREXTALK_WORKDIR/dirextalk-updater-linux-${DIREXTALK_UPDATER_GOARCH:-amd64}"
  if [ ! -x "$output" ]; then
    bash "$SERVER_RELEASE_SCRIPTS_DIR/updater/build.sh" --output "$output" --arch "${DIREXTALK_UPDATER_GOARCH:-amd64}" || return 1
  fi
  printf '%s\n' "$output"
}

server_release_resolver_binary() {
  local output host_os host_arch extension=""
  if [ -n "${DIREXTALK_UPDATER_RESOLVER_BINARY:-}" ]; then
    [ -x "$DIREXTALK_UPDATER_RESOLVER_BINARY" ] || {
      warn "DIREXTALK_UPDATER_RESOLVER_BINARY is not executable: $DIREXTALK_UPDATER_RESOLVER_BINARY"
      return 1
    }
    printf '%s\n' "$DIREXTALK_UPDATER_RESOLVER_BINARY"
    return 0
  fi
  : "${DIREXTALK_WORKDIR:?DIREXTALK_WORKDIR is required to build the release resolver}"
  command -v go >/dev/null 2>&1 || { warn "Go is required to build the release resolver"; return 1; }
  host_os=$(go env GOOS)
  host_arch=$(go env GOARCH)
  [ "$host_os" = "windows" ] && extension=.exe
  output="$DIREXTALK_WORKDIR/dirextalk-updater-resolver-$host_os-$host_arch$extension"
  if [ ! -x "$output" ]; then
    bash "$SERVER_RELEASE_SCRIPTS_DIR/updater/build.sh" --output "$output" --os "$host_os" --arch "$host_arch" || return 1
  fi
  printf '%s\n' "$output"
}

server_release_prepare_state() {
  server_release_validate_override || return 1
  local source version image digest image_ref manifest_digest binary resolved_file resolved_json

  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ]; then
    resolved_json=$(json_build object \
      source=debug_override \
      version=debug \
      "image=$MESSAGE_SERVER_IMAGE" \
      digest= \
      "image_ref=$MESSAGE_SERVER_IMAGE" \
      manifest_digest=) || return 1
    state_set_raw server_release "$resolved_json" || return 1
    return 0
  fi

  source=$(state_get server_release.source)
  version=$(state_get server_release.version)
  image=$(state_get server_release.image)
  image_ref=$(state_get server_release.image_ref)
  digest=$(state_get server_release.digest)
  manifest_digest=$(state_get server_release.manifest_digest)
  if [ "$source" = "github_release" ] \
    && server_release_is_version "$version" \
    && [ "$image" = "dirextalk/message-server:$version" ] \
    && server_release_is_digest "$digest" \
    && server_release_is_digest "$manifest_digest" \
    && [ "$image_ref" = "$image@$digest" ]; then
    return 0
  fi

  binary=$(server_release_resolver_binary) || return 1
  resolved_file=$(mktemp)
  if ! "$binary" resolve-release > "$resolved_file"; then
    rm -f "$resolved_file"
    warn "No usable formal Dirextalk message-server GitHub Release is available."
    return 1
  fi
  if ! json_valid "$resolved_file"; then
    rm -f "$resolved_file"
    warn "The release resolver returned invalid JSON."
    return 1
  fi
  source=$(json_get "$resolved_file" source)
  version=$(json_get "$resolved_file" version)
  image=$(json_get "$resolved_file" image)
  digest=$(json_get "$resolved_file" digest)
  image_ref=$(json_get "$resolved_file" image_ref)
  manifest_digest=$(json_get "$resolved_file" manifest_digest)
  if [ "$source" != "github_release" ] \
    || ! server_release_is_version "$version" \
    || [ "$image" != "dirextalk/message-server:$version" ] \
    || ! server_release_is_digest "$digest" \
    || [ "$image_ref" != "$image@$digest" ] \
    || ! server_release_is_digest "$manifest_digest"; then
    rm -f "$resolved_file"
    warn "The release resolver returned an inconsistent immutable target."
    return 1
  fi
  resolved_json=$(cat "$resolved_file")
  rm -f "$resolved_file"
  state_set_raw server_release "$resolved_json"
}

server_release_is_version() {
  printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

server_release_is_digest() {
  printf '%s\n' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}
