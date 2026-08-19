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

server_release_validate_resolved_component() {
  local component=$1 json=$2 version image ref revision digest repository
  version=$(server_release_json_field "$json" "$component.version")
  image=$(server_release_json_field "$json" "$component.image")
  ref=$(server_release_json_field "$json" "$component.image_ref")
  revision=$(server_release_json_field "$json" "$component.source_revision")
  digest=$(server_release_json_field "$json" "$component.manifest_digest")
  case "$component" in
    message) repository=docker.io/dirextalk/message-server ;;
    agent) repository=docker.io/dirextalk/agent ;;
    *) return 1 ;;
  esac
  server_release_is_version "$version" \
    && server_release_is_revision "$revision" \
    && server_release_is_digest "$digest" \
    && [ "$image" = "$repository:$version" ] \
    && [ "$ref" = "$image@$digest" ]
}

server_release_is_newer_version() {
  local candidate=${1#v} current=${2#v} c1 c2 c3 r1 r2 r3
  IFS=. read -r c1 c2 c3 <<<"$candidate"
  IFS=. read -r r1 r2 r3 <<<"$current"
  [ "$c1" -gt "$r1" ] || {
    [ "$c1" -eq "$r1" ] && {
      [ "$c2" -gt "$r2" ] || {
        [ "$c2" -eq "$r2" ] && [ "$c3" -gt "$r3" ]
      }
    }
  }
}

server_release_resolve_update_target() {
  local message_requested=${DIREXTALK_MESSAGE_SERVER_VERSION:-}
  local agent_requested=${DIREXTALK_AGENT_VERSION:-}
  local message_resolve agent_resolve message_env= agent_env= resolve_message=true resolve_agent=false resolved_json
  server_release_validate_override || return 1
  server_release_split_state_can_advance && server_release_application_receipts_match || {
    warn "Existing infrastructure has inconsistent application release receipts; refusing direct release update."
    return 1
  }
  server_release_is_version "${message_requested:-v0.0.0}" || [ -z "$message_requested" ] || {
    warn "DIREXTALK_MESSAGE_SERVER_VERSION must be a canonical vX.Y.Z version."
    return 1
  }
  server_release_is_version "${agent_requested:-v0.0.0}" || [ -z "$agent_requested" ] || {
    warn "DIREXTALK_AGENT_VERSION must be a canonical vX.Y.Z version."
    return 1
  }
  if [ -n "$agent_requested" ]; then
    server_release_is_version "${DIREXTALK_AGENT_MINIMUM_SERVER_VERSION:-}" || {
      warn "DIREXTALK_AGENT_MINIMUM_SERVER_VERSION is required for a direct Agent update."
      return 1
    }
  elif [ -n "${DIREXTALK_AGENT_MINIMUM_SERVER_VERSION:-}" ]; then
    warn "DIREXTALK_AGENT_MINIMUM_SERVER_VERSION requires DIREXTALK_AGENT_VERSION."
    return 1
  fi
  # An explicit component selector leaves the other component receipt-bound.
  # With no selector, update the Message Server to the verified stable release
  # and retain the Agent until its explicit compatibility floor is supplied.
  if [ -n "$message_requested" ]; then
    message_resolve=$message_requested
  elif [ -n "$agent_requested" ]; then
    message_resolve=$(state_get split_release.message_version)
    resolve_message=false
  else
    message_resolve=latest
  fi
  agent_resolve=${agent_requested:-$(state_get split_release.agent_version)}
  [ -z "$agent_requested" ] || resolve_agent=true
  if [ "$resolve_message" = true ]; then
    message_env=${message_resolve/latest/}
  fi
  if [ "$resolve_agent" = true ]; then
    agent_env=$agent_resolve
  fi
  [ -f "$SERVER_RELEASE_RESOLVER" ] && [ ! -L "$SERVER_RELEASE_RESOLVER" ] || return 1
  resolved_json=$(DIREXTALK_PRODUCTION_RELEASE_MESSAGE_VERSION="$message_env" \
    DIREXTALK_PRODUCTION_RELEASE_AGENT_VERSION="$agent_env" \
    DIREXTALK_PRODUCTION_RELEASE_RETAIN_MESSAGE="$([ "$resolve_message" = true ] || printf true)" \
    DIREXTALK_PRODUCTION_RELEASE_RETAIN_AGENT="$([ "$resolve_agent" = true ] || printf true)" \
    NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}" node "$SERVER_RELEASE_RESOLVER") || return 1
  if [ "$resolve_message" = true ] && [ "$message_resolve" != latest ]; then
    [ "$(server_release_json_field "$resolved_json" message.version)" = "$message_resolve" ] || return 1
  fi
  if [ "$resolve_message" = true ]; then
    server_release_validate_resolved_component message "$resolved_json" || {
      warn "The direct Message Server release target is invalid."
      return 1
    }
  fi
  if [ "$resolve_agent" = true ]; then
    server_release_validate_resolved_component agent "$resolved_json" || {
      warn "The direct Agent release target is invalid."
      return 1
    }
  fi
  if [ "$resolve_message" = true ] && [ "$resolve_agent" = true ]; then
    :
  elif [ "$resolve_message" != true ] && [ "$resolve_agent" != true ]; then
    warn "The direct production release target is invalid."
    return 1
  fi
  if [ "$resolve_message" = true ]; then
    DIREXTALK_UPDATE_MESSAGE_VERSION=$(server_release_json_field "$resolved_json" message.version)
    DIREXTALK_UPDATE_MESSAGE_IMAGE=$(server_release_json_field "$resolved_json" message.image)
    DIREXTALK_UPDATE_MESSAGE_IMAGE_REF=$(server_release_json_field "$resolved_json" message.image_ref)
    DIREXTALK_UPDATE_MESSAGE_REVISION=$(server_release_json_field "$resolved_json" message.source_revision)
    DIREXTALK_UPDATE_MESSAGE_DIGEST=$(server_release_json_field "$resolved_json" message.manifest_digest)
  else
    DIREXTALK_UPDATE_MESSAGE_VERSION=$(state_get split_release.message_version)
    DIREXTALK_UPDATE_MESSAGE_IMAGE=$(state_get split_release.message_image)
    DIREXTALK_UPDATE_MESSAGE_IMAGE_REF="$DIREXTALK_UPDATE_MESSAGE_IMAGE@$(state_get split_release.message_manifest_digest)"
    DIREXTALK_UPDATE_MESSAGE_REVISION=$(state_get split_release.message_source_revision)
    DIREXTALK_UPDATE_MESSAGE_DIGEST=$(state_get split_release.message_manifest_digest)
  fi
  if [ "$resolve_agent" = true ]; then
    DIREXTALK_UPDATE_AGENT_VERSION=$(server_release_json_field "$resolved_json" agent.version)
    DIREXTALK_UPDATE_AGENT_IMAGE=$(server_release_json_field "$resolved_json" agent.image)
    DIREXTALK_UPDATE_AGENT_IMAGE_REF=$(server_release_json_field "$resolved_json" agent.image_ref)
    DIREXTALK_UPDATE_AGENT_REVISION=$(server_release_json_field "$resolved_json" agent.source_revision)
    DIREXTALK_UPDATE_AGENT_DIGEST=$(server_release_json_field "$resolved_json" agent.manifest_digest)
  else
    DIREXTALK_UPDATE_AGENT_VERSION=$(state_get split_release.agent_version)
    DIREXTALK_UPDATE_AGENT_IMAGE=$(state_get split_release.agent_image)
    DIREXTALK_UPDATE_AGENT_IMAGE_REF="$DIREXTALK_UPDATE_AGENT_IMAGE@$(state_get split_release.agent_manifest_digest)"
    DIREXTALK_UPDATE_AGENT_REVISION=$(state_get split_release.agent_source_revision)
    DIREXTALK_UPDATE_AGENT_DIGEST=$(state_get split_release.agent_manifest_digest)
  fi
  if [ "$resolve_message" = true ] && [ "$DIREXTALK_UPDATE_MESSAGE_VERSION" = "$(state_get split_release.message_version)" ]; then
    [ "$DIREXTALK_UPDATE_MESSAGE_IMAGE" = "$(state_get split_release.message_image)" ] \
      && [ "$DIREXTALK_UPDATE_MESSAGE_REVISION" = "$(state_get split_release.message_source_revision)" ] \
      && [ "$DIREXTALK_UPDATE_MESSAGE_DIGEST" = "$(state_get split_release.message_manifest_digest)" ] || {
        warn "The resolved Message Server tag differs from the recorded immutable receipt."
        return 1
      }
  fi
  if [ "$resolve_agent" = true ] && [ "$DIREXTALK_UPDATE_AGENT_VERSION" = "$(state_get split_release.agent_version)" ]; then
    [ "$DIREXTALK_UPDATE_AGENT_IMAGE" = "$(state_get split_release.agent_image)" ] \
      && [ "$DIREXTALK_UPDATE_AGENT_REVISION" = "$(state_get split_release.agent_source_revision)" ] \
      && [ "$DIREXTALK_UPDATE_AGENT_DIGEST" = "$(state_get split_release.agent_manifest_digest)" ] || {
        warn "The resolved Agent tag differs from the recorded immutable receipt."
        return 1
      }
  fi
  DIREXTALK_UPDATE_AGENT_MINIMUM_SERVER_VERSION=${DIREXTALK_AGENT_MINIMUM_SERVER_VERSION:-}
  DIREXTALK_UPDATE_MESSAGE_APPLY=false
  DIREXTALK_UPDATE_AGENT_APPLY=false
  if [ "$DIREXTALK_UPDATE_MESSAGE_VERSION" != "$(state_get split_release.message_version)" ]; then
    server_release_is_newer_version "$DIREXTALK_UPDATE_MESSAGE_VERSION" "$(state_get split_release.message_version)" || {
      warn "Direct Message Server updates cannot downgrade the recorded version."
      return 1
    }
    DIREXTALK_UPDATE_MESSAGE_APPLY=true
  fi
  if [ -n "$agent_requested" ] && [ "$DIREXTALK_UPDATE_AGENT_VERSION" != "$(state_get split_release.agent_version)" ]; then
    server_release_is_newer_version "$DIREXTALK_UPDATE_AGENT_VERSION" "$(state_get split_release.agent_version)" || {
      warn "Direct Agent updates cannot downgrade the recorded version."
      return 1
    }
    DIREXTALK_UPDATE_AGENT_APPLY=true
  fi
  export DIREXTALK_UPDATE_MESSAGE_VERSION DIREXTALK_UPDATE_MESSAGE_IMAGE DIREXTALK_UPDATE_MESSAGE_IMAGE_REF
  export DIREXTALK_UPDATE_MESSAGE_REVISION DIREXTALK_UPDATE_MESSAGE_DIGEST
  export DIREXTALK_UPDATE_AGENT_VERSION DIREXTALK_UPDATE_AGENT_IMAGE DIREXTALK_UPDATE_AGENT_IMAGE_REF
  export DIREXTALK_UPDATE_AGENT_REVISION DIREXTALK_UPDATE_AGENT_DIGEST DIREXTALK_UPDATE_AGENT_MINIMUM_SERVER_VERSION
  export DIREXTALK_UPDATE_MESSAGE_APPLY DIREXTALK_UPDATE_AGENT_APPLY
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
