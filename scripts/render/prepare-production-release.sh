#!/usr/bin/env bash
# Prepare the production split bundle from the current application latest tags.
# Application images remain the latest release channels. Their version and
# revision are recorded only so the remote binary probes have explicit values.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
message_root=${DIREXTALK_MESSAGE_SERVER_ROOT:-$root/../dirextalk-message-server}
release_pin=${DIREXTALK_RELEASE_PIN_FILE:-$root/scripts/cloud-init/split/release.env}
release_bundle=${DIREXTALK_RELEASE_BUNDLE_FILE:-$root/scripts/cloud-init/split/canonical-bundle.tar.gz}
release_bundle_sha=${DIREXTALK_RELEASE_BUNDLE_SHA256_FILE:-$release_bundle.sha256}

die() {
  printf 'prepare production release: %s\n' "$*" >&2
  exit 1
}

is_version() {
  printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

is_revision() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

read_unique_pair() {
  local file=$1 key=$2 value count
  count=$(grep -Ec "^${key}=" "$file")
  [ "$count" -eq 1 ] || return 1
  value=$(sed -n "s/^${key}=//p" "$file")
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

sha256_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

resolve_latest_image() {
  local repository=$1 entrypoint=$2 prefix=$3
  local latest_ref identity version revision probe binary

  latest_ref="docker.io/$repository:latest"
  docker pull --platform linux/amd64 "$latest_ref" >/dev/null \
    || die "could not pull $latest_ref"

  identity=$(docker image inspect "$latest_ref" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "org.opencontainers.image.revision"}}') \
    || die "could not inspect $latest_ref"
  IFS='|' read -r version revision <<<"$identity"
  is_version "$version" || die "$latest_ref has an invalid version label"
  is_revision "$revision" || die "$latest_ref has an invalid revision label"

  for binary in $entrypoint; do
    probe=$(docker run --rm --entrypoint "$binary" "$latest_ref" --version) \
      || die "$latest_ref binary probe failed: $binary"
    [ "$probe" = "$version" ] \
      || die "$latest_ref binary reports $probe instead of $version: $binary"
  done

  case "$prefix" in
    message)
      message_version=$version
      message_revision=$revision
      message_image=$latest_ref
      ;;
    agent)
      agent_version=$version
      agent_revision=$revision
      agent_image=$latest_ref
      ;;
    *) die 'internal image prefix is invalid' ;;
  esac
}

render_release_pin() {
  printf 'DIREXTALK_RELEASE_CATALOG_ORIGIN=%s\n' "$release_catalog_origin"
  printf 'DIREXTALK_MESSAGE_SERVER_VERSION=%s\n' "$message_version"
  printf 'DIREXTALK_MESSAGE_SERVER_IMAGE=%s\n' "$message_image"
  printf 'DIREXTALK_MESSAGE_SOURCE_REVISION=%s\n' "$message_revision"
  printf 'DIREXTALK_SPLIT_SOURCE_REVISION=%s\n' "$split_revision"
  printf 'DIREXTALK_AGENT_VERSION=%s\n' "$agent_version"
  printf 'DIREXTALK_AGENT_IMAGE=%s\n' "$agent_image"
  printf 'DIREXTALK_AGENT_SOURCE_REVISION=%s\n' "$agent_revision"
  printf 'DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=%s\n' "$postgres_image"
  printf 'DIREXTALK_CADDY_IMAGE_IMMUTABLE=%s\n' "$caddy_image"
  printf 'DIREXTALK_COTURN_IMAGE_IMMUTABLE=%s\n' "$coturn_image"
}

command -v git >/dev/null 2>&1 || die 'git is required'
command -v docker >/dev/null 2>&1 || die 'Docker is required'
[ -f "$release_pin" ] && [ ! -L "$release_pin" ] \
  || die 'existing production release settings are unavailable'
[ -d "$message_root" ] && [ ! -L "$message_root" ] \
  || die 'Message Server sibling repository is unavailable'

caddy_image=$(read_unique_pair "$release_pin" DIREXTALK_CADDY_IMAGE_IMMUTABLE) \
  || die 'existing Caddy image setting is invalid'
postgres_image=$(read_unique_pair "$release_pin" DIREXTALK_POSTGRES_IMAGE_IMMUTABLE) \
  || die 'existing PostgreSQL image setting is invalid'
coturn_image=$(read_unique_pair "$release_pin" DIREXTALK_COTURN_IMAGE_IMMUTABLE) \
  || die 'existing coturn image setting is invalid'
release_catalog_origin=$(read_unique_pair "$release_pin" DIREXTALK_RELEASE_CATALOG_ORIGIN) \
  || die 'existing release catalog origin is invalid'
[ "$release_catalog_origin" = https://imadmin.dirextalk.ai ] \
  || die 'production release catalog origin must be https://imadmin.dirextalk.ai'

resolve_latest_image \
  dirextalk/message-server \
  /usr/bin/dirextalk-message-server \
  message
resolve_latest_image \
  dirextalk/agent \
  '/usr/local/bin/dirextalk-agent /usr/local/bin/dirextalk-extension-runner /usr/local/bin/dirextalk-core-runner' \
  agent

split_revision=$(git -C "$message_root" rev-parse HEAD) \
  || die 'could not read the Message Server split source revision'
is_revision "$split_revision" || die 'Message Server split source revision is invalid'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
pin_candidate=$work/release.env
bundle_candidate=$work/canonical-bundle.tar.gz
bundle_sha_candidate=$work/canonical-bundle.tar.gz.sha256

render_release_pin >"$pin_candidate"
DIREXTALK_MESSAGE_SERVER_ROOT="$message_root" \
  bash "$root/scripts/render/render-split-bundle.sh" "$bundle_candidate" \
  || die 'could not render the production split bundle'
[ "$(tar -xOzf "$bundle_candidate" deploy/split-agent/SOURCE_REVISION)" = "$split_revision" ] \
  || die 'rendered production split bundle source revision is incorrect'
bundle_digest=$(sha256_value "$bundle_candidate")
printf '%s  %s\n' "$bundle_digest" "${release_bundle##*/}" >"$bundle_sha_candidate"

install -m 0600 "$bundle_candidate" "$release_bundle"
install -m 0644 "$bundle_sha_candidate" "$release_bundle_sha"
install -m 0644 "$pin_candidate" "$release_pin"

printf 'Prepared production release from latest: Message Server %s, Agent %s\n' \
  "$message_version" "$agent_version"
