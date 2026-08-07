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

require_digest() {
  printf '%s\n' "$2" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$' || {
    echo "$1 must be an immutable image digest" >&2
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
[ -f "$split/SOURCE_REVISION" ] || { echo "staged canonical split source is missing" >&2; exit 1; }
[ -f "$split/SOURCE_FILES.sha256" ] || { echo "staged canonical split source manifest is missing" >&2; exit 1; }
(cd "$split" && sha256sum -c --status SOURCE_FILES.sha256) || {
  echo "staged canonical split source differs from its manifest" >&2
  exit 1
}

domain=$(read_env DOMAIN)
printf '%s\n' "$domain" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' || {
  echo "protected bootstrap domain is invalid" >&2
  exit 1
}
message_image=$(read_env MESSAGE_SERVER_IMAGE)
agent_image=$(read_env AGENT_IMAGE)
postgres_image=$(read_env POSTGRES_IMAGE)
caddy_image=$(read_env CADDY_IMAGE)
message_revision=$(read_env MESSAGE_SOURCE_REVISION)
split_revision=$(read_env SPLIT_SOURCE_REVISION)
runtime_split_revision=${DIREXTALK_AUTHORIZED_SPLIT_SOURCE_REVISION:-$split_revision}
agent_revision=$(read_env AGENT_SOURCE_REVISION)
release_catalog_origin=$(read_env DIREXTALK_RELEASE_CATALOG_ORIGIN)
[ "$release_catalog_origin" = https://imadmin.dirextalk.ai ] \
  || { echo "protected release catalog origin is invalid" >&2; exit 1; }
require_digest MESSAGE_SERVER_IMAGE "$message_image"
require_digest AGENT_IMAGE "$agent_image"
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
  write_stage runner_preparation
  if [ ! -s "$base/runner-preparation.env" ]; then
  if [ -s "$base/split-stack-name" ]; then
    stack=$(cat "$base/split-stack-name")
  else
    stack=d-$(head -c 16 /dev/urandom | base32 | tr '[:upper:]' '[:lower:]' | tr -d '=[:space:]')
    printf '%s\n' "$stack" >"$base/split-stack-name"
    chmod 0600 "$base/split-stack-name"
  fi
  "$split/scripts/prepare-runner-cgroups.sh" "$stack" >"$base/runner-preparation.env"
  chmod 0400 "$base/runner-preparation.env"
  else
    stack=$(cat "$base/split-stack-name")
  fi
  set -a
  # This receipt is generated by the root-owned helper from this exact bundle.
  # shellcheck disable=SC1090
  . "$base/runner-preparation.env"
  set +a

  attestation=$base/image-attestation
  if [ ! -f "$attestation" ]; then
  attestation_tmp=$(mktemp "$base/.image-attestation.XXXXXX")
  cat >"$attestation_tmp" <<EOF
# dirextalk-image-attestation-v2
capability_api_version=v1.0.3
message_source_revision=$message_revision
agent_source_revision=$agent_revision
capability_api_source=published
image.DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=$postgres_image
image.DIREXTALK_UTILITY_IMAGE_IMMUTABLE=$postgres_image
image.DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=$message_image
image.DIREXTALK_AGENT_IMAGE_IMMUTABLE=$agent_image
image.DIREXTALK_COTURN_IMAGE_IMMUTABLE=$coturn_image
EOF
  chmod 0400 "$attestation_tmp"
    mv -f "$attestation_tmp" "$attestation"
  fi

  write_stage provision
  if [ ! -e "$run_dir" ]; then
  DIREXTALK_SPLIT_STACK_NAME="$stack" \
  DIREXTALK_SPLIT_COMPOSE_MODE=production \
  DIREXTALK_MESSAGE_TLS_MODE=edge-terminated \
  DIREXTALK_MESSAGE_SERVER_NAME="$domain" \
  DIREXTALK_CORE_EXTENSION_ENABLED=true \
  DIREXTALK_CORE_WORKLOAD_ENABLED=true \
  DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE="$message_image" \
  DIREXTALK_AGENT_IMAGE_IMMUTABLE="$agent_image" \
  DIREXTALK_POSTGRES_IMAGE_IMMUTABLE="$postgres_image" \
  DIREXTALK_COTURN_IMAGE_IMMUTABLE="$coturn_image" \
  DIREXTALK_RELEASE_CATALOG_ORIGIN="$release_catalog_origin" \
  DIREXTALK_TURN_EXTERNAL_IP="$turn_external_ip" \
  DIREXTALK_IMAGE_ATTESTATION_SOURCE_FILE="$attestation" \
      "$split/scripts/provision-local.sh" "$run_dir"
  fi

  write_stage application_start
  "$split/scripts/start-local.sh" "$run_dir/.env"
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
EOF
  chmod 0400 "$edge_env_tmp"
  mv -f "$edge_env_tmp" "$edge_env"
fi
[ -f "$edge_env" ] && [ ! -L "$edge_env" ] || { echo "protected edge environment is unavailable" >&2; exit 1; }
[ "$(stat -c '%u:%a' "$edge_env")" = "0:400" ] || { echo "edge environment must be root-owned mode 0400" >&2; exit 1; }
require_pair "$edge_env" DIREXTALK_EDGE_STACK_NAME "${stack}-edge"
require_pair "$edge_env" DIREXTALK_PUBLIC_DOMAIN "$domain"
require_pair "$edge_env" DIREXTALK_MESSAGE_TLS_MODE edge-terminated
require_pair "$edge_env" DIREXTALK_MESSAGE_PUBLIC_NETWORK "${stack}-message-public"
require_pair "$edge_env" DIREXTALK_CADDY_IMAGE_IMMUTABLE "$caddy_image"
require_pair "$edge_env" DIREXTALK_CADDY_DATA_VOLUME "${stack}-caddy-data"
require_pair "$edge_env" DIREXTALK_CADDY_CONFIG_VOLUME "${stack}-caddy-config"
require_pair "$edge_env" DIREXTALK_CADDYFILE "$caddyfile"
caddy_tmp=$(mktemp "$base/.Caddyfile.XXXXXX")
sed "s/__DIREXTALK_PUBLIC_DOMAIN__/$domain/g" "$script_dir/Caddyfile" >"$caddy_tmp"
chmod 0400 "$caddy_tmp"
mv -f "$caddy_tmp" "$caddyfile"
docker volume create --label com.dirextalk.owner="$stack" "${stack}-caddy-data" >/dev/null
docker volume create --label com.dirextalk.owner="$stack" "${stack}-caddy-config" >/dev/null
edge_compose=(docker compose --env-file "$edge_env" -f "$split/edge-compose.yaml" -f "$script_dir/edge-compose.override.yaml")
"${edge_compose[@]}" config --quiet
"${edge_compose[@]}" pull
"${edge_compose[@]}" up -d --wait
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
write_stage completed
