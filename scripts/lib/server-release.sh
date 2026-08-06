#!/usr/bin/env bash
# The deployer owns one immutable production split release. There is no
# mutable image override, legacy adoption, or standard Compose fallback.

SERVER_RELEASE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SERVER_RELEASE_PIN=$SERVER_RELEASE_LIB_DIR/../cloud-init/split/release.env
# shellcheck disable=SC1090
source "$SERVER_RELEASE_PIN"

server_release_is_version() {
  printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

server_release_is_digest() {
  printf '%s\n' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}

server_release_is_immutable_image() {
  printf '%s\n' "$1" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$'
}

server_release_validate_pin() {
  [ -f "$SERVER_RELEASE_PIN" ] && [ ! -L "$SERVER_RELEASE_PIN" ] || return 1
  server_release_is_version "$DIREXTALK_MESSAGE_SERVER_VERSION" || return 1
  server_release_is_version "$DIREXTALK_AGENT_VERSION" || return 1
  [ "$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" = "docker.io/dirextalk/message-server@${DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE##*@}" ] || return 1
  [ "$DIREXTALK_AGENT_IMAGE_IMMUTABLE" = "docker.io/dirextalk/agent@${DIREXTALK_AGENT_IMAGE_IMMUTABLE##*@}" ] || return 1
  [ "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" = "docker.io/library/caddy@${DIREXTALK_CADDY_IMAGE_IMMUTABLE##*@}" ] || return 1
  [ "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" = "docker.io/coturn/coturn:4.6.3-alpine@${DIREXTALK_COTURN_IMAGE_IMMUTABLE##*@}" ] || return 1
  server_release_is_immutable_image "$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" || return 1
  server_release_is_immutable_image "$DIREXTALK_AGENT_IMAGE_IMMUTABLE" || return 1
  server_release_is_immutable_image "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" || return 1
  server_release_is_immutable_image "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" || return 1
  printf '%s\n' "$DIREXTALK_MESSAGE_SOURCE_REVISION" "$DIREXTALK_SPLIT_SOURCE_REVISION" "$DIREXTALK_AGENT_SOURCE_REVISION" \
    | grep -Eq '^[0-9a-f]{40}$' || return 1
  [ "$(printf '%s\n' "$DIREXTALK_MESSAGE_SOURCE_REVISION" "$DIREXTALK_SPLIT_SOURCE_REVISION" "$DIREXTALK_AGENT_SOURCE_REVISION" | grep -Ec '^[0-9a-f]{40}$')" -eq 3 ]
}

server_release_validate_override() {
  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ] || [ -n "${DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE:-}" ]; then
    warn "Mutable message-server image overrides are not supported by the production split deployer."
    return 1
  fi
  server_release_validate_pin || {
    warn "The deployer-owned production split release pin is invalid."
    return 1
  }
}

server_release_state_matches_pin() {
  local source=$1 version=$2 image=$3 digest=$4 image_ref=$5 manifest_digest=$6
  local expected_digest=${DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE##*@}
  [ "$source" = production_split ] \
    && [ "$version" = "$DIREXTALK_MESSAGE_SERVER_VERSION" ] \
    && [ "$image" = "docker.io/dirextalk/message-server:$DIREXTALK_MESSAGE_SERVER_VERSION" ] \
    && [ "$digest" = "$expected_digest" ] \
    && [ "$image_ref" = "$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" ] \
    && [ "$manifest_digest" = "$expected_digest" ]
}

server_release_split_state_matches_pin() {
  [ "$(state_get split_release.message_version)" = "$DIREXTALK_MESSAGE_SERVER_VERSION" ] \
    && [ "$(state_get split_release.message_image)" = "$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" ] \
    && [ "$(state_get split_release.message_source_revision)" = "$DIREXTALK_MESSAGE_SOURCE_REVISION" ] \
    && [ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ] \
    && [ "$(state_get split_release.agent_version)" = "$DIREXTALK_AGENT_VERSION" ] \
    && [ "$(state_get split_release.agent_image)" = "$DIREXTALK_AGENT_IMAGE_IMMUTABLE" ] \
    && [ "$(state_get split_release.agent_source_revision)" = "$DIREXTALK_AGENT_SOURCE_REVISION" ] \
    && [ "$(state_get split_release.caddy_image)" = "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" ] \
    && [ "$(state_get split_release.coturn_image)" = "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" ]
}

server_release_record_split_state() {
  local split_json
  split_json=$(json_build object \
    "message_version=$DIREXTALK_MESSAGE_SERVER_VERSION" \
    "message_image=$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" \
    "message_source_revision=$DIREXTALK_MESSAGE_SOURCE_REVISION" \
    "split_source_revision=$DIREXTALK_SPLIT_SOURCE_REVISION" \
    "agent_version=$DIREXTALK_AGENT_VERSION" \
    "agent_image=$DIREXTALK_AGENT_IMAGE_IMMUTABLE" \
    "agent_source_revision=$DIREXTALK_AGENT_SOURCE_REVISION" \
    "caddy_image=$DIREXTALK_CADDY_IMAGE_IMMUTABLE" \
    "coturn_image=$DIREXTALK_COTURN_IMAGE_IMMUTABLE") || return 1
  state_set_raw split_release "$split_json"
}

server_release_prepare_state() {
  server_release_validate_override || return 1
  local source version image digest image_ref manifest_digest expected_digest resolved_json instance_id
  source=$(state_get server_release.source)
  version=$(state_get server_release.version)
  image=$(state_get server_release.image)
  digest=$(state_get server_release.digest)
  image_ref=$(state_get server_release.image_ref)
  manifest_digest=$(state_get server_release.manifest_digest)
  instance_id=$(state_get resources.instance_id)

  if [ -n "$instance_id" ]; then
    server_release_state_matches_pin "$source" "$version" "$image" "$digest" "$image_ref" "$manifest_digest" || {
      warn "Existing infrastructure is not bound to the current production split release; refusing replacement or compatibility fallback."
      return 1
    }
    server_release_split_state_matches_pin || {
      warn "Existing infrastructure has incomplete or different Agent/Caddy/coturn/source pins; refusing replacement."
      return 1
    }
    return 0
  fi

  expected_digest=${DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE##*@}
  resolved_json=$(json_build object \
    source=production_split \
    "version=$DIREXTALK_MESSAGE_SERVER_VERSION" \
    "image=docker.io/dirextalk/message-server:$DIREXTALK_MESSAGE_SERVER_VERSION" \
    "digest=$expected_digest" \
    "image_ref=$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" \
    "manifest_digest=$expected_digest") || return 1
  state_set_raw server_release "$resolved_json" || return 1
  server_release_record_split_state
}
