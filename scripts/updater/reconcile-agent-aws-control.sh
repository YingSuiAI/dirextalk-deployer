#!/usr/bin/env bash
# Atomically advance an existing EC2 Agent from AWS-control foundation mode to
# managed preparation with one exact Worker-AMI publication.
set -euo pipefail

source_dir=${1:-}
base=${2:-/var/dirextalk-message-server}
foundation_compose_sha256=${3:-}
managed_compose_sha256=${4:-}
publication_sha256=${5:-}
expected_message_image=${6:-}
expected_agent_image=${7:-}
expected_agent_instance_id=${8:-}
expected_model_profiles_sha256=${9:-}
expected_reaper_image=${10:-}
expected_worker_endpoint=${11:-}
expected_endpoint_service_name=${12:-}
state_root=${DIREXTALK_AGENT_AWS_CONTROL_ROOT:-}
marker_dir="$state_root/var/lib/dirextalk-bootstrap"
marker="$marker_dir/agent-aws-control-import"
lock_dir="$state_root/run/lock"
lock_file="$lock_dir/dirextalk-agent-aws-control-import.lock"
backup="$base/.agent-aws-control-foundation.compose"
target_compose="$source_dir/docker-compose.yml"
target_publication="$source_dir/agent-worker-ami-publication.json"

sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

valid_sha256() {
  printf '%s\n' "${1:-}" | grep -Eq '^[0-9a-f]{64}$'
}

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
    $1 == key {
      count += 1
      value = substr($0, index($0, "=") + 1)
    }
    END { exit !(count == 1 && value == expected) }
  '
}

mount_destination_is_exact() {
  local mounts=$1 expected_source=$2 expected_destination=$3
  printf '%s\n' "$mounts" | awk -F'|' -v source="$expected_source" -v destination="$expected_destination" '
    $2 == destination {
      count += 1
      matched = ($1 == source && $3 == "false")
    }
    END { exit !(count == 1 && matched) }
  '
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
      || ! runtime_env_value_is_exact "$environment" AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME "$expected_endpoint_service_name" \
      || ! runtime_env_value_is_exact "$environment" AGENT_MODEL_PROFILES_FILE /run/dirextalk-agent/agent-model-profiles.json \
      || [ ! -f "$profiles_file" ] || [ -L "$profiles_file" ] \
      || [ "$(sha256_file "$profiles_file")" != "$expected_model_profiles_sha256" ]; then
    printf '%s\n' drift
    return 0
  fi
  if runtime_env_value_is_exact "$environment" AGENT_ENABLE_MANAGED_PREPARATION_AWS true \
      && runtime_env_value_is_exact "$environment" AGENT_WORKER_AMI_PUBLICATION_FILE /run/dirextalk-agent/worker-ami-publication.json \
      && mount_destination_is_exact "$mounts" "$base/agent-worker-ami-publication.json" /run/dirextalk-agent/worker-ami-publication.json \
      && [ -f "$base/agent-worker-ami-publication.json" ] \
      && [ ! -L "$base/agent-worker-ami-publication.json" ] \
      && [ "$(sha256_file "$base/agent-worker-ami-publication.json")" = "$publication_sha256" ]; then
    printf '%s\n' managed
    return 0
  fi
  if runtime_env_value_is_exact "$environment" AGENT_ENABLE_MANAGED_PREPARATION_AWS false \
      && ! printf '%s\n' "$environment" | grep -q '^AGENT_WORKER_AMI_PUBLICATION_FILE=' \
      && ! printf '%s\n' "$mounts" | grep -Fq '|/run/dirextalk-agent/worker-ami-publication.json|'; then
    printf '%s\n' foundation
    return 0
  fi
  printf '%s\n' drift
}

atomic_install() {
  local source=$1 destination=$2 mode=$3 tmp
  tmp=$(mktemp "$base/.agent-aws-control.XXXXXX")
  install -m "$mode" "$source" "$tmp"
  sync -f "$tmp"
  mv -f "$tmp" "$destination"
  sync -f "$base"
}

write_marker() {
  local tmp
  install -d -m 0700 "$marker_dir"
  tmp=$(mktemp "$marker_dir/.agent-aws-control-import.XXXXXX")
  {
    printf 'status=applied\n'
    printf 'compose_sha256=%s\n' "$managed_compose_sha256"
    printf 'publication_sha256=%s\n' "$publication_sha256"
  } > "$tmp"
  chmod 0600 "$tmp"
  sync -f "$tmp"
  mv -f "$tmp" "$marker"
  sync -f "$marker_dir"
}

marker_matches() {
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    && grep -Fxq 'status=applied' "$marker" \
    && grep -Fxq "compose_sha256=$managed_compose_sha256" "$marker" \
    && grep -Fxq "publication_sha256=$publication_sha256" "$marker"
}

