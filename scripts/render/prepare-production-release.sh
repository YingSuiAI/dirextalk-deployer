#!/usr/bin/env bash
# Resolve mutable release-channel tags once, validate their OCI provenance, and
# atomically freeze the resulting immutable production split release pin.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
message_root=${DIREXTALK_MESSAGE_SERVER_ROOT:-$root/../dirextalk-message-server}
agent_root=${DIREXTALK_AGENT_ROOT:-$root/../dirextalk-agent}
release_pin=${DIREXTALK_RELEASE_PIN_FILE:-$root/scripts/cloud-init/split/release.env}
release_bundle=${DIREXTALK_RELEASE_BUNDLE_FILE:-$root/scripts/cloud-init/split/canonical-bundle.tar.gz}
release_bundle_sha=${DIREXTALK_RELEASE_BUNDLE_SHA256_FILE:-$release_bundle.sha256}

# shellcheck disable=SC1091
source "$root/scripts/lib/json.sh"
# shellcheck disable=SC1091
source "$root/scripts/lib/atomic-write.sh"

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

is_digest() {
  printf '%s\n' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}

require_clean_repository() {
  local repository=$1 label=$2
  [ -d "$repository" ] && [ ! -L "$repository" ] \
    || die "$label sibling repository is unavailable"
  [ "$(git -C "$repository" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || die "$label sibling is not a Git worktree"
  [ -z "$(git -C "$repository" status --porcelain --untracked-files=all)" ] \
    || die "$label sibling worktree is not clean"
}

read_unique_pair() {
  local file=$1 key=$2 value count
  count=$(grep -Ec "^${key}=" "$file")
  [ "$count" -eq 1 ] || return 1
  value=$(sed -n "s/^${key}=//p" "$file")
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

read_unique_label() {
  local file=$1 key=$2
  json_entries "$file" config.Labels | awk -v expected="$key" '
    index($0, expected "=") == 1 {
      count++
      value=substr($0, length(expected) + 2)
    }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  '
}

read_optional_label() {
  local file=$1 key=$2
  json_entries "$file" config.Labels | awk -v expected="$key" '
    index($0, expected "=") == 1 {
      count++
      value=substr($0, length(expected) + 2)
    }
    END {
      if (count > 1) exit 1
      if (count == 1) print value
    }
  '
}

inspect_json() {
  local reference=$1 format=$2 output=$3
  docker buildx imagetools inspect "$reference" --format "$format" >"$output" \
    || die "could not inspect $reference"
  json_valid "$output" >/dev/null || die "registry returned invalid JSON for $reference"
}

inspect_manifest() {
  local reference=$1 output=$2
  inspect_json "$reference" '{{json .Manifest}}' "$output"
}

verify_tag_digest() {
  local reference=$1 expected=$2 output=$3 actual
  inspect_manifest "$reference" "$output"
  actual=$(json_get "$output" digest)
  [ "$actual" = "$expected" ] || die "$reference moved while the release was being prepared"
}

verify_non_image_changes() {
  local sibling=$1 revision=$2 sibling_head=$3 policy=$4 invalid
  [ "$revision" != "$sibling_head" ] || return 0
  case "$policy" in
    message)
      # The production Dockerfile builds from the repository context. These
      # split-only paths are reusable only while the current .dockerignore
      # excludes the complete deploy tree without a negated re-include.
      [ "$(git -C "$sibling" show "$sibling_head:.dockerignore" | grep -Fxc 'deploy/')" -eq 1 ] \
        && ! git -C "$sibling" show "$sibling_head:.dockerignore" | grep -Eq '^![[:space:]]*/?deploy(/|$)' \
        || die 'Message Server split tooling is not excluded from the production image build context'
      invalid=$(git -C "$sibling" diff --name-only --diff-filter=ACDMRTUXB "$revision..$sibling_head" \
        | awk '
          $0 == "deploy/split-agent/README.md" { next }
          $0 == "deploy/split-agent/apparmor.d/dirextalk-runner-userns" { next }
          $0 == "deploy/split-agent/compose.yaml" { next }
          $0 == "deploy/split-agent/compose.production.yaml" { next }
          $0 == "deploy/split-agent/compose.direct-tls.yaml" { next }
          $0 == "deploy/split-agent/edge-compose.yaml" { next }
          $0 ~ /^deploy\/split-agent\/scripts\/[A-Za-z0-9._-]+\.sh$/ { next }
          $0 == "deploy/split-agent/systemd/dirextalk-extension-runner@.service" { next }
          $0 == "deploy/split-agent/systemd/dirextalk-core-runner@.service" { next }
          $0 == "deploy/split-agent/sysusers.d/dirextalk-split-agent.conf" { next }
          { print }
        ') \
        || die 'could not classify Message Server changes after the image revision'
      ;;
    agent)
      invalid=$(git -C "$sibling" diff --name-only --diff-filter=ACDMRTUXB "$revision..$sibling_head" \
        | awk '$0 != "deploy/container/compose.local.yaml" && $0 !~ /(^|\/)[^\/]*_test\.go$/ { print }') \
        || die 'could not classify Agent changes after the image revision'
      ;;
    *) die 'internal image reuse policy is invalid' ;;
  esac
  [ -z "$invalid" ] || die "$policy sibling contains image-affecting changes after $revision: $invalid"
}

