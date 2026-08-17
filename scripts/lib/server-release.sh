#!/usr/bin/env bash
# Fresh deployments resolve application latest tags once and freeze the
# verified linux/amd64 release identities in state before provisioning.

SERVER_RELEASE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SERVER_RELEASE_PIN=$SERVER_RELEASE_LIB_DIR/../cloud-init/split/release.env
SERVER_RELEASE_RESOLVER=${DIREXTALK_PRODUCTION_RELEASE_RESOLVER:-$SERVER_RELEASE_LIB_DIR/production-release-resolver.mjs}
# shellcheck disable=SC1090
source "$SERVER_RELEASE_PIN"

server_release_is_version() {
  printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

server_release_is_revision() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

server_release_is_digest() {
  printf '%s\n' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}

server_release_is_immutable_image() {
  printf '%s\n' "$1" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$'
}

server_release_validate_pin() {
  local key
  [ -f "$SERVER_RELEASE_PIN" ] && [ ! -L "$SERVER_RELEASE_PIN" ] || return 1
  for key in \
    DIREXTALK_RELEASE_CATALOG_ORIGIN \
    DIREXTALK_SPLIT_SOURCE_REVISION \
    DIREXTALK_POSTGRES_IMAGE_IMMUTABLE \
    DIREXTALK_CADDY_IMAGE_IMMUTABLE \
    DIREXTALK_COTURN_IMAGE_IMMUTABLE; do
    [ "$(grep -Ec "^${key}=" "$SERVER_RELEASE_PIN")" -eq 1 ] || return 1
  done
  if grep -Eq '^DIREXTALK_(MESSAGE_SERVER_VERSION|MESSAGE_SERVER_IMAGE|MESSAGE_SOURCE_REVISION|AGENT_VERSION|AGENT_IMAGE|AGENT_SOURCE_REVISION)=' "$SERVER_RELEASE_PIN"; then
    return 1
  fi
  [ "$DIREXTALK_RELEASE_CATALOG_ORIGIN" = https://imadmin.dirextalk.ai ] || return 1
  [ "$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" = "docker.io/pgvector/pgvector:pg18@${DIREXTALK_POSTGRES_IMAGE_IMMUTABLE##*@}" ] || return 1
  [ "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" = "docker.io/library/caddy@${DIREXTALK_CADDY_IMAGE_IMMUTABLE##*@}" ] || return 1
  [ "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" = "docker.io/coturn/coturn:4.6.3-alpine@${DIREXTALK_COTURN_IMAGE_IMMUTABLE##*@}" ] || return 1
  server_release_is_immutable_image "$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" \
    && server_release_is_immutable_image "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" \
    && server_release_is_immutable_image "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" \
    && server_release_is_revision "$DIREXTALK_SPLIT_SOURCE_REVISION"
}

server_release_validate_override() {
  if [ -n "${MESSAGE_SERVER_IMAGE:-}" ] || [ -n "${DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE:-}" ]; then
    warn "Mutable message-server image overrides are not supported by the production split deployer."
    return 1
  fi
  server_release_validate_pin || {
    warn "The deployer-owned production split release settings are invalid."
    return 1
  }
}

server_release_state_is_recorded_current() {
  local source=$1 version=$2 image=$3 digest=$4 image_ref=$5 manifest_digest=$6 tagged
  tagged="docker.io/dirextalk/message-server:$version"
  [ "$source" = production_split ] \
    && server_release_is_version "$version" \
    && [ "$image" = "$tagged" ] || return 1
  if [ -z "$digest" ] && [ -z "$manifest_digest" ]; then
    [ "$image_ref" = "$tagged" ]
  else
    server_release_is_digest "$digest" \
      && [ "$manifest_digest" = "$digest" ] \
      && [ "$image_ref" = "$tagged" ]
  fi
}

server_release_split_state_can_advance() {
  local recorded message_version agent_version message_image agent_image postgres_image caddy_image coturn_image
  local message_revision agent_revision message_digest agent_digest
  recorded=$(state_get split_release.split_source_revision)
  [ "$(state_get split_release.release_catalog_origin)" = "$DIREXTALK_RELEASE_CATALOG_ORIGIN" ] || return 1
  message_version=$(state_get split_release.message_version)
  agent_version=$(state_get split_release.agent_version)
  message_image=$(state_get split_release.message_image)
  agent_image=$(state_get split_release.agent_image)
  message_digest=$(state_get split_release.message_manifest_digest)
  agent_digest=$(state_get split_release.agent_manifest_digest)
  postgres_image=$(state_get split_release.postgres_image)
  caddy_image=$(state_get split_release.caddy_image)
  coturn_image=$(state_get split_release.coturn_image)
  message_revision=$(state_get split_release.message_source_revision)
  agent_revision=$(state_get split_release.agent_source_revision)
  server_release_is_version "$message_version" \
    && server_release_is_version "$agent_version" \
    && server_release_is_revision "$message_revision" \
    && server_release_is_revision "$agent_revision" \
    && server_release_is_revision "$recorded" \
    && [ "$postgres_image" = "docker.io/pgvector/pgvector:pg18@${postgres_image##*@}" ] \
    && server_release_is_immutable_image "$postgres_image" \
    && server_release_is_immutable_image "$caddy_image" \
    && server_release_is_immutable_image "$coturn_image" || return 1
  if [ -z "$message_digest" ] && [ -z "$agent_digest" ]; then
    [ "$message_image" = "docker.io/dirextalk/message-server:$message_version" ] \
      && [ "$agent_image" = "docker.io/dirextalk/agent:$agent_version" ]
  else
    server_release_is_digest "$message_digest" \
      && server_release_is_digest "$agent_digest" \
      && [ "$message_image" = "docker.io/dirextalk/message-server:$message_version" ] \
      && [ "$agent_image" = "docker.io/dirextalk/agent:$agent_version" ]
  fi
}

server_release_application_receipts_match() {
  local server_version server_image server_digest server_ref
  server_version=$(state_get server_release.version)
  server_image=$(state_get server_release.image)
  server_digest=$(state_get server_release.manifest_digest)
  server_ref=$(state_get server_release.image_ref)
  server_release_state_is_recorded_current \
    "$(state_get server_release.source)" "$server_version" "$server_image" \
    "$(state_get server_release.digest)" "$server_ref" "$server_digest" \
    && [ "$(state_get split_release.message_version)" = "$server_version" ] \
    && [ "$(state_get split_release.message_source_revision)" != "" ] \
    && [ "$(state_get split_release.message_image)" = "$server_ref" ] \
    && [ "$(state_get split_release.message_manifest_digest)" = "$server_digest" ]
}

server_release_split_state_matches_pin() {
  server_release_split_state_can_advance \
    && [ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ] \
    && [ "$(state_get split_release.postgres_image)" = "$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" ] \
    && [ "$(state_get split_release.caddy_image)" = "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" ] \
    && [ "$(state_get split_release.coturn_image)" = "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" ] \
    && server_release_application_receipts_match \
    && server_release_is_digest "$(state_get split_release.message_manifest_digest)" \
    && server_release_is_digest "$(state_get split_release.agent_manifest_digest)"
}

server_release_load_recorded_application() {
  DIREXTALK_MESSAGE_SERVER_VERSION=$(state_get split_release.message_version)
  DIREXTALK_MESSAGE_SERVER_IMAGE=$(state_get split_release.message_image)
  DIREXTALK_MESSAGE_SOURCE_REVISION=$(state_get split_release.message_source_revision)
  DIREXTALK_AGENT_VERSION=$(state_get split_release.agent_version)
  DIREXTALK_AGENT_IMAGE=$(state_get split_release.agent_image)
  DIREXTALK_AGENT_SOURCE_REVISION=$(state_get split_release.agent_source_revision)
  DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST=$(state_get split_release.message_manifest_digest)
  DIREXTALK_AGENT_MANIFEST_DIGEST=$(state_get split_release.agent_manifest_digest)
  export DIREXTALK_MESSAGE_SERVER_VERSION DIREXTALK_MESSAGE_SERVER_IMAGE DIREXTALK_MESSAGE_SOURCE_REVISION
  export DIREXTALK_AGENT_VERSION DIREXTALK_AGENT_IMAGE DIREXTALK_AGENT_SOURCE_REVISION
  export DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST DIREXTALK_AGENT_MANIFEST_DIGEST
}

server_release_advance_split_state() {
  local expected_old=$1 recorded
  server_release_split_state_can_advance || return 1
  recorded=$(state_get split_release.split_source_revision)
  case "$recorded" in
    "$DIREXTALK_SPLIT_SOURCE_REVISION") return 0 ;;
    "$expected_old") ;;
    *) return 1 ;;
  esac
  state_set split_release.split_source_revision "$DIREXTALK_SPLIT_SOURCE_REVISION"
}

