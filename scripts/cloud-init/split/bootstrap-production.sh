#!/usr/bin/env bash
# First-fresh production consumer for the staged canonical split-agent bundle.
set -euo pipefail

base=${DIREXTALK_BOOTSTRAP_BASE:-/var/dirextalk-message-server}
script_dir=$(cd "$(dirname "$0")" && pwd -P)
split=$base/deploy/split-agent
run_dir=$base/split
env_file=$base/.env
stage_file=$base/.split-bootstrap-stage
operation=${1:-bootstrap}
[ "$#" -le 1 ] || { echo "usage: $0 [--reconcile-edge]" >&2; exit 2; }
case "$operation" in
  bootstrap|--reconcile-edge) ;;
  *) echo "usage: $0 [--reconcile-edge]" >&2; exit 2 ;;
esac
stable_ip_file=$base/stable-public-ip
runner_libexec=/usr/local/libexec/dirextalk/split-agent

install_runner_host_assets() {
  install -d -o root -g root -m 0755 \
    "$runner_libexec/scripts" \
    "$runner_libexec/systemd" \
    "$runner_libexec/sysusers.d" \
    "$runner_libexec/apparmor.d"
  install -o root -g root -m 0755 \
    "$split/scripts/prepare-runner-cgroups.sh" \
    "$split/scripts/manage-runner-apparmor.sh" \
    "$runner_libexec/scripts/"
  install -o root -g root -m 0644 \
    "$split/systemd/dirextalk-extension-runner@.service" \
    "$split/systemd/dirextalk-core-runner@.service" \
    "$runner_libexec/systemd/"
  install -o root -g root -m 0644 \
    "$split/sysusers.d/dirextalk-split-agent.conf" \
    "$runner_libexec/sysusers.d/"
  install -o root -g root -m 0644 \
    "$split/apparmor.d/dirextalk-runner-userns" \
    "$runner_libexec/apparmor.d/dirextalk-runner-userns"
}

remove_empty_fresh_run_dir() {
  local identity
  [ -e "$run_dir" ] || return 0
  [ -d "$run_dir" ] && [ ! -L "$run_dir" ] || return 1
  [ "$(stat -c '%u:%g:%a' -- "$run_dir")" = 0:0:700 ] || return 1
  [ -z "$(find "$run_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] || return 1
  identity=$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir") || return 1
  [ "$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir" 2>/dev/null)" = "$identity" ] || return 1
  rmdir -- "$run_dir"
}

