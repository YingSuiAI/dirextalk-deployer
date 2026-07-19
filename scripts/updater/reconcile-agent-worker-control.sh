#!/usr/bin/env bash
# Atomically add the retained PrivateLink service name to the foundation Agent.
set -euo pipefail

source_dir=${1:-}
base=${2:-/var/dirextalk-message-server}
foundation_compose_sha256=${3:-}
producer_compose_sha256=${4:-}
expected_message_image=${5:-}
expected_agent_image=${6:-}
expected_agent_instance_id=${7:-}
expected_model_profiles_sha256=${8:-}
expected_reaper_image=${9:-}
expected_worker_endpoint=${10:-}
expected_endpoint_service_name=${11:-}
state_root=${DIREXTALK_AGENT_AWS_CONTROL_ROOT:-}
lock_dir="$state_root/run/lock"
lock_file="$lock_dir/dirextalk-agent-aws-control-import.lock"
backup="$base/.agent-worker-control-foundation.compose"
target_compose="$source_dir/docker-compose.yml"

sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }
valid_sha256() { printf '%s\n' "${1:-}" | grep -Eq '^[0-9a-f]{64}$'; }

env_value_is_exact() {
  local key=$1 expected=$2 count value
  count=$(awk -F= -v key="$key" '$1 == key { count += 1 } END { print count + 0 }' "$base/.env")
  [ "$count" -eq 1 ] || return 1
  value=$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$base/.env")
  [ "$value" = "$expected" ]
}

runtime_env_value_is_exact() {
  local environment=$1 key=$2 expected=$3
  printf '%s\n' "$environment" | awk -F= -v key="$key" -v expected="$expected" '
    $1 == key { count += 1; value = substr($0, index($0, "=") + 1) }
    END { exit !(count == 1 && value == expected) }
  '
}

runtime_env_value_is_absent() {
  local environment=$1 key=$2
  ! printf '%s\n' "$environment" | awk -F= -v key="$key" '$1 == key { found = 1 } END { exit !found }'
}

active_agent_mode() {
  local container running image environment mounts runtime_source profiles_file
  container=$(docker compose --env-file "$base/.env" -f "$base/docker-compose.yml" ps -q agent 2>/dev/null) || return 1
  [ -n "$container" ] || { printf '%s\n' stopped; return 0; }
  running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) || return 1
  [ "$running" = true ] || { printf '%s\n' stopped; return 0; }
  image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null) || return 1
  environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null) || return 1
  mounts=$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%t\n" .Source .Destination .RW}}{{end}}' "$container" 2>/dev/null) || return 1
  runtime_source=$(printf '%s\n' "$mounts" | awk -F'|' '$2 == "/run/dirextalk-agent" && $3 == "false" { count += 1; source = $1 } END { if (count == 1) print source; else exit 1 }') || {
    printf '%s\n' drift
    return 0
  }
  profiles_file="$runtime_source/agent-model-profiles.json"
  if [ "$image" != "$expected_agent_image" ] \
      || ! runtime_env_value_is_exact "$environment" AGENT_INSTANCE_ID "$expected_agent_instance_id" \
      || ! runtime_env_value_is_exact "$environment" AGENT_ENABLE_AWS_CONTROL true \
      || ! runtime_env_value_is_exact "$environment" AGENT_AWS_REAPER_IMAGE_URI "$expected_reaper_image" \
      || ! runtime_env_value_is_exact "$environment" AGENT_WORKER_CONTROL_ENDPOINT "$expected_worker_endpoint" \
      || ! runtime_env_value_is_exact "$environment" AGENT_ENABLE_MANAGED_PREPARATION_AWS false \
      || ! runtime_env_value_is_exact "$environment" AGENT_MODEL_PROFILES_FILE /run/dirextalk-agent/agent-model-profiles.json \
      || [ ! -f "$profiles_file" ] || [ -L "$profiles_file" ] \
      || [ "$(sha256_file "$profiles_file")" != "$expected_model_profiles_sha256" ]; then
    printf '%s\n' drift
    return 0
  fi
  if runtime_env_value_is_exact "$environment" AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME "$expected_endpoint_service_name"; then
    printf '%s\n' producer
  elif runtime_env_value_is_absent "$environment" AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME; then
    printf '%s\n' foundation
  else
    printf '%s\n' drift
  fi
}

