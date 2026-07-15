#!/usr/bin/env bash
# Select the normal server target without a release-discovery network request.
# MESSAGE_SERVER_IMAGE remains an explicit debug/legacy override.

DEFAULT_MESSAGE_SERVER_IMAGE=dirextalk/message-server:latest

server_release_validate_override() {
  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ] && [ "${DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE:-0}" != "1" ]; then
    warn "MESSAGE_SERVER_IMAGE is a debug/legacy override and is disabled for normal production installs."
    warn "Use the default latest image, or explicitly set DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 for a debug/legacy deployment."
    return 1
  fi
  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ]; then
    if ! server_release_image_is_safe "$MESSAGE_SERVER_IMAGE"; then
      warn "MESSAGE_SERVER_IMAGE contains invalid characters for a debug/legacy image reference."
      return 1
    fi
  fi
}

server_release_image_is_safe() {
  case "${1:-}" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
}

server_release_state_is_default_latest() {
  local source=$1 version=$2 image=$3 digest=$4 image_ref=$5 manifest_digest=$6
  [ "$source" = "default_latest" ] \
    && [ "$version" = "latest" ] \
    && [ "$image" = "$DEFAULT_MESSAGE_SERVER_IMAGE" ] \
    && [ "$image_ref" = "$DEFAULT_MESSAGE_SERVER_IMAGE" ] \
    && [ -z "$digest" ] \
    && [ -z "$manifest_digest" ]
}

server_release_state_is_formal() {
  local source=$1 version=$2 image=$3 digest=$4 image_ref=$5 manifest_digest=$6
  [ "$source" = "github_release" ] \
    && server_release_is_version "$version" \
    && [ "$image" = "dirextalk/message-server:$version" ] \
    && server_release_is_digest "$digest" \
    && server_release_is_digest "$manifest_digest" \
    && [ "$image_ref" = "$image@$digest" ]
}

server_release_state_is_debug() {
  local source=$1 version=$2 image=$3 digest=$4 image_ref=$5 manifest_digest=$6
  [ "$source" = "debug_override" ] \
    && [ "$version" = "debug" ] \
    && server_release_image_is_safe "$image" \
    && [ "$image_ref" = "$image" ] \
    && [ -z "$digest" ] \
    && [ -z "$manifest_digest" ]
}

server_release_state_is_legacy_adopted() {
  local source=$1 version=$2 image=$3 digest=$4 image_ref=$5
  local approved=sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c
  [ "$source" = legacy_adopted ] \
    && [ "$version" = v0.15.2 ] \
    && [ "$image" = dirextalk/message-server:v0.15.2 ] \
    && [ "$digest" = "$approved" ] \
    && [ "$image_ref" = "$image@$digest" ]
}

server_release_prepare_state() {
  server_release_validate_override || return 1
  local source version image digest image_ref manifest_digest resolved_json instance_id

  source=$(state_get server_release.source)
  version=$(state_get server_release.version)
  image=$(state_get server_release.image)
  image_ref=$(state_get server_release.image_ref)
  digest=$(state_get server_release.digest)
  manifest_digest=$(state_get server_release.manifest_digest)
  instance_id=$(state_get resources.instance_id)

  if [ -n "$instance_id" ]; then
    if server_release_state_is_default_latest "$source" "$version" "$image" "$digest" "$image_ref" "$manifest_digest"; then
      if [ -z "${MESSAGE_SERVER_IMAGE:-}" ] || [ "$MESSAGE_SERVER_IMAGE" = "$image_ref" ]; then
        return 0
      fi
      warn "Server image is frozen after infrastructure creation; the existing default latest image cannot be replaced by an override."
      return 1
    fi
    # Preserve already-created nodes that were deployed before the default
    # switched away from formal GitHub Release resolution. This compatibility
    # check never performs a GitHub request.
    if server_release_state_is_formal "$source" "$version" "$image" "$digest" "$image_ref" "$manifest_digest"; then
      if [ -n "${MESSAGE_SERVER_IMAGE:-}" ]; then
        warn "Server release is frozen after infrastructure creation; the existing formal release cannot be replaced by an image override."
        return 1
      fi
      return 0
    fi
    if server_release_state_is_debug "$source" "$version" "$image" "$digest" "$image_ref" "$manifest_digest"; then
      if [ -z "${MESSAGE_SERVER_IMAGE:-}" ] || [ "$MESSAGE_SERVER_IMAGE" = "$image_ref" ]; then
        return 0
      fi
      warn "Server release is frozen after infrastructure creation; the existing debug image cannot be changed."
      return 1
    fi
    if server_release_state_is_legacy_adopted "$source" "$version" "$image" "$digest" "$image_ref"; then
      [ -z "${MESSAGE_SERVER_IMAGE:-}" ] || {
        warn "An adopted legacy release cannot be replaced by an image override."
        return 1
      }
      return 0
    fi
    warn "Server release state is missing or inconsistent for existing infrastructure; refusing to select a replacement release."
    return 1
  fi

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

  resolved_json=$(json_build object \
    source=default_latest \
    version=latest \
    "image=$DEFAULT_MESSAGE_SERVER_IMAGE" \
    digest= \
    "image_ref=$DEFAULT_MESSAGE_SERVER_IMAGE" \
    manifest_digest=) || return 1
  state_set_raw server_release "$resolved_json"
}

server_release_is_version() {
  printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

server_release_is_digest() {
  printf '%s\n' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}