read_env() {
  local key=$1 count value
  count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$env_file")
  [ "$count" -eq 1 ] || { echo "$env_file must contain exactly one $key" >&2; return 1; }
  value=$(awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$env_file")
  [ -n "$value" ] || { echo "$key is empty" >&2; return 1; }
  printf '%s' "$value"
}

read_pair() {
  local file=$1 key=$2 count value
  count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$file")
  [ "$count" -eq 1 ] || { echo "$file must contain exactly one $key" >&2; return 1; }
  value=$(awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$file")
  [ -n "$value" ] || { echo "$file contains an empty $key" >&2; return 1; }
  printf '%s' "$value"
}

require_pair() {
  local file=$1 key=$2 expected=$3
  [ "$(read_pair "$file" "$key")" = "$expected" ] || {
    echo "$file contains an unexpected $key" >&2
    exit 1
  }
}

write_stage() {
  local value=$1 tmp
  tmp=$(mktemp "$base/.split-bootstrap-stage.XXXXXX")
  printf '%s\n' "$value" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$stage_file"
}

cleanup_failed_application_start() {
  local start_status=$1 run_identity env_identity manifest_identity env_sha256 manifest_sha256
  local preparation=$base/runner-preparation.env preparation_identity preparation_sha256
  local cleanup_status control_file receipt=$run_dir/.cleanup-receipt
  [ -d "$run_dir" ] && [ ! -L "$run_dir" ] || {
    echo "application start failed (status $start_status) before a recoverable run directory was available" >&2
    return 1
  }
  run_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir") || return 1
  for control_file in "$run_dir/.env" "$run_dir/.manifest"; do
    [ -f "$control_file" ] && [ ! -L "$control_file" ] || {
      echo "application start failed (status $start_status) without a recoverable control file: $control_file" >&2
      return 1
    }
  done
  env_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir/.env") || return 1
  manifest_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir/.manifest") || return 1
  env_sha256=$(sha256sum -- "$run_dir/.env" | awk '{print $1}') || return 1
  manifest_sha256=$(sha256sum -- "$run_dir/.manifest" | awk '{print $1}') || return 1
  [ -f "$preparation" ] && [ ! -L "$preparation" ] || {
    echo "application start failed (status $start_status) without a recoverable runner preparation receipt" >&2
    return 1
  }
  preparation_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$preparation") || return 1
  preparation_sha256=$(sha256sum -- "$preparation" | awk '{print $1}') || return 1

  revalidate_failed_run() {
    [ "$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir" 2>/dev/null)" = "$run_identity" ] \
      && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir/.env" 2>/dev/null)" = "$env_identity" ] \
      && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$run_dir/.manifest" 2>/dev/null)" = "$manifest_identity" ] \
      && [ "$(sha256sum -- "$run_dir/.env" 2>/dev/null | awk '{print $1}')" = "$env_sha256" ] \
      && [ "$(sha256sum -- "$run_dir/.manifest" 2>/dev/null | awk '{print $1}')" = "$manifest_sha256" ]
  }

  revalidate_runner_preparation() {
    [ "$(stat -c '%d:%i:%u:%g:%a' -- "$preparation" 2>/dev/null)" = "$preparation_identity" ] \
      && [ "$(sha256sum -- "$preparation" 2>/dev/null | awk '{print $1}')" = "$preparation_sha256" ]
  }

  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || {
      echo "application start cleanup receipt is not a regular control file" >&2
      return 1
    }
    revalidate_failed_run || { echo "application start controls changed before cleanup" >&2; return 1; }
    revalidate_runner_preparation || { echo "runner preparation receipt changed before cleanup" >&2; return 1; }
    if "$split/scripts/cleanup-local.sh" --purge "$run_dir"; then
      :
    else
      cleanup_status=$?
      echo "application start failed (status $start_status) and stack cleanup failed (status $cleanup_status)" >&2
      return 1
    fi
  else
    revalidate_failed_run || { echo "application start controls changed before cleanup" >&2; return 1; }
    revalidate_runner_preparation || { echo "runner preparation receipt changed before cleanup" >&2; return 1; }
    if "$split/scripts/cleanup-provision-failure.sh" "$run_dir"; then
      :
    else
      cleanup_status=$?
      if [ "$cleanup_status" -eq 3 ]; then
        echo "application start failed (status $start_status) and provision cleanup stopped in an expected negative state" >&2
        return 1
      else
        echo "application start failed (status $start_status) and provision cleanup failed (status $cleanup_status)" >&2
        return 1
      fi
    fi
  fi

  revalidate_failed_run || { echo "application start controls changed after cleanup" >&2; return 1; }
  revalidate_runner_preparation || { echo "runner preparation receipt changed after cleanup" >&2; return 1; }
  rm -f -- "$preparation" || {
    echo "runner preparation receipt could not be invalidated after cleanup" >&2
    return 1
  }
  [ ! -e "$preparation" ] && [ ! -L "$preparation" ] || {
    echo "runner preparation receipt remains after cleanup" >&2
    return 1
  }
  rm -rf -- "$run_dir" || {
    echo "failed application run directory could not be removed after cleanup" >&2
    return 1
  }
  [ ! -e "$run_dir" ] && [ ! -L "$run_dir" ] || {
    echo "failed application run directory remains after cleanup" >&2
    return 1
  }
  echo "application start failed (status $start_status); partial fresh stack was cleaned for retry" >&2
}

require_digest() {
  printf '%s\n' "$2" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$' || {
    echo "$1 must be an immutable image digest" >&2
    exit 1
  }
}