rollback_foundation() {
  [ -f "$backup" ] && [ ! -L "$backup" ] \
    && [ "$(sha256_file "$backup")" = "$foundation_compose_sha256" ] || return 1
  atomic_install "$backup" "$base/docker-compose.yml" 0644
  if [ -e "$base/agent-worker-ami-publication.json" ]; then
    [ -f "$base/agent-worker-ami-publication.json" ] && [ ! -L "$base/agent-worker-ami-publication.json" ] \
      && [ "$(sha256_file "$base/agent-worker-ami-publication.json")" = "$publication_sha256" ] || return 1
    rm -f "$base/agent-worker-ami-publication.json"
    sync -f "$base"
  fi
  docker compose --env-file "$base/.env" -f "$base/docker-compose.yml" up -d --no-deps agent >/dev/null
  [ "$(active_agent_mode)" = foundation ]
}

[ -d "$source_dir" ] && [ -f "$base/.env" ] && [ -f "$base/docker-compose.yml" ] || {
  echo "Agent AWS-control reconciliation prerequisites are missing" >&2
  exit 1
}
for digest in "$foundation_compose_sha256" "$managed_compose_sha256" "$publication_sha256"; do
  valid_sha256 "$digest" || { echo "Agent AWS-control reconciliation digest is invalid" >&2; exit 1; }
done
valid_sha256 "$expected_model_profiles_sha256" || {
  echo "Agent model-profile digest is invalid" >&2
  exit 1
}
printf '%s\n' "$expected_endpoint_service_name" \
  | grep -Eq '^com\.amazonaws\.vpce\.ap-northeast-3\.vpce-svc-[0-9a-f]+$' || {
  echo "Agent worker-control endpoint service name is invalid" >&2
  exit 1
}
[ -f "$target_compose" ] && [ ! -L "$target_compose" ] \
  && [ "$(sha256_file "$target_compose")" = "$managed_compose_sha256" ] || {
  echo "managed Agent Compose payload is missing or changed" >&2
  exit 1
}
[ -f "$target_publication" ] && [ ! -L "$target_publication" ] \
  && [ "$(sha256_file "$target_publication")" = "$publication_sha256" ] || {
  echo "Worker-AMI publication payload is missing or changed" >&2
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
current_publication_sha256=
if [ -e "$base/agent-worker-ami-publication.json" ]; then
  [ -f "$base/agent-worker-ami-publication.json" ] && [ ! -L "$base/agent-worker-ami-publication.json" ] || {
    echo "existing Worker-AMI publication path is unsafe" >&2
    exit 1
  }
  current_publication_sha256=$(sha256_file "$base/agent-worker-ami-publication.json")
fi

if [ "$current_compose_sha256" = "$managed_compose_sha256" ] \
    && [ "$current_publication_sha256" = "$publication_sha256" ]; then
  mode=$(active_agent_mode)
  if [ "$mode" = managed ]; then
    marker_matches || write_marker
    rm -f "$backup"
    printf 'applied\t%s\t%s\treadback\n' "$managed_compose_sha256" "$publication_sha256"
    exit 0
  fi
  case "$mode" in
    foundation|stopped) ;;
    *) echo "active Agent runtime drifted from both transition states" >&2; exit 1 ;;
  esac
elif [ "$current_compose_sha256" = "$foundation_compose_sha256" ]; then
  [ -z "$current_publication_sha256" ] || [ "$current_publication_sha256" = "$publication_sha256" ] || {
    echo "existing Worker-AMI publication cannot be replaced" >&2
    exit 1
  }
  if [ -e "$backup" ]; then
    [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(sha256_file "$backup")" = "$foundation_compose_sha256" ] || {
      echo "foundation Compose backup is unsafe or changed" >&2
      exit 1
    }
  else
    atomic_install "$base/docker-compose.yml" "$backup" 0600
  fi
  [ "$current_publication_sha256" = "$publication_sha256" ] \
    || atomic_install "$target_publication" "$base/agent-worker-ami-publication.json" 0644
  atomic_install "$target_compose" "$base/docker-compose.yml" 0644
else
  echo "existing Agent Compose drifted from the frozen foundation and managed targets" >&2
  exit 1
fi

if ! docker compose --env-file "$base/.env" -f "$base/docker-compose.yml" up -d --no-deps agent >/dev/null \
    || [ "$(active_agent_mode)" != managed ]; then
  rollback_foundation || echo "failed to restore the usable Agent AWS-control foundation" >&2
  echo "managed Agent restart/import failed; foundation configuration restored" >&2
  exit 1
fi

write_marker
rm -f "$backup"
sync -f "$base"
printf 'applied\t%s\t%s\trestarted\n' "$managed_compose_sha256" "$publication_sha256"