resolve_image() {
  local repository=$1 expected_source=$2 expected_title=$3 sibling=$4 prefix=$5
  local manifest_file image_file tag_manifest_file latest_manifest_file
  local digest immutable version revision source title sibling_head

  manifest_file=$work/$prefix-latest-manifest.json
  image_file=$work/$prefix-image.json
  tag_manifest_file=$work/$prefix-version-manifest.json
  latest_manifest_file=$work/$prefix-latest-recheck.json

  inspect_manifest "$repository:latest" "$manifest_file"
  json_check "$manifest_file" \
    'data.mediaType === "application/vnd.oci.image.index.v1+json" && Array.isArray(data.manifests) && data.manifests.some((entry) => entry?.mediaType === "application/vnd.oci.image.manifest.v1+json" && entry?.platform?.os === "linux" && entry?.platform?.architecture === "amd64")' \
    || die "$repository:latest is not an OCI index containing linux/amd64"
  digest=$(json_get "$manifest_file" digest)
  is_digest "$digest" || die "$repository:latest has an invalid OCI digest"
  immutable=$repository@$digest

  # Read labels through the immutable reference so a concurrent latest-tag
  # move can never cross this release candidate's identity boundary.
  inspect_json "$immutable" '{{json .Image}}' "$image_file"
  json_check "$image_file" 'data.os === "linux" && data.architecture === "amd64"' \
    || die "$immutable does not resolve to a linux/amd64 image"
  version=$(read_unique_label "$image_file" org.opencontainers.image.version) \
    || die "$immutable lacks one version label"
  revision=$(read_unique_label "$image_file" org.opencontainers.image.revision) \
    || die "$immutable lacks one revision label"
  title=$(read_unique_label "$image_file" org.opencontainers.image.title) \
    || die "$immutable lacks one title label"
  source=$(read_optional_label "$image_file" org.opencontainers.image.source) \
    || die "$immutable has duplicate source repository labels"
  is_version "$version" || die "$immutable has a non-semver version label"
  is_revision "$revision" || die "$immutable has an invalid source revision label"
  [ "$title" = "$expected_title" ] || die "$immutable has an unexpected artifact title label"
  # The registry repository is fixed by this script. Older immutable Agent
  # releases did not publish image.source; when present it must agree with the
  # fixed repository instead of creating a second provenance identity.
  [ -z "$source" ] || [ "$source" = "$expected_source" ] \
    || die "$immutable has an unexpected source repository label"

  git -C "$sibling" cat-file -e "$revision^{commit}" 2>/dev/null \
    || die "$immutable source revision is absent from its sibling repository"
  git -C "$sibling" merge-base --is-ancestor "$revision" HEAD \
    || die "$immutable source revision is not an ancestor of its sibling HEAD"
  sibling_head=$(git -C "$sibling" rev-parse HEAD)
  is_revision "$sibling_head" || die "$repository sibling HEAD is invalid"
  verify_non_image_changes "$sibling" "$revision" "$sibling_head" "$prefix"

  verify_tag_digest "$repository:$version" "$digest" "$tag_manifest_file"
  verify_tag_digest "$repository:latest" "$digest" "$latest_manifest_file"

  case "$prefix" in
    message)
      message_version=$version
      message_revision=$revision
      message_image=$immutable
      message_head=$sibling_head
      ;;
    agent)
      agent_version=$version
      agent_revision=$revision
      agent_image=$immutable
      agent_head=$sibling_head
      ;;
    *) die 'internal image prefix is invalid' ;;
  esac
}