require_version_application_image() {
  local name=$1 image=$2 repository=$3 version=$4 expected
  expected="$repository:$version"
  [ "$image" = "$expected" ] || {
    echo "$name must use the prepared version tag $expected" >&2
    exit 1
  }
}

[ -f "$env_file" ] && [ ! -L "$env_file" ] || { echo "missing protected bootstrap env" >&2; exit 1; }
[ "$(stat -c '%u:%a' "$env_file")" = "0:600" ] || { echo "bootstrap env must be root-owned mode 0600" >&2; exit 1; }
[ -f "$split/compose.production.yaml" ] && [ ! -L "$split/compose.production.yaml" ] || {
  echo "staged production Compose override is missing" >&2
  exit 1
}
[ -x "$split/scripts/update-message-server-local.sh" ] && [ ! -L "$split/scripts/update-message-server-local.sh" ] || {
  echo "staged message-server update adapter is not executable" >&2
  exit 1
}
[ -x "$split/scripts/prepare-host-dependencies.sh" ] && [ ! -L "$split/scripts/prepare-host-dependencies.sh" ] || {
  echo "staged host dependency preparation helper is not executable" >&2
  exit 1
}
for cleanup_helper in cleanup-local.sh cleanup-provision-failure.sh; do
  [ -x "$split/scripts/$cleanup_helper" ] && [ ! -L "$split/scripts/$cleanup_helper" ] || {
    echo "staged split cleanup helper is not executable: $cleanup_helper" >&2
    exit 1
  }
done
[ -f "$split/SOURCE_REVISION" ] || { echo "staged canonical split source is missing" >&2; exit 1; }
[ -f "$split/SOURCE_FILES.sha256" ] || { echo "staged canonical split source manifest is missing" >&2; exit 1; }
(cd "$split" && sha256sum -c --status SOURCE_FILES.sha256) || {
  echo "staged canonical split source differs from its manifest" >&2
  exit 1
}
"$split/scripts/prepare-host-dependencies.sh"

domain=$(read_env DOMAIN)
printf '%s\n' "$domain" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' || {
  echo "protected bootstrap domain is invalid" >&2
  exit 1
}
postgres_image=$(read_env POSTGRES_IMAGE)
caddy_image=$(read_env CADDY_IMAGE)
split_revision=$(read_env SPLIT_SOURCE_REVISION)
runtime_split_revision=${DIREXTALK_AUTHORIZED_SPLIT_SOURCE_REVISION:-$split_revision}
release_catalog_origin=$(read_env DIREXTALK_RELEASE_CATALOG_ORIGIN)
if [ "$operation" = --reconcile-edge ]; then
  [ -f "$run_dir/.env" ] && [ ! -L "$run_dir/.env" ] \
    && [ "$(stat -c '%u:%a' "$run_dir/.env")" = "0:400" ] \
    || { echo "protected runtime release receipt is unavailable" >&2; exit 1; }
  message_image=$(read_pair "$run_dir/.env" DIREXTALK_MESSAGE_SERVER_IMAGE)
  agent_image=$(read_pair "$run_dir/.env" DIREXTALK_AGENT_IMAGE)
  message_version=$(read_pair "$run_dir/.env" DIREXTALK_MESSAGE_SERVER_VERSION)
  agent_version=$(read_pair "$run_dir/.env" DIREXTALK_AGENT_VERSION)
  message_revision=$(read_pair "$run_dir/.env" DIREXTALK_MESSAGE_SOURCE_REVISION)
  agent_revision=$(read_pair "$run_dir/.env" DIREXTALK_AGENT_SOURCE_REVISION)
else
  message_image=$(read_env MESSAGE_SERVER_IMAGE)
  agent_image=$(read_env AGENT_IMAGE)
  message_version=$(read_env MESSAGE_VERSION)
  agent_version=$(read_env AGENT_VERSION)
  message_revision=$(read_env MESSAGE_SOURCE_REVISION)
  agent_revision=$(read_env AGENT_SOURCE_REVISION)
