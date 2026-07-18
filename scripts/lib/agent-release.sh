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
  local path=${1:-} output digest
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$path") || return 1
  else
    output=$(shasum -a 256 "$path") || return 1
  fi
  # GNU coreutils prefixes the complete output with `\\` when it escapes a
  # Windows-style filename. That marker is not part of the checksum.
  case "$output" in
    \\*) output=${output#?} ;;
  esac
  digest=${output%%[[:space:]]*}
  printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$digest"
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

# AWS control is opt-in and frozen alongside the optional Agent release. The
# persisted record contains only public identifiers and a publication digest.
agent_aws_control_enabled_is_explicit() { [ "${1:-}" = true ]; }

agent_aws_reaper_image_uri_is_safe() {
  local value=${1:-}
  case "$value" in ''|*$'\n'*|*$'\r'*|*$'\t'*|*' '*|*'@'*'@'*) return 1 ;; esac
  printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*@sha256:[0-9a-f]{64}$'
}

agent_worker_control_endpoint_is_safe() {
  local value=${1:-}
  # No user info, query, or credentials: only a TLS gRPC DNS target on 443.
  printf '%s\n' "$value" | grep -Eq '^grpcs://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+:443$'
}

agent_managed_preparation_aws_is_safe() { case "${1:-}" in true|false) return 0 ;; *) return 1 ;; esac; }

agent_aws_control_state_is_blank() { [ -z "${1:-}${2:-}${3:-}${4:-}${5:-}${6:-}${7:-}" ]; }
agent_aws_control_state_is_disabled() {
  [ "${1:-}" = disabled ] && [ "${2:-}" = false ] && [ -z "${3:-}" ] && [ -z "${4:-}" ] \
    && [ -z "${5:-}" ] && [ -z "${6:-}" ] && [ -z "${7:-}" ]
}
agent_aws_control_state_is_enabled() {
  case "${6:-}" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
  [ "${1:-}" = operator_configuration ] && [ "${2:-}" = true ] \
    && agent_aws_reaper_image_uri_is_safe "${3:-}" \
    && agent_worker_control_endpoint_is_safe "${4:-}" \
    && agent_managed_preparation_aws_is_safe "${5:-}" \
    && printf '%s\n' "${7:-}" | grep -Eq '^[0-9a-f]{64}$'
}

agent_aws_control_record_disabled() {
  local resolved_json
  resolved_json=$(json_build object source=disabled enabled=false aws_reaper_image_uri= worker_control_endpoint= managed_preparation_aws= worker_ami_publication_snapshot_file= worker_ami_publication_sha256=) || return 1
  state_set_raw agent_aws_control "$resolved_json"
}

agent_aws_control_record_enabled() {
  local reaper_image_uri=$1 worker_control_endpoint=$2 managed_preparation_aws=$3 publication_snapshot_file=$4 publication_sha256=$5 resolved_json
  resolved_json=$(json_build object source=operator_configuration enabled=true "aws_reaper_image_uri=$reaper_image_uri" "worker_control_endpoint=$worker_control_endpoint" "managed_preparation_aws=$managed_preparation_aws" "worker_ami_publication_snapshot_file=$publication_snapshot_file" "worker_ami_publication_sha256=$publication_sha256") || return 1
  state_set_raw agent_aws_control "$resolved_json"
}