render_release_pin() {
  printf 'DIREXTALK_RELEASE_CATALOG_ORIGIN=%s\n' "$release_catalog_origin"
  printf 'DIREXTALK_MESSAGE_SERVER_VERSION=%s\n' "$message_version"
  printf 'DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=%s\n' "$message_image"
  printf 'DIREXTALK_MESSAGE_SOURCE_REVISION=%s\n' "$message_revision"
  printf 'DIREXTALK_SPLIT_SOURCE_REVISION=%s\n' "$message_head"
  printf 'DIREXTALK_AGENT_VERSION=%s\n' "$agent_version"
  printf 'DIREXTALK_AGENT_IMAGE_IMMUTABLE=%s\n' "$agent_image"
  printf 'DIREXTALK_AGENT_SOURCE_REVISION=%s\n' "$agent_revision"
  printf 'DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=%s\n' "$postgres_image"
  printf 'DIREXTALK_CADDY_IMAGE_IMMUTABLE=%s\n' "$caddy_image"
  printf 'DIREXTALK_COTURN_IMAGE_IMMUTABLE=%s\n' "$coturn_image"
}

sha256_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

render_bundle_sha() {
  printf '%s  %s\n' "$bundle_digest" "${release_bundle##*/}"
}

command -v git >/dev/null 2>&1 || die 'git is required'
command -v docker >/dev/null 2>&1 || die 'Docker with buildx is required'
[ -f "$release_pin" ] && [ ! -L "$release_pin" ] \
  || die 'existing production release pin is unavailable'
require_clean_repository "$message_root" 'Message Server'
require_clean_repository "$agent_root" 'Agent'

caddy_image=$(read_unique_pair "$release_pin" DIREXTALK_CADDY_IMAGE_IMMUTABLE) \
  || die 'existing Caddy image pin is invalid'
postgres_image=$(read_unique_pair "$release_pin" DIREXTALK_POSTGRES_IMAGE_IMMUTABLE) \
  || die 'existing PostgreSQL image pin is invalid'
coturn_image=$(read_unique_pair "$release_pin" DIREXTALK_COTURN_IMAGE_IMMUTABLE) \
  || die 'existing coturn image pin is invalid'
release_catalog_origin=$(read_unique_pair "$release_pin" DIREXTALK_RELEASE_CATALOG_ORIGIN) \
  || die 'existing release catalog origin is invalid'