fi
[ "$release_catalog_origin" = https://imadmin.dirextalk.ai ] \
  || { echo "protected release catalog origin is invalid" >&2; exit 1; }
require_version_application_image MESSAGE_SERVER_IMAGE "$message_image" docker.io/dirextalk/message-server "$message_version"
require_version_application_image AGENT_IMAGE "$agent_image" docker.io/dirextalk/agent "$agent_version"
require_digest POSTGRES_IMAGE "$postgres_image"
[ "$postgres_image" = "docker.io/pgvector/pgvector:pg18@${postgres_image##*@}" ] || {
  echo "POSTGRES_IMAGE must use the pinned pgvector/pgvector:pg18 image" >&2
  exit 1
}
require_digest CADDY_IMAGE "$caddy_image"
coturn_image=$(read_env COTURN_IMAGE)
require_digest COTURN_IMAGE "$coturn_image"
for revision in "$message_revision" "$split_revision" "$agent_revision"; do
  printf '%s\n' "$revision" | grep -Eq '^[0-9a-f]{40}$' || { echo "source revision is invalid" >&2; exit 1; }
done
for version in "$message_version" "$agent_version"; do
  printf '%s\n' "$version" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || { echo "application version is invalid" >&2; exit 1; }
done

verify_application_image() {
  local image=$1 expected_version=$2 expected_revision=$3 binary label probe
  docker pull --platform linux/amd64 "$image" >/dev/null \
    || { echo "could not pull prepared application release: $image" >&2; exit 1; }
  label=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "org.opencontainers.image.revision"}}') \
    || { echo "could not inspect application image: $image" >&2; exit 1; }
  [ "$label" = "$expected_version|$expected_revision" ] \
    || { echo "application image label does not match the prepared version/revision: $image" >&2; exit 1; }
  for binary in ${4}; do
    probe=$(docker run --rm --entrypoint "$binary" "$image" --version) \
      || { echo "application binary probe failed: $binary" >&2; exit 1; }
    [ "$probe" = "$expected_version" ] \
      || { echo "application binary version mismatch: $binary" >&2; exit 1; }
  done
}

verify_application_image "$message_image" "$message_version" "$message_revision" \
  /usr/bin/dirextalk-message-server
verify_application_image "$agent_image" "$agent_version" "$agent_revision" \
  '/usr/local/bin/dirextalk-agent /usr/local/bin/dirextalk-extension-runner /usr/local/bin/dirextalk-core-runner'
[ "$(printf '%s\n' "$runtime_split_revision" | grep -Ec '^[0-9a-f]{40}$')" -eq 1 ] || {
  echo "authorized runtime split revision is invalid" >&2
  exit 1
}
[ "$(cat "$split/SOURCE_REVISION")" = "$runtime_split_revision" ] || {
  echo "staged split contract revision differs from the pinned deployment revision" >&2
  exit 1
}
[ -f "$stable_ip_file" ] && [ ! -L "$stable_ip_file" ] || { echo "stable public IP receipt is missing" >&2; exit 1; }
[ "$(stat -c '%u:%a' "$stable_ip_file")" = "0:600" ] || { echo "stable public IP receipt must be root-owned mode 0600" >&2; exit 1; }
turn_external_ip=$(cat "$stable_ip_file")
printf '%s\n' "$turn_external_ip" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' || {
  echo "stable public IP receipt is not a canonical IPv4 address" >&2
  exit 1
}
IFS=. read -r -a turn_octets <<<"$turn_external_ip"
for turn_octet in "${turn_octets[@]}"; do
  [ "$turn_octet" -le 255 ] || { echo "stable public IP receipt contains an IPv4 octet above 255" >&2; exit 1; }
done

completed=false
agent_attention=false
if [ "$operation" = --reconcile-edge ]; then
  [ -f "$base/.split-deploy-done" ] && [ ! -L "$base/.split-deploy-done" ] || {
    echo "edge reconcile requires a completed split deployment" >&2
    exit 3
  }
  completed=true
  [ -s "$base/split-stack-name" ] || { echo "completed deployment lacks its split stack identity" >&2; exit 1; }
  stack=$(cat "$base/split-stack-name")