server_release_record_split_state() {
  local split_json
  split_json=$(json_build object \
    "release_catalog_origin=$DIREXTALK_RELEASE_CATALOG_ORIGIN" \
    "message_version=$DIREXTALK_MESSAGE_SERVER_VERSION" \
    "message_image=$DIREXTALK_MESSAGE_SERVER_IMAGE" \
    "message_source_revision=$DIREXTALK_MESSAGE_SOURCE_REVISION" \
    "message_manifest_digest=${DIREXTALK_MESSAGE_SERVER_MANIFEST_DIGEST:-}" \
    "split_source_revision=$DIREXTALK_SPLIT_SOURCE_REVISION" \
    "agent_version=$DIREXTALK_AGENT_VERSION" \
    "agent_image=$DIREXTALK_AGENT_IMAGE" \
    "agent_source_revision=$DIREXTALK_AGENT_SOURCE_REVISION" \
    "agent_manifest_digest=${DIREXTALK_AGENT_MANIFEST_DIGEST:-}" \
    "postgres_image=$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" \
    "caddy_image=$DIREXTALK_CADDY_IMAGE_IMMUTABLE" \
    "coturn_image=$DIREXTALK_COTURN_IMAGE_IMMUTABLE") || return 1
  state_set_raw split_release "$split_json"
}

