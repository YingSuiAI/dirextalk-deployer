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

server_release_prepare_state() {
  server_release_validate_override || return 1
  local source version image digest image_ref manifest_digest node_binary resolver_script resolved_file resolved_json instance_id

  source=$(state_get server_release.source)
  version=$(state_get server_release.version)
  image=$(state_get server_release.image)
  image_ref=$(state_get server_release.image_ref)
  digest=$(state_get server_release.digest)
  manifest_digest=$(state_get server_release.manifest_digest)
  instance_id=$(state_get resources.instance_id)

  if [ -n "$instance_id" ]; then
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

  if server_release_state_is_formal "$source" "$version" "$image" "$digest" "$image_ref" "$manifest_digest"; then
    return 0
  fi

  node_binary=$(json_node) || { warn "Node.js is required to resolve the formal server Release."; return 1; }
  resolver_script="$SERVER_RELEASE_SCRIPTS_DIR/lib/server-release-resolver.mjs"
  [ -f "$resolver_script" ] || { warn "Server Release resolver is missing: $resolver_script"; return 1; }
  resolved_file=$(mktemp)
  if ! "$node_binary" "$resolver_script" resolve-release > "$resolved_file"; then
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