elif [ -f "$base/.split-deploy-done" ]; then
  completed=true
  [ -s "$base/split-stack-name" ] || { echo "completed deployment lacks its split stack identity" >&2; exit 1; }
  stack=$(cat "$base/split-stack-name")
else
  cloud_worker_host_region=$(read_env DIREXTALK_CLOUD_WORKER_HOST_REGION)
  printf '%s\n' "$cloud_worker_host_region" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' || {
    echo "protected Cloud Worker host region is invalid" >&2
    exit 1
  }
  write_stage runner_preparation
  install_runner_host_assets
  runner_preparation_current=false
  if [ -s "$base/runner-preparation.env" ] \
    && [ "$(read_pair "$base/runner-preparation.env" DIREXTALK_RUNNER_APPARMOR_MANAGER_PATH 2>/dev/null || true)" = "$runner_libexec/scripts/manage-runner-apparmor.sh" ] \
    && [ "$(read_pair "$base/runner-preparation.env" DIREXTALK_RUNNER_PREP_HELPER_PATH 2>/dev/null || true)" = "$runner_libexec/scripts/prepare-runner-cgroups.sh" ]; then
    runner_preparation_current=true
  fi
  if [ "$runner_preparation_current" = false ]; then
  if [ -s "$base/split-stack-name" ]; then
    stack=$(cat "$base/split-stack-name")
  else
    stack=d-$(head -c 16 /dev/urandom | base32 | tr '[:upper:]' '[:lower:]' | tr -d '=[:space:]')
    printf '%s\n' "$stack" >"$base/split-stack-name"
    chmod 0600 "$base/split-stack-name"
  fi
  "$runner_libexec/scripts/prepare-runner-cgroups.sh" "$stack" >"$base/runner-preparation.env"
  chmod 0400 "$base/runner-preparation.env"
  else
    stack=$(cat "$base/split-stack-name")
  fi
  set -a
  # This receipt is generated by the root-owned helper from this exact bundle.
  # shellcheck disable=SC1090
  . "$base/runner-preparation.env"
  set +a

  write_stage provision
  if [ -e "$run_dir" ]; then
    remove_empty_fresh_run_dir || :
  fi
  if [ ! -e "$run_dir" ]; then
    if DIREXTALK_SPLIT_STACK_NAME="$stack" \
      DIREXTALK_SPLIT_COMPOSE_MODE=production \
      DIREXTALK_MESSAGE_TLS_MODE=edge-terminated \
      DIREXTALK_MESSAGE_SERVER_NAME="$domain" \
      DIREXTALK_CORE_EXTENSION_ENABLED=true \
      DIREXTALK_CORE_WORKLOAD_ENABLED=true \
      DIREXTALK_MESSAGE_SERVER_IMAGE="$message_image" \
      DIREXTALK_AGENT_IMAGE="$agent_image" \
      DIREXTALK_MESSAGE_SERVER_VERSION="$message_version" \
      DIREXTALK_MESSAGE_SOURCE_REVISION="$message_revision" \
      DIREXTALK_AGENT_VERSION="$agent_version" \
      DIREXTALK_AGENT_SOURCE_REVISION="$agent_revision" \
      DIREXTALK_POSTGRES_IMAGE_IMMUTABLE="$postgres_image" \
      DIREXTALK_COTURN_IMAGE_IMMUTABLE="$coturn_image" \
      DIREXTALK_RELEASE_CATALOG_ORIGIN="$release_catalog_origin" \
      DIREXTALK_TURN_EXTERNAL_IP="$turn_external_ip" \
      DIREXTALK_CLOUD_WORKER_HOST_REGION="$cloud_worker_host_region" \
        "$split/scripts/provision-local.sh" "$run_dir"; then
      :
    else
      provision_status=$?
      if [ -e "$run_dir" ]; then
        remove_empty_fresh_run_dir || {
          echo "fresh provision failed (status $provision_status) and left a non-empty or unexpected run directory" >&2
          exit 1
        }
      fi
      exit "$provision_status"
    fi
  fi

  write_stage application_start
  if "$split/scripts/start-local.sh" "$run_dir/.env"; then
    :
  else
    start_status=$?
    if [ "$start_status" -eq 3 ]; then
      agent_attention=true
      echo 'message-server is healthy; continuing Edge and bootstrap export while Agent needs attention' >&2
    else
      cleanup_failed_application_start "$start_status" || exit 1
      exit 1
    fi
  fi