[ "$release_catalog_origin" = https://imadmin.dirextalk.ai ] \
  || die 'production release catalog origin must be https://imadmin.dirextalk.ai'
printf '%s\n' "$caddy_image" | grep -Eq '^docker\.io/library/caddy@sha256:[0-9a-f]{64}$' \
  || die 'existing Caddy image pin is not immutable'
printf '%s\n' "$postgres_image" | grep -Eq '^docker\.io/pgvector/pgvector:pg18@sha256:[0-9a-f]{64}$' \
  || die 'existing PostgreSQL image pin must be immutable pgvector/pgvector:pg18'
printf '%s\n' "$coturn_image" | grep -Eq '^docker\.io/coturn/coturn:4\.6\.3-alpine@sha256:[0-9a-f]{64}$' \
  || die 'existing coturn image pin is not immutable'

work=$(mktemp -d)
release_lock=${release_pin}.prepare.lock
release_lock_owned=false
release_bundle_had_original=false
publish_in_progress=false
publish_complete=false

replace_file_from() {
  local source=$1 destination=$2 mode=$3 directory base temporary
  directory=$(dirname "$destination") || return 1
  base=$(basename "$destination") || return 1
  temporary=$(mktemp "$directory/.${base}.publish.XXXXXX") || return 1
  if ! cp "$source" "$temporary" || ! chmod "$mode" "$temporary" \
      || ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
}

restore_release_unit() {
  local status=0
  replace_file_from "$work/original-release.env" "$release_pin" 644 || status=1
  if [ "$release_bundle_had_original" = true ]; then
    replace_file_from "$work/original-canonical-bundle.tar.gz" "$release_bundle" 600 || status=1
    replace_file_from "$work/original-canonical-bundle.tar.gz.sha256" "$release_bundle_sha" 644 || status=1
  else
    rm -f "$release_bundle" "$release_bundle_sha" || status=1
  fi
  return "$status"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$publish_in_progress" = true ] && [ "$publish_complete" = false ]; then
    restore_release_unit \
      || printf 'prepare production release: failed to restore the previous release unit\n' >&2
  fi
  if [ "$release_lock_owned" = true ]; then
    rmdir "$release_lock" 2>/dev/null || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$release_lock" 2>/dev/null \
  || die 'another production release preparation is active or requires lock cleanup'
release_lock_owned=true

resolve_image \
  docker.io/dirextalk/message-server \
  https://github.com/YingSuiAI/dirextalk-message-server \
  'Dirextalk Message Server' \
  "$message_root" message
resolve_image \
  docker.io/dirextalk/agent \
  https://github.com/YingSuiAI/dirextalk-agent \
  'Dirextalk Agent' \
  "$agent_root" agent

# Revalidate both mutable repositories and local provenance immediately before
# the one release-pin mutation. A retry must restart resolution instead of
# crossing into a same-name replacement.
require_clean_repository "$message_root" 'Message Server'
require_clean_repository "$agent_root" 'Agent'
[ "$(git -C "$message_root" rev-parse HEAD)" = "$message_head" ] \
  || die 'Message Server sibling HEAD moved while the release was being prepared'
[ "$(git -C "$agent_root" rev-parse HEAD)" = "$agent_head" ] \
  || die 'Agent sibling HEAD moved while the release was being prepared'
verify_tag_digest docker.io/dirextalk/message-server:latest "${message_image##*@}" \
  "$work/message-final-latest-manifest.json"
verify_tag_digest docker.io/dirextalk/agent:latest "${agent_image##*@}" \
  "$work/agent-final-latest-manifest.json"
verify_tag_digest "docker.io/dirextalk/message-server:$message_version" "${message_image##*@}" \
  "$work/message-final-version-manifest.json"
verify_tag_digest "docker.io/dirextalk/agent:$agent_version" "${agent_image##*@}" \
  "$work/agent-final-version-manifest.json"

[ -d "${release_bundle%/*}" ] && [ -d "${release_bundle_sha%/*}" ] \
  || die 'production split bundle output directory is unavailable'
if [ -e "$release_bundle" ] || [ -L "$release_bundle" ] \
    || [ -e "$release_bundle_sha" ] || [ -L "$release_bundle_sha" ]; then
  [ -f "$release_bundle" ] && [ ! -L "$release_bundle" ] \
    && [ -f "$release_bundle_sha" ] && [ ! -L "$release_bundle_sha" ] \
    || die 'existing production split bundle release unit is incomplete or unsafe'
  release_bundle_had_original=true
fi

pin_candidate=$work/release.env
bundle_candidate=$work/canonical-bundle.tar.gz
bundle_sha_candidate=$work/canonical-bundle.tar.gz.sha256
render_release_pin >"$pin_candidate" \
  || die 'could not render the production release pin candidate'
chmod 0644 "$pin_candidate"
if DIREXTALK_MESSAGE_SERVER_ROOT="$message_root" \
    bash "$root/scripts/render/render-split-bundle.sh" "$bundle_candidate"; then
  :
else
  die 'could not render the production split bundle from the resolved source'
fi
bundle_revision=$(tar -xOzf "$bundle_candidate" deploy/split-agent/SOURCE_REVISION) \
  || die 'rendered production split bundle lacks its source revision'
[ "$bundle_revision" = "$(read_unique_pair "$pin_candidate" DIREXTALK_SPLIT_SOURCE_REVISION)" ] \
  || die 'rendered production split bundle source revision differs from the release pin'
bundle_digest=$(sha256_value "$bundle_candidate")
printf '%s\n' "$bundle_digest" | grep -Eq '^[0-9a-f]{64}$' \
  || die 'rendered production split bundle SHA-256 is invalid'
chmod 0600 "$bundle_candidate"
render_bundle_sha >"$bundle_sha_candidate" \
  || die 'could not render the production split bundle SHA-256 candidate'
chmod 0644 "$bundle_sha_candidate"

# The pin, bundle, and checksum form one release unit. Keep temporary originals
# only for this publication attempt so any ordinary write failure or handled
# signal restores the previously usable unit; no historical release is retained.
cp "$release_pin" "$work/original-release.env" \
  || die 'could not preserve the current release unit for transactional publication'
if [ "$release_bundle_had_original" = true ]; then
  cp "$release_bundle" "$work/original-canonical-bundle.tar.gz" \
    && cp "$release_bundle_sha" "$work/original-canonical-bundle.tar.gz.sha256" \
    || die 'could not preserve the current bundle release unit for transactional publication'
fi
publish_in_progress=true
replace_file_from "$bundle_candidate" "$release_bundle" 600 \
  || die 'could not atomically replace the production split bundle'
replace_file_from "$bundle_sha_candidate" "$release_bundle_sha" 644 \
  || die 'could not atomically replace the production split bundle SHA-256'
replace_file_from "$pin_candidate" "$release_pin" 644 \
  || die 'could not atomically replace the production release pin'
publish_complete=true
printf 'Prepared immutable production release pin: Message Server %s, Agent %s\n' \
  "$message_version" "$agent_version"
