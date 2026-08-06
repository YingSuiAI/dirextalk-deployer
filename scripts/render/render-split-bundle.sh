#!/usr/bin/env bash
# Render the host-side consumer bundle for the external Agent stack.
# The message-server repository owns the Compose/runtime contract; the deployer
# packages only the reviewed files that first boot and updater adapters use.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
message_root_explicit=false
if [ "${DIREXTALK_MESSAGE_SERVER_ROOT+x}" = x ]; then
  message_root_explicit=true
fi
packaged_bundle_explicit=false
if [ "${DIREXTALK_SPLIT_BUNDLE_FILE+x}" = x ]; then
  packaged_bundle_explicit=true
fi
message_root=${DIREXTALK_MESSAGE_SERVER_ROOT:-$root/../dirextalk-message-server}
split=$message_root/deploy/split-agent
output=${1:-}
packaged_bundle=${DIREXTALK_SPLIT_BUNDLE_FILE:-$root/scripts/cloud-init/split/canonical-bundle.tar.gz}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

[ -n "$output" ] || {
  echo "usage: $0 OUTPUT_TAR_GZ" >&2
  exit 2
}
case "$output" in
  /*) ;;
  *) output=$(pwd -P)/$output ;;
esac

if { [ "$packaged_bundle_explicit" = true ] || [ "$message_root_explicit" = false ]; } \
  && [ -f "$packaged_bundle" ]; then
  packaged_sha_file=${DIREXTALK_SPLIT_BUNDLE_SHA256_FILE:-$packaged_bundle.sha256}
  [ -f "$packaged_sha_file" ] && [ ! -L "$packaged_sha_file" ] || {
    echo "packaged split bundle SHA-256 file is missing" >&2
    exit 1
  }
  expected_sha=$(awk 'NR == 1 { print $1 }' "$packaged_sha_file")
  printf '%s\n' "$expected_sha" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "packaged split bundle SHA-256 is invalid" >&2
    exit 1
  }
  [ "$(sha256_file "$packaged_bundle" | awk '{print $1}')" = "$expected_sha" ] || {
    echo "packaged split bundle does not match its SHA-256" >&2
    exit 1
  }
  tar -tzf "$packaged_bundle" deploy/split-agent/SOURCE_REVISION >/dev/null || {
    echo "packaged split bundle lacks source provenance" >&2
    exit 1
  }
  tmp=$(mktemp "${output%/*}/.split-agent-bundle.XXXXXX.tar.gz")
  cp "$packaged_bundle" "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$output"
  exit 0
fi

required=(
  compose.yaml
  compose.direct-tls.yaml
  edge-compose.yaml
  apparmor.d/dirextalk-runner-userns
  systemd/dirextalk-extension-runner@.service
  systemd/dirextalk-core-runner@.service
  sysusers.d/dirextalk-split-agent.conf
  scripts/provision-local.sh
  scripts/prepare-runner-cgroups.sh
  scripts/start-local.sh
  scripts/adopt-edge.sh
  scripts/cutover-edge.sh
  scripts/update-agent-local.sh
)

for file in "${required[@]}"; do
  [ -f "$split/$file" ] && [ ! -L "$split/$file" ] || {
    echo "missing canonical split deployment asset: $split/$file" >&2
    exit 1
  }
done

revision=$(git -C "$message_root" rev-parse HEAD)
printf '%s\n' "$revision" | grep -Eq '^[0-9a-f]{40}$' || {
  echo "canonical split source revision is invalid" >&2
  exit 1
}
if ! git -C "$message_root" diff --quiet -- deploy/split-agent \
  || ! git -C "$message_root" diff --cached --quiet -- deploy/split-agent; then
  echo "canonical split deployment source has uncommitted changes; commit it before staging" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
install -d -m 0755 "$work/deploy/split-agent"
mapfile -t runtime_files < <(
  cd "$split"
  find . -type f \
    ! -name '*.test.sh' \
    ! -name 'compose.local.yaml' \
    ! -path './container/*' \
    ! -path './aws/*' \
    ! -name '.gitignore' \
    -print | sed 's#^./##' | LC_ALL=C sort
)
[ "${#runtime_files[@]}" -gt 20 ] || {
  echo "canonical split runtime bundle is unexpectedly incomplete" >&2
  exit 1
}
for file in "${runtime_files[@]}"; do
  install -d -m 0755 "$work/deploy/split-agent/$(dirname "$file")"
  case "$file" in
    scripts/*.sh) mode=0755 ;;
    *) mode=0644 ;;
  esac
  install -m "$mode" "$split/$file" "$work/deploy/split-agent/$file"
done
printf '%s\n' "$revision" >"$work/deploy/split-agent/SOURCE_REVISION"
chmod 0644 "$work/deploy/split-agent/SOURCE_REVISION"
(cd "$work/deploy/split-agent" && find . -type f ! -name SOURCE_FILES.sha256 -print \
  | LC_ALL=C sort | while IFS= read -r file; do sha256_file "$file"; done) \
  >"$work/deploy/split-agent/SOURCE_FILES.sha256"
chmod 0644 "$work/deploy/split-agent/SOURCE_FILES.sha256"

output_dir=${output%/*}
[ -d "$output_dir" ] || {
  echo "output directory does not exist: $output_dir" >&2
  exit 1
}
tmp=$(mktemp "$output_dir/.split-agent-bundle.XXXXXX.tar.gz")
cleanup_tmp() { rm -f "$tmp"; }
trap 'rm -rf "$work"; cleanup_tmp' EXIT
COPYFILE_DISABLE=1 tar -C "$work" -cf - deploy | gzip -n >"$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$output"
trap 'rm -rf "$work"' EXIT