server_release_json_field() {
  printf '%s' "$1" | json_stdin_get "$2"
}

server_release_resolve_fresh_state() {
  local resolved_json message_version message_image message_ref message_revision message_digest
  local agent_version agent_image agent_ref agent_revision agent_digest
  [ -f "$SERVER_RELEASE_RESOLVER" ] && [ ! -L "$SERVER_RELEASE_RESOLVER" ] || {
    warn "The production application release resolver is unavailable."
    return 1
  }
  resolved_json=$(NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}" node "$SERVER_RELEASE_RESOLVER") || return 1
  message_version=$(server_release_json_field "$resolved_json" message.version)
  message_image=$(server_release_json_field "$resolved_json" message.image)
  message_ref=$(server_release_json_field "$resolved_json" message.image_ref)
  message_revision=$(server_release_json_field "$resolved_json" message.source_revision)
  message_digest=$(server_release_json_field "$resolved_json" message.manifest_digest)
  agent_version=$(server_release_json_field "$resolved_json" agent.version)
  agent_image=$(server_release_json_field "$resolved_json" agent.image)
  agent_ref=$(server_release_json_field "$resolved_json" agent.image_ref)
  agent_revision=$(server_release_json_field "$resolved_json" agent.source_revision)
  agent_digest=$(server_release_json_field "$resolved_json" agent.manifest_digest)

  server_release_is_version "$message_version" \
    && server_release_is_version "$agent_version" \
    && server_release_is_revision "$message_revision" \
    && server_release_is_revision "$agent_revision" \
    && server_release_is_digest "$message_digest" \
    && server_release_is_digest "$agent_digest" \
    && [ "$message_image" = "docker.io/dirextalk/message-server:$message_version" ] \
    && [ "$message_ref" = "$message_image@$message_digest" ] \
    && [ "$agent_image" = "docker.io/dirextalk/agent:$agent_version" ] \
    && [ "$agent_ref" = "$agent_image@$agent_digest" ] || {
      warn "The resolved production application release is invalid."
      return 1
    }

  json_mutate "$STATE_JSON" fresh-production-release-commit "$resolved_json" \
    "$DIREXTALK_RELEASE_CATALOG_ORIGIN" "$DIREXTALK_SPLIT_SOURCE_REVISION" \
    "$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" \
    "$DIREXTALK_COTURN_IMAGE_IMMUTABLE"
}

server_release_prepare_state() {
  local instance_id server_json split_json
  server_release_validate_override || return 1
  instance_id=$(state_get resources.instance_id)
  server_json=$(state_get server_release)
  split_json=$(state_get split_release)

  if [ -n "$instance_id" ]; then
    server_release_split_state_can_advance \
      && server_release_application_receipts_match || {
        warn "Existing infrastructure has an invalid recorded application release; refusing tooling mutation."
        return 1
      }
    server_release_load_recorded_application
    return 0
  fi

  if [ -n "$server_json" ] || [ -n "$split_json" ]; then
    [ -n "$server_json" ] && [ -n "$split_json" ] && server_release_split_state_matches_pin || {
      warn "Fresh deployment has an incomplete or invalid frozen application release."
      return 1
    }
    server_release_load_recorded_application
    return 0
  fi

  server_release_resolve_fresh_state || return 1
  server_release_split_state_matches_pin || {
    warn "The frozen production application release failed post-write validation."
    return 1
  }
  server_release_load_recorded_application
}