fi

write_stage edge_start
caddyfile=$base/Caddyfile
edge_env=$base/edge.env
[ -f "$script_dir/Caddyfile" ] && [ ! -L "$script_dir/Caddyfile" ] || {
  echo "staged edge Caddy source is missing" >&2
  exit 1
}
[ -f "$script_dir/edge-compose.override.yaml" ] && [ ! -L "$script_dir/edge-compose.override.yaml" ] || {
  echo "staged edge Compose overlay is missing" >&2
  exit 1
}
if [ ! -f "$edge_env" ]; then
  static_sites_root=$(read_pair "$run_dir/.env" DIREXTALK_STATIC_SITES_ROOT)
  edge_env_tmp=$(mktemp "$base/.edge.env.XXXXXX")
  cat >"$edge_env_tmp" <<EOF
DIREXTALK_EDGE_STACK_NAME=${stack}-edge
DIREXTALK_PUBLIC_DOMAIN=$domain
DIREXTALK_MESSAGE_TLS_MODE=edge-terminated
DIREXTALK_MESSAGE_PUBLIC_NETWORK=${stack}-message-public
DIREXTALK_CADDY_IMAGE_IMMUTABLE=$caddy_image
DIREXTALK_CADDY_DATA_VOLUME=${stack}-caddy-data
DIREXTALK_CADDY_CONFIG_VOLUME=${stack}-caddy-config
DIREXTALK_CADDYFILE=$caddyfile
DIREXTALK_STATIC_SITES_ROOT=$static_sites_root
EOF
  chmod 0400 "$edge_env_tmp"
  mv -f "$edge_env_tmp" "$edge_env"
fi
[ -f "$edge_env" ] && [ ! -L "$edge_env" ] || { echo "protected edge environment is unavailable" >&2; exit 1; }
[ "$(stat -c '%u:%a' "$edge_env")" = "0:400" ] || { echo "edge environment must be root-owned mode 0400" >&2; exit 1; }
if [ "$(awk -F= '$1 == "DIREXTALK_STATIC_SITES_ROOT" { count++ } END { print count + 0 }' "$edge_env")" -eq 0 ]; then
  static_sites_root=$(read_pair "$run_dir/.env" DIREXTALK_STATIC_SITES_ROOT)
  edge_env_tmp=$(mktemp "$base/.edge.env.XXXXXX")
  cat "$edge_env" >"$edge_env_tmp"
  printf 'DIREXTALK_STATIC_SITES_ROOT=%s\n' "$static_sites_root" >>"$edge_env_tmp"
  chmod 0400 "$edge_env_tmp"
  mv -f "$edge_env_tmp" "$edge_env"
fi
require_pair "$edge_env" DIREXTALK_EDGE_STACK_NAME "${stack}-edge"
require_pair "$edge_env" DIREXTALK_PUBLIC_DOMAIN "$domain"
require_pair "$edge_env" DIREXTALK_MESSAGE_TLS_MODE edge-terminated
require_pair "$edge_env" DIREXTALK_MESSAGE_PUBLIC_NETWORK "${stack}-message-public"
require_pair "$edge_env" DIREXTALK_CADDY_IMAGE_IMMUTABLE "$caddy_image"
require_pair "$edge_env" DIREXTALK_CADDY_DATA_VOLUME "${stack}-caddy-data"
require_pair "$edge_env" DIREXTALK_CADDY_CONFIG_VOLUME "${stack}-caddy-config"
require_pair "$edge_env" DIREXTALK_CADDYFILE "$caddyfile"
require_pair "$edge_env" DIREXTALK_STATIC_SITES_ROOT "$(read_pair "$run_dir/.env" DIREXTALK_STATIC_SITES_ROOT)"
if ! caddy_tmp=$(mktemp "$base/.Caddyfile.XXXXXX"); then
  echo 'could not create the Caddyfile staging file; refusing to render a literal template' >&2
  exit 1
