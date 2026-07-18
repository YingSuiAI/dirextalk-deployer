#!/usr/bin/env bash
# Optional single-tenant Agent image selection.  The image is never resolved
# from a mutable tag: the caller must supply the reviewed prerelease tag and
# the exact registry digest together.

agent_image_is_immutable() {
  local value=${1:-}
  case "$value" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;;
  esac
  printf '%s\n' "$value" | grep -Eq '^.+:v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)[A-Za-z0-9.-]*-[0-9a-f]{7,40}@sha256:[0-9a-f]{64}$'
}

agent_instance_id_is_canonical() {
  local value=${1:-}
  printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

agent_model_profiles_file_is_safe() {
  local path=${1:-}
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] && [ -s "$path" ] || return 1
  # This file is copied into cloud-init user-data. The Agent parser is strict
  # as well, but reject common credential-shaped fields/values before the file
  # can cross that boundary. `secret_ref: mounted:<name>` remains the only
  # supported credential reference in a catalog.
  if LC_ALL=C grep -Eiq '"(api[_-]?key|access[_-]?token|refresh[_-]?token|secret[_-]?(key|value)|private[_-]?key|client[_-]?secret|password|credentials?|authorization|bearer)"[[:space:]]*:' "$path"; then
    return 1
  fi
  if LC_ALL=C grep -Eq '(sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN( [A-Z]+)? PRIVATE KEY-----)' "$path"; then
    return 1
  fi
}