agent_aws_control_prepare_state() {
  local source enabled reaper_image_uri worker_control_endpoint managed_preparation_aws publication_snapshot_file publication_sha256
  local infrastructure_id agent_enabled current_sha256 expected_snapshot_file
  source=$(state_get agent_aws_control.source); enabled=$(state_get agent_aws_control.enabled)
  reaper_image_uri=$(state_get agent_aws_control.aws_reaper_image_uri); worker_control_endpoint=$(state_get agent_aws_control.worker_control_endpoint)
  managed_preparation_aws=$(state_get agent_aws_control.managed_preparation_aws)
  publication_snapshot_file=$(state_get agent_aws_control.worker_ami_publication_snapshot_file)
  publication_sha256=$(state_get agent_aws_control.worker_ami_publication_sha256)
  infrastructure_id=$(state_get resources.instance_id); agent_enabled=$(state_get agent_release.enabled)
  expected_snapshot_file="$DIREXTALK_WORKDIR/agent-worker-ami-publication.json"

  case "${AGENT_ENABLE_AWS_CONTROL:-false}" in
    true|false) ;;
    *) warn 'AGENT_ENABLE_AWS_CONTROL must be true or false.'; return 1 ;;
  esac
  if ! agent_aws_control_enabled_is_explicit "${AGENT_ENABLE_AWS_CONTROL:-false}"; then
    if [ -n "${AGENT_AWS_REAPER_IMAGE_URI:-}${AGENT_WORKER_CONTROL_ENDPOINT:-}${AGENT_ENABLE_MANAGED_PREPARATION_AWS:-}${AGENT_WORKER_AMI_PUBLICATION_FILE:-}" ]; then warn 'AGENT AWS control inputs require AGENT_ENABLE_AWS_CONTROL=true.'; return 1; fi
    if agent_aws_control_state_is_enabled "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256"; then warn 'Agent AWS control was selected for this deployment; refusing to disable it through an environment change.'; return 1; fi
    if ! agent_aws_control_state_is_blank "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256" && ! agent_aws_control_state_is_disabled "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256"; then warn 'Agent AWS control state is incomplete or unsafe.'; return 1; fi
    agent_aws_control_record_disabled; return $?
  fi

  [ "$agent_enabled" = true ] || { warn 'AGENT_ENABLE_AWS_CONTROL=true requires the optional Agent runtime.'; return 1; }
  agent_aws_reaper_image_uri_is_safe "${AGENT_AWS_REAPER_IMAGE_URI:-}" || { warn 'AGENT_AWS_REAPER_IMAGE_URI must be an immutable credential-free image reference with a lowercase sha256 digest.'; return 1; }
  agent_worker_control_endpoint_is_safe "${AGENT_WORKER_CONTROL_ENDPOINT:-}" || { warn 'AGENT_WORKER_CONTROL_ENDPOINT must be a credential-free grpcs:// DNS endpoint on port 443.'; return 1; }
  agent_managed_preparation_aws_is_safe "${AGENT_ENABLE_MANAGED_PREPARATION_AWS:-}" || { warn 'AGENT_ENABLE_MANAGED_PREPARATION_AWS must be true or false when Agent AWS control is enabled.'; return 1; }
  [ -n "${AGENT_WORKER_AMI_PUBLICATION_FILE:-}" ] || { warn 'AGENT_WORKER_AMI_PUBLICATION_FILE is required when Agent AWS control is enabled.'; return 1; }

  if [ -n "$infrastructure_id" ]; then
    agent_aws_control_state_is_enabled "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256" || { warn 'Agent AWS control state is missing or inconsistent for existing infrastructure; refusing a replacement configuration.'; return 1; }
    [ "$publication_snapshot_file" = "$expected_snapshot_file" ] || { warn 'Agent AWS control snapshot location is inconsistent for existing infrastructure.'; return 1; }
    current_sha256=$(json_worker_ami_publication_snapshot "$AGENT_WORKER_AMI_PUBLICATION_FILE" "$publication_snapshot_file" "$publication_sha256") || { warn 'AGENT_WORKER_AMI_PUBLICATION_FILE is missing, malformed, unsafe, or no longer matches the frozen snapshot.'; return 1; }
    [ "$AGENT_AWS_REAPER_IMAGE_URI" = "$reaper_image_uri" ] && [ "$AGENT_WORKER_CONTROL_ENDPOINT" = "$worker_control_endpoint" ] && [ "$AGENT_ENABLE_MANAGED_PREPARATION_AWS" = "$managed_preparation_aws" ] && [ "$current_sha256" = "$publication_sha256" ] || { warn 'Agent AWS control configuration is frozen after infrastructure creation; a changed input is refused.'; return 1; }
    return 0
  fi
  if agent_aws_control_state_is_enabled "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256"; then
    [ "$publication_snapshot_file" = "$expected_snapshot_file" ] || { warn 'Agent AWS control snapshot location is inconsistent for this deployment.'; return 1; }
    current_sha256=$(json_worker_ami_publication_snapshot "$AGENT_WORKER_AMI_PUBLICATION_FILE" "$publication_snapshot_file" "$publication_sha256") || { warn 'AGENT_WORKER_AMI_PUBLICATION_FILE is missing, malformed, unsafe, or no longer matches the frozen snapshot.'; return 1; }
    [ "$AGENT_AWS_REAPER_IMAGE_URI" = "$reaper_image_uri" ] && [ "$AGENT_WORKER_CONTROL_ENDPOINT" = "$worker_control_endpoint" ] && [ "$AGENT_ENABLE_MANAGED_PREPARATION_AWS" = "$managed_preparation_aws" ] && [ "$current_sha256" = "$publication_sha256" ] || { warn 'Agent AWS control configuration is already frozen for this deployment.'; return 1; }
    return 0
  fi
  if ! agent_aws_control_state_is_blank "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256" && ! agent_aws_control_state_is_disabled "$source" "$enabled" "$reaper_image_uri" "$worker_control_endpoint" "$managed_preparation_aws" "$publication_snapshot_file" "$publication_sha256"; then warn 'Agent AWS control state is incomplete or unsafe.'; return 1; fi
  mkdir -p "$DIREXTALK_WORKDIR" || return 1
  current_sha256=$(json_worker_ami_publication_snapshot "$AGENT_WORKER_AMI_PUBLICATION_FILE" "$expected_snapshot_file") || { warn 'AGENT_WORKER_AMI_PUBLICATION_FILE must be the exact strict Agent Worker-AMI publication in one readable regular non-symlink file.'; return 1; }
  agent_aws_control_record_enabled "$AGENT_AWS_REAPER_IMAGE_URI" "$AGENT_WORKER_CONTROL_ENDPOINT" "$AGENT_ENABLE_MANAGED_PREPARATION_AWS" "$expected_snapshot_file" "$current_sha256"
}

agent_aws_control_require_render_inputs() {
  local enabled publication_snapshot_file publication_sha256
  enabled=$(state_get agent_aws_control.enabled); [ "$enabled" = true ] || return 0
  publication_snapshot_file=$(state_get agent_aws_control.worker_ami_publication_snapshot_file)
  publication_sha256=$(state_get agent_aws_control.worker_ami_publication_sha256)
  [ "$publication_snapshot_file" = "$DIREXTALK_WORKDIR/agent-worker-ami-publication.json" ] || { warn 'Agent AWS control snapshot state is missing or inconsistent.'; return 1; }
  json_worker_ami_publication_snapshot "$publication_snapshot_file" "$publication_snapshot_file" "$publication_sha256" >/dev/null || { warn 'The frozen Agent Worker-AMI publication snapshot is missing, unsafe, malformed, or changed.'; return 1; }
}