atomic_install() {
  local source=$1 destination=$2 mode=$3 tmp
  tmp=$(mktemp "$base/.agent-worker-control.XXXXXX")
  install -m "$mode" "$source" "$tmp"
  sync -f "$tmp"
  mv -f "$tmp" "$destination"
  sync -f "$base"
}

rollback_foundation() {
  [ -f "$backup" ] && [ ! -L "$backup" ] \
    && [ "$(sha256_file "$backup")" = "$foundation_compose_sha256" ] || return 1
  atomic_install "$backup" "$base/docker-compose.yml" 0644
  docker compose --env-file "$base/.env" -f "$base/docker-compose.yml" up -d --no-deps agent >/dev/null
  [ "$(active_agent_mode)" = foundation ]
}

[ -d "$source_dir" ] && [ -f "$base/.env" ] && [ -f "$base/docker-compose.yml" ] || {
  echo "Agent worker-control reconciliation prerequisites are missing" >&2
  exit 1
}
valid_sha256 "$foundation_compose_sha256" && valid_sha256 "$producer_compose_sha256" \
  && valid_sha256 "$expected_model_profiles_sha256" || {
  echo "Agent worker-control reconciliation digest is invalid" >&2
  exit 1
}
printf '%s\n' "$expected_endpoint_service_name" \
  | grep -Eq '^com\.amazonaws\.vpce\.ap-northeast-3\.vpce-svc-[0-9a-f]{17}$' || {
  echo "Agent worker-control endpoint service name is invalid" >&2
  exit 1
}
[ -f "$target_compose" ] && [ ! -L "$target_compose" ] \
  && [ "$(sha256_file "$target_compose")" = "$producer_compose_sha256" ] || {
  echo "producer Agent Compose payload is missing or changed" >&2
  exit 1
}
env_value_is_exact MESSAGE_SERVER_IMAGE "$expected_message_image" \
  && env_value_is_exact AGENT_IMAGE "$expected_agent_image" \
  && env_value_is_exact AGENT_INSTANCE_ID "$expected_agent_instance_id" || {
  echo "existing Agent core inputs drifted" >&2
  exit 1
}

install -d -m 0755 "$lock_dir"
exec 9>"$lock_file"
flock 9

current_compose_sha256=$(sha256_file "$base/docker-compose.yml")
if [ "$current_compose_sha256" = "$producer_compose_sha256" ]; then
  mode=$(active_agent_mode)
  if [ "$mode" = producer ]; then
    rm -f "$backup"
    printf 'applied\t%s\treadback\n' "$producer_compose_sha256"
    exit 0
  fi
  case "$mode" in foundation|stopped) ;; *) echo "active Agent runtime drifted from the staged producer target" >&2; exit 1 ;; esac
elif [ "$current_compose_sha256" = "$foundation_compose_sha256" ]; then
  mode=$(active_agent_mode)
  case "$mode" in foundation|stopped) ;; *) echo "active Agent runtime drifted from the foundation source" >&2; exit 1 ;; esac
  if [ -e "$backup" ]; then
    [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(sha256_file "$backup")" = "$foundation_compose_sha256" ] || {
      echo "foundation Agent Compose backup is unsafe or changed" >&2
      exit 1
    }
  else
    atomic_install "$base/docker-compose.yml" "$backup" 0600
  fi
  atomic_install "$target_compose" "$base/docker-compose.yml" 0644
else
  echo "existing Agent Compose drifted from the frozen foundation and producer targets" >&2
  exit 1
fi

if ! docker compose --env-file "$base/.env" -f "$base/docker-compose.yml" up -d --no-deps agent >/dev/null \
    || [ "$(active_agent_mode)" != producer ]; then
  rollback_foundation || echo "failed to restore the usable Agent AWS-control foundation" >&2
  echo "worker-control Agent restart failed; foundation configuration restored" >&2
  exit 1
fi

rm -f "$backup"
sync -f "$base"
printf 'applied\t%s\trestarted\n' "$producer_compose_sha256"
