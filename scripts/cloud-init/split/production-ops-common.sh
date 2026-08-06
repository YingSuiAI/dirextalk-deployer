#!/usr/bin/env bash

production_die() { printf 'split production operation: %s\n' "$*" >&2; exit 1; }
production_negative() { printf 'split production operation: %s\n' "$*" >&2; exit 3; }

production_read_pair() {
  local file=$1 key=$2 count value
  count=$(awk -F= -v wanted="$key" '$1 == wanted {n++} END {print n+0}' "$file")
  [ "$count" -eq 1 ] || production_die "$file must contain exactly one $key"
  value=$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0,length(wanted)+2); exit}' "$file")
  [ -n "$value" ] || production_die "$file contains an empty $key"
  printf '%s' "$value"
}

production_require_control_file() {
  local file=$1 mode=$2
  [ -f "$file" ] && [ ! -L "$file" ] || production_die "missing regular control file: $file"
  [ "$(stat -c '%u:%a' "$file")" = "$(id -u):$mode" ] || production_die "control file owner or mode differs: $file"
}

production_bind_runtime() {
  production_base=${DIREXTALK_PRODUCTION_BASE:-/var/dirextalk-message-server}
  production_split=$production_base/deploy/split-agent
  production_run=$production_base/split
  production_env=$production_run/.env
  production_manifest=$production_run/.manifest
  production_receipt=$production_run/.cleanup-receipt
  production_edge_env=$production_base/edge.env
  production_edge_receipt=$production_base/edge-bootstrap-receipt
  [ -d "$production_base" ] && [ ! -L "$production_base" ] || production_die 'production base is unavailable'
  [ -d "$production_run" ] && [ ! -L "$production_run" ] || production_die 'split runtime directory is unavailable'
  production_require_control_file "$production_env" 400
  production_require_control_file "$production_manifest" 400
  production_require_control_file "$production_receipt" 400
  production_require_control_file "$production_edge_env" 400
  production_require_control_file "$production_edge_receipt" 400
  [ -x "$production_split/scripts/restart-agent-local.sh" ] || production_die 'canonical existing-runtime restart wrapper is unavailable'
  [ -x "$production_split/scripts/cleanup-local.sh" ] || production_die 'canonical split cleanup is unavailable'
  grep -Fqx '# dirextalk-split-cleanup-receipt-v1' "$production_receipt" || production_die 'cleanup receipt version is unsupported'
  [ "$(production_read_pair "$production_receipt" state)" = complete ] || production_negative 'split runtime cleanup receipt is not complete'
  [ "$(production_read_pair "$production_manifest" compose_mode)" = production ] || production_negative 'existing-runtime operations require a production stack'
  [ "$(production_read_pair "$production_receipt" control.env_identity)" = "$(stat -c '%d:%i:%u' "$production_env")" ] || production_die 'runtime environment identity differs from receipt'
  [ "$(production_read_pair "$production_receipt" control.manifest_identity)" = "$(stat -c '%d:%i:%u' "$production_manifest")" ] || production_die 'runtime manifest identity differs from receipt'
  [ "$(production_read_pair "$production_receipt" control.env_sha256)" = "$(sha256sum "$production_env" | awk '{print $1}')" ] || production_die 'runtime environment digest differs from receipt'
  [ "$(production_read_pair "$production_receipt" control.manifest_sha256)" = "$(sha256sum "$production_manifest" | awk '{print $1}')" ] || production_die 'runtime manifest digest differs from receipt'
  production_stack=$(production_read_pair "$production_manifest" stack_name)
  printf '%s\n' "$production_stack" | grep -Eq '^d-[a-z2-7]{26}$' || production_die 'split stack identity is invalid'
  [ "$(production_read_pair "$production_receipt" stack_name)" = "$production_stack" ] || production_die 'runtime receipt stack differs from manifest'
}

production_bind_completed_runtime() {
  production_base=${DIREXTALK_PRODUCTION_BASE:-/var/dirextalk-message-server}
  if [ ! -e "$production_base/.split-deploy-done" ] && [ ! -L "$production_base/.split-deploy-done" ]; then
    production_negative 'completed split runtime is unavailable'
  fi
  [ -f "$production_base/.split-deploy-done" ] && [ ! -L "$production_base/.split-deploy-done" ] \
    || production_die 'completed split runtime marker is invalid'
  production_bind_runtime
}

production_verify_edge() {
  local identity actual_id project service image network state health
  grep -Fqx '# dirextalk-edge-bootstrap-receipt-v1' "$production_edge_receipt" || production_die 'edge receipt version is unsupported'
  [ "$(production_read_pair "$production_edge_receipt" stack)" = "$production_stack" ] || production_die 'edge receipt stack differs'
  production_edge_id=$(production_read_pair "$production_edge_receipt" container_id)
  printf '%s\n' "$production_edge_id" | grep -Eq '^[0-9a-f]{64}$' || production_die 'edge container identity is invalid'
  production_edge_image=$(production_read_pair "$production_edge_receipt" image)
  production_edge_network=$(production_read_pair "$production_edge_receipt" network)
  [ "$production_edge_image" = "$(production_read_pair "$production_edge_env" DIREXTALK_CADDY_IMAGE_IMMUTABLE)" ] || production_die 'edge image differs from protected environment'
  [ "$production_edge_network" = "${production_stack}-message-public" ] || production_die 'edge network is outside the split stack'
  identity=$(docker inspect --format '{{.Id}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$production_edge_id" 2>/dev/null) || production_die 'recorded edge container is unavailable'
  IFS='|' read -r actual_id project service image state health <<<"$identity"
  network=$(docker inspect --format "{{if index .NetworkSettings.Networks \"$production_edge_network\"}}true{{end}}" "$production_edge_id" 2>/dev/null) || production_die 'recorded edge network inspection failed'
  [ "$actual_id" = "$production_edge_id" ] || production_die 'edge container identity changed'
  [ "$project" = "${production_stack}-edge" ] && [ "$service" = caddy ] || production_die 'edge Compose identity changed'
  [ "$image" = "$production_edge_image" ] || production_die 'edge container image differs from receipt'
  [ "$network" = true ] || production_die 'edge container network differs from receipt'
  [ "$state" = running ] && [ "$health" = healthy ] || production_die 'edge container is not healthy'
}