agent_model_profiles_sha256() {
  local path=${1:-}
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

agent_release_state_is_blank() {
  [ -z "${1:-}${2:-}${3:-}${4:-}${5:-}" ]
}

agent_release_state_is_disabled() {
  [ "${1:-}" = disabled ] && [ "${2:-}" = false ] && [ -z "${3:-}" ] && [ -z "${4:-}" ] && [ -z "${5:-}" ]
}

agent_release_state_is_enabled() {
  [ "${1:-}" = operator_image ] && [ "${2:-}" = true ] \
    && agent_image_is_immutable "${3:-}" \
    && agent_instance_id_is_canonical "${4:-}" \
    && printf '%s\n' "${5:-}" | grep -Eq '^[0-9a-f]{64}$'
}

agent_release_record_disabled() {
  local resolved_json
  resolved_json=$(json_build object \
    source=disabled \
    enabled=false \
    image_ref= \
    instance_id= \
    model_profiles_sha256=) || return 1
  state_set_raw agent_release "$resolved_json"
}

agent_release_record_enabled() {
  local image_ref=$1 instance_id=$2 profiles_sha256=$3 resolved_json
  resolved_json=$(json_build object \
    source=operator_image \
    enabled=true \
    "image_ref=$image_ref" \
    "instance_id=$instance_id" \
    "model_profiles_sha256=$profiles_sha256") || return 1
  state_set_raw agent_release "$resolved_json"
}

# Freeze the optional Agent identity after an instance has been created.  This
# mirrors the Message Server release guard while remaining backwards-compatible
# with already-provisioned hosts that have no Agent state at all.
agent_release_prepare_state() {
  local source enabled image_ref instance_id profiles_sha256 infrastructure_id
  source=$(state_get agent_release.source)
  enabled=$(state_get agent_release.enabled)
  image_ref=$(state_get agent_release.image_ref)
  instance_id=$(state_get agent_release.instance_id)
  profiles_sha256=$(state_get agent_release.model_profiles_sha256)
  infrastructure_id=$(state_get resources.instance_id)

  if [ -n "$infrastructure_id" ]; then
    if agent_release_state_is_blank "$source" "$enabled" "$image_ref" "$instance_id" "$profiles_sha256"; then
      agent_release_record_disabled
      return $?
    fi
    if agent_release_state_is_disabled "$source" "$enabled" "$image_ref" "$instance_id" "$profiles_sha256"; then
      if [ -n "${AGENT_IMAGE:-}${AGENT_INSTANCE_ID:-}${AGENT_MODEL_PROFILES_FILE:-}" ]; then
        warn "Agent is disabled for existing infrastructure; refusing to add it after provisioning. Create a new instance or use a reviewed migration path."
        return 1
      fi
      return 0
    fi
    if ! agent_release_state_is_enabled "$source" "$enabled" "$image_ref" "$instance_id" "$profiles_sha256"; then
      warn "Agent release state is missing or inconsistent for existing infrastructure; refusing to select a replacement image."
      return 1
    fi
    if [ -n "${AGENT_IMAGE:-}" ] && [ "$AGENT_IMAGE" != "$image_ref" ]; then
      warn "Agent image is frozen after infrastructure creation; a replacement image is refused."
      return 1
    fi
    if [ -n "${AGENT_INSTANCE_ID:-}" ] && [ "$AGENT_INSTANCE_ID" != "$instance_id" ]; then
      warn "Agent instance ID is frozen after infrastructure creation; a replacement identity is refused."
      return 1
    fi
    if [ -n "${AGENT_MODEL_PROFILES_FILE:-}" ]; then
      agent_model_profiles_file_is_safe "$AGENT_MODEL_PROFILES_FILE" || {
        warn "AGENT_MODEL_PROFILES_FILE must be a readable, non-empty regular file."
        return 1
      }
      [ "$(agent_model_profiles_sha256 "$AGENT_MODEL_PROFILES_FILE")" = "$profiles_sha256" ] || {
        warn "Agent model-profile catalog is frozen after infrastructure creation; a changed catalog is refused."
        return 1
      }
    fi
    return 0
  fi

  if [ -z "${AGENT_IMAGE:-}" ]; then
    if [ -n "${AGENT_INSTANCE_ID:-}${AGENT_MODEL_PROFILES_FILE:-}" ]; then
      warn "AGENT_INSTANCE_ID and AGENT_MODEL_PROFILES_FILE require AGENT_IMAGE."
      return 1
    fi
    agent_release_record_disabled
    return $?
  fi

  if ! agent_image_is_immutable "$AGENT_IMAGE"; then
    warn "AGENT_IMAGE must be a prerelease tag plus lowercase sha256 digest; latest, stable tags, and tag-only references are refused."
    return 1
  fi
  if ! agent_instance_id_is_canonical "${AGENT_INSTANCE_ID:-}"; then
    warn "AGENT_INSTANCE_ID must be a canonical non-nil lowercase UUID when AGENT_IMAGE is set."
    return 1
  fi
  if ! agent_model_profiles_file_is_safe "${AGENT_MODEL_PROFILES_FILE:-}"; then
    warn "AGENT_MODEL_PROFILES_FILE must be a readable, non-empty regular file when AGENT_IMAGE is set."
    return 1
  fi
  agent_release_record_enabled "$AGENT_IMAGE" "$AGENT_INSTANCE_ID" "$(agent_model_profiles_sha256 "$AGENT_MODEL_PROFILES_FILE")"
}

# Rendering needs the original non-secret catalog as well as the state hash.
# Never persist catalog contents or model credentials in state.
agent_release_require_render_inputs() {
  local enabled profiles_sha256
  enabled=$(state_get agent_release.enabled)
  [ "$enabled" = true ] || return 0
  profiles_sha256=$(state_get agent_release.model_profiles_sha256)
  if ! agent_model_profiles_file_is_safe "${AGENT_MODEL_PROFILES_FILE:-}"; then
    warn "AGENT_MODEL_PROFILES_FILE is required to render the enabled Agent bundle."
    return 1
  fi
  if [ "$(agent_model_profiles_sha256 "$AGENT_MODEL_PROFILES_FILE")" != "$profiles_sha256" ]; then
    warn "AGENT_MODEL_PROFILES_FILE does not match the reviewed catalog recorded for this deployment."
    return 1
  fi
}
