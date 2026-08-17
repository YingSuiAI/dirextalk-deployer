#!/usr/bin/env bash
# Prepare only Deployer-owned production artifacts. Application releases are
# discovered and frozen independently for each fresh deployment.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
runtime_root=${DIREXTALK_SPLIT_RUNTIME_ROOT:-$root/scripts/cloud-init/split/runtime}
release_pin=${DIREXTALK_RELEASE_PIN_FILE:-$root/scripts/cloud-init/split/release.env}
release_bundle=${DIREXTALK_RELEASE_BUNDLE_FILE:-$root/scripts/cloud-init/split/canonical-bundle.tar.gz}
release_bundle_sha=${DIREXTALK_RELEASE_BUNDLE_SHA256_FILE:-$release_bundle.sha256}

die() {
  printf 'prepare production release: %s\n' "$*" >&2
  exit 1
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

render_release_pin() {
  printf 'DIREXTALK_RELEASE_CATALOG_ORIGIN=%s\n' "$release_catalog_origin"
  printf 'DIREXTALK_SPLIT_SOURCE_REVISION=%s\n' "$split_revision"
  printf 'DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=%s\n' "$postgres_image"
  printf 'DIREXTALK_CADDY_IMAGE_IMMUTABLE=%s\n' "$caddy_image"
  printf 'DIREXTALK_COTURN_IMAGE_IMMUTABLE=%s\n' "$coturn_image"
}

command -v git >/dev/null 2>&1 || die 'git is required'
[ -f "$release_pin" ] && [ ! -L "$release_pin" ] \
  || die 'existing production release settings are unavailable'
[ -d "$runtime_root" ] && [ ! -L "$runtime_root" ] \
  || die 'deployer-owned split runtime is unavailable'

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
pin_candidate=$work/release.env
bundle_candidate=$work/canonical-bundle.tar.gz
bundle_sha_candidate=$work/canonical-bundle.tar.gz.sha256

DIREXTALK_SPLIT_RUNTIME_ROOT="$runtime_root" \
  bash "$root/scripts/render/render-split-bundle.sh" "$bundle_candidate" \
  || die 'could not render the production split bundle'
split_revision=$(tar -xOzf "$bundle_candidate" deploy/split-agent/SOURCE_REVISION) \
  || die 'could not read the rendered split runtime tree revision'
is_revision "$split_revision" || die 'rendered split runtime tree revision is invalid'
render_release_pin >"$pin_candidate"
bundle_digest=$(sha256_value "$bundle_candidate")
printf '%s  %s\n' "$bundle_digest" "${release_bundle##*/}" >"$bundle_sha_candidate"

install -m 0600 "$bundle_candidate" "$release_bundle"
install -m 0644 "$bundle_sha_candidate" "$release_bundle_sha"
install -m 0644 "$pin_candidate" "$release_pin"

printf 'Prepared Deployer production split release %s\n' "$split_revision"