fi
cleanup_caddy_tmp() { rm -f -- "$caddy_tmp"; }
trap cleanup_caddy_tmp EXIT
sed "s/__DIREXTALK_PUBLIC_DOMAIN__/$domain/g" "$script_dir/Caddyfile" >"$caddy_tmp" || exit 1
chmod 0400 "$caddy_tmp"
if [ -f "$caddyfile" ] && [ ! -L "$caddyfile" ] && cmp -s "$caddy_tmp" "$caddyfile"; then
  caddy_changed=false
  rm -f -- "$caddy_tmp"
else
  caddy_changed=true
  mv -f -- "$caddy_tmp" "$caddyfile"
fi
trap - EXIT
docker volume create --label com.dirextalk.owner="$stack" "${stack}-caddy-data" >/dev/null
docker volume create --label com.dirextalk.owner="$stack" "${stack}-caddy-config" >/dev/null
edge_compose=(docker compose --env-file "$edge_env" -f "$split/edge-compose.yaml" -f "$script_dir/edge-compose.override.yaml")
"${edge_compose[@]}" config --quiet
"${edge_compose[@]}" pull
if [ "$operation" = --reconcile-edge ] && [ "$caddy_changed" = true ]; then
  "${edge_compose[@]}" up -d --wait --force-recreate caddy
else
  "${edge_compose[@]}" up -d --wait
fi
edge_id=$("${edge_compose[@]}" ps -q caddy)
printf '%s\n' "$edge_id" | grep -Eq '^[0-9a-f]{64}$' || { echo "edge Caddy identity is invalid" >&2; exit 1; }
receipt_tmp=$(mktemp "$base/.edge-bootstrap-receipt.XXXXXX")
printf '# dirextalk-edge-bootstrap-receipt-v1\nstack=%s\ncontainer_id=%s\nimage=%s\nnetwork=%s\n' \
  "$stack" "$edge_id" "$caddy_image" "${stack}-message-public" >"$receipt_tmp"
chmod 0400 "$receipt_tmp"
mv -f "$receipt_tmp" "$base/edge-bootstrap-receipt"

if [ "$operation" = --reconcile-edge ]; then
  write_stage completed
  exit 0
fi

mkdir -p "$base/p2p"
chmod 0700 "$base/p2p"
portal_bootstrap=$base/p2p/bootstrap.json
if [ -e "$portal_bootstrap" ] || [ -L "$portal_bootstrap" ]; then
  [ -f "$portal_bootstrap" ] && [ ! -L "$portal_bootstrap" ] || {
    echo 'existing portal bootstrap is not a regular control file' >&2
    exit 1
  }
  [ "$(stat -c '%u:%a' "$portal_bootstrap")" = "$(id -u):400" ] || {
    echo 'existing portal bootstrap owner or mode differs' >&2
    exit 1
  }
  refresh_dir=$(mktemp -d "$base/p2p/.bootstrap-refresh.XXXXXX")
  chmod 0700 "$refresh_dir"
  cleanup_refresh() {
    rm -f "$refresh_dir/bootstrap.json"
    rmdir "$refresh_dir" 2>/dev/null || true
  }
  trap cleanup_refresh EXIT
  "$split/scripts/export-portal-bootstrap.sh" "$run_dir" "$refresh_dir/bootstrap.json"
  cmp "$portal_bootstrap" "$refresh_dir/bootstrap.json" || {
    echo 'existing portal bootstrap differs from the running stack' >&2
    exit 1
  }
  cleanup_refresh
  trap - EXIT
else
  "$split/scripts/export-portal-bootstrap.sh" "$run_dir" "$portal_bootstrap"
fi
[ "$completed" = true ] || touch "$base/.split-deploy-done"
if [ "$agent_attention" = true ]; then
  write_stage agent_needs_attention
  echo 'fresh production bootstrap preserved healthy messaging; Agent recovery is required' >&2
  exit 3
fi
write_stage completed
