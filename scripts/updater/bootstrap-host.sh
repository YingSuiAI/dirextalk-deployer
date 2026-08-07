#!/usr/bin/env bash
# Complete an interrupted first boot after the updater and stable public IP are available.
set -euo pipefail

root=${DIREXTALK_BOOTSTRAP_ROOT:-}
base="$root/var/dirextalk-message-server"
timeout=${DIREXTALK_BOOTSTRAP_TIMEOUT:-900}
requested_stable_ip=${1:-}
preflight_only=false
record_stable_ip_only=false
case "$requested_stable_ip" in
  --preflight)
    preflight_only=true
    requested_stable_ip=${2:-}
    [ "$#" -eq 2 ] || { echo "usage: bootstrap-host.sh --preflight <stable-public-ip>" >&2; exit 1; }
    ;;
  --record-stable-ip)
    record_stable_ip_only=true
    requested_stable_ip=${2:-}
    [ "$#" -eq 2 ] || { echo "usage: bootstrap-host.sh --record-stable-ip <stable-public-ip>" >&2; exit 1; }
    ;;
esac
lock_dir="$root/run/lock"
lock_file="$lock_dir/dirextalk-bootstrap.lock"
stage_file="$base/.bootstrap-stage"

# The stage marker is diagnostic-only. Keep its contents to a fixed allow-list
# and make failures non-fatal so it cannot change bootstrap semantics.
write_bootstrap_stage() {
  local stage=$1 stage_tmp
  case "$stage" in
    prerequisites|lock|updater|completed) ;;
    *) return 0 ;;
  esac
  if ! mkdir -p "$base" 2>/dev/null; then
    return 0
  fi
  if ! stage_tmp=$(mktemp "$base/.bootstrap-stage.XXXXXX" 2>/dev/null); then
    return 0
  fi
  if printf '%s\n' "$stage" > "$stage_tmp" \
    && chmod 0600 "$stage_tmp" 2>/dev/null \
    && mv -f "$stage_tmp" "$stage_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$stage_tmp" 2>/dev/null || true
}

valid_public_ip() {
  local ip=$1 part
  local -a parts
  case "$ip" in *$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;; esac
  printf '%s\n' "$ip" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [ "$part" -le 255 ] || return 1
  done
}

supported_ubuntu_version() {
  local version=$1 major minor
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)$ ]] || return 1
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  [ "$major" -gt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -ge 4 ]; }
}

record_stable_public_ip() {
  local stable_ip=$1 receipt="$base/stable-public-ip" temporary owner base_identity
  owner="$(id -u):$(id -g)"
  mkdir -p "$base" || return 1
  [ -d "$base" ] && [ ! -L "$base" ] || return 1
  [ "$(stat -c '%u:%g' -- "$base")" = "$owner" ] \
    || { echo "stable public IP receipt directory owner is invalid" >&2; return 1; }
  base_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$base") || return 1
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$receipt")" = "$owner:600" ] \
      || { echo "recorded stable public IP receipt is invalid" >&2; return 1; }
    [ "$(cat -- "$receipt")" = "$stable_ip" ] \
      || { echo "requested stable public IP differs from the protected receipt" >&2; return 3; }
    return 0
  fi
  temporary=$(mktemp "$base/.stable-public-ip.XXXXXX") || return 1
  if ! printf '%s\n' "$stable_ip" >"$temporary" \
      || ! chmod 0600 "$temporary" \
      || ! sync -f "$temporary" \
      || [ "$(stat -c '%d:%i:%u:%g:%a' -- "$base")" != "$base_identity" ] \
      || ! mv -f "$temporary" "$receipt"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
  sync -f "$base" || return 1
  [ "$(stat -c '%d:%i:%u:%g:%a' -- "$base")" = "$base_identity" ] \
    && [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$receipt")" = "$owner:600" ] \
    && [ "$(cat -- "$receipt")" = "$stable_ip" ]
}

read_unique_value() {
  local file=$1 key=$2 count value
  count=$(awk -F= -v wanted="$key" '$1 == wanted {n++} END {print n+0}' "$file")
  [ "$count" -eq 1 ] || { echo "$file must contain exactly one $key" >&2; return 1; }
  value=$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0,length(wanted)+2); exit}' "$file")
  [ -n "$value" ] || { echo "$file contains an empty $key" >&2; return 1; }
  printf '%s' "$value"
}

preflight_existing_host() {
  local expected_ip=$1 receipt="$base/stable-public-ip" env_file="$base/.env"
  local source_revision_file="$base/deploy/split-agent/SOURCE_REVISION"
  local recorded_ip recorded_revision canonical_revision owner
  owner="$(id -u):$(id -g)"

  [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$receipt")" = "$owner:600" ] \
    || { echo "recorded stable public IP receipt is invalid" >&2; return 1; }
  recorded_ip=$(cat -- "$receipt")
  valid_public_ip "$recorded_ip" || { echo "recorded stable public IP receipt is malformed" >&2; return 1; }
  [ "$recorded_ip" = "$expected_ip" ] \
    || { echo "requested stable public IP differs from the protected receipt" >&2; return 3; }

  if [ -e "$base/.split-deploy-done" ] || [ -L "$base/.split-deploy-done" ]; then
    [ -f "$base/.split-deploy-done" ] && [ ! -L "$base/.split-deploy-done" ] \
      && [ "$(stat -c '%u:%g' -- "$base/.split-deploy-done")" = "$owner" ] \
      || { echo "completed split deployment marker is invalid" >&2; return 1; }
    [ -f "$env_file" ] && [ ! -L "$env_file" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$env_file")" = "$owner:600" ] \
      || { echo "protected root environment is invalid" >&2; return 1; }
    [ -f "$source_revision_file" ] && [ ! -L "$source_revision_file" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$source_revision_file")" = "$owner:644" ] \
      || { echo "staged canonical split source revision is invalid" >&2; return 1; }
    recorded_revision=$(read_unique_value "$env_file" SPLIT_SOURCE_REVISION) || return 1
    canonical_revision=$(cat -- "$source_revision_file")
    printf '%s\n' "$canonical_revision" | grep -Eq '^[0-9a-f]{40}$' \
      || { echo "staged canonical split source revision is malformed" >&2; return 1; }
    if [ "$recorded_revision" != "$canonical_revision" ]; then
      [ -n "${DIREXTALK_AUTHORIZED_SPLIT_SOURCE_REVISION:-}" ] \
        && [ "$canonical_revision" = "$DIREXTALK_AUTHORIZED_SPLIT_SOURCE_REVISION" ] \
        || { echo "protected split source revision differs from the staged canonical runtime" >&2; return 3; }
    fi
  fi
}

if [ -n "$requested_stable_ip" ]; then
  valid_public_ip "$requested_stable_ip" || { echo "invalid stable public IP" >&2; exit 1; }
fi

if [ "$preflight_only" = true ]; then
  preflight_existing_host "$requested_stable_ip"
  exit $?
fi

ready() {
  [ -s "$base/stable-public-ip" ] \
    && [ -f "$base/.env" ] \
    && [ -x "$base/production-ops/bootstrap-production.sh" ] \
    && [ -x "$base/production-ops/reconcile-production.sh" ] \
    && [ -f "$base/deploy/split-agent/compose.yaml" ] \
    && [ -x "$base/updater/install.sh" ] \
    && [ -f "$base/updater/release.env" ]
}

bootstrap_lock_inherited=false
if [ -n "${DIREXTALK_BOOTSTRAP_LOCK_FD:-}" ]; then
  printf '%s\n' "$DIREXTALK_BOOTSTRAP_LOCK_FD" | grep -Eq '^[0-9]+$' \
    || { echo "inherited bootstrap lock descriptor is invalid" >&2; exit 1; }
  [ -e "/proc/self/fd/$DIREXTALK_BOOTSTRAP_LOCK_FD" ] \
    || { echo "inherited bootstrap lock descriptor is unavailable" >&2; exit 1; }
  [ "$(readlink -f "/proc/self/fd/$DIREXTALK_BOOTSTRAP_LOCK_FD")" = "$(readlink -f "$lock_file")" ] \
    || { echo "inherited bootstrap lock descriptor targets the wrong file" >&2; exit 1; }
  eval "exec 9>&$DIREXTALK_BOOTSTRAP_LOCK_FD"
  flock -n 9 || { echo "inherited bootstrap lock is not held" >&2; exit 1; }
  bootstrap_lock_inherited=true
else
  mkdir -p "$lock_dir"
  exec 9>"$lock_file"
  flock 9
fi

write_bootstrap_stage lock
write_bootstrap_stage prerequisites
if [ -n "$requested_stable_ip" ]; then
  record_stable_public_ip "$requested_stable_ip"
fi
if [ "$bootstrap_lock_inherited" = false ]; then
  flock -u 9
fi
[ "$record_stable_ip_only" = false ] || exit 0

deadline=$(($(date +%s) + timeout))
until ready; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out waiting ${timeout} seconds for stable IP and deployment prerequisites" >&2
    exit 1
  fi
  sleep 5
done

if [ "$bootstrap_lock_inherited" = false ]; then
  flock 9
fi
ready || { echo "deployment prerequisites disappeared while waiting for bootstrap lock" >&2; exit 1; }

stable_ip=$(cat "$base/stable-public-ip")
valid_public_ip "$stable_ip" || { echo "invalid recorded stable public IP" >&2; exit 1; }

write_bootstrap_stage updater
arch=$(uname -m)
os_release="$root/etc/os-release"
[ "$arch" = x86_64 ] || { echo "unsupported host architecture: v1 requires x86_64" >&2; exit 1; }
[ -f "$os_release" ] || { echo "cannot identify supported Ubuntu 24.04+ host" >&2; exit 1; }
os_id=$(sed -n 's/^ID=//p' "$os_release" | tr -d '"' | head -n 1)
os_version=$(sed -n 's/^VERSION_ID=//p' "$os_release" | tr -d '"' | head -n 1)
[ "$os_id" = ubuntu ] && supported_ubuntu_version "$os_version" || {
  echo "unsupported host distribution: production requires Ubuntu 24.04+" >&2
  exit 1
}
systemd_version_output=$(systemctl --version 2>/dev/null) || {
  echo "cannot identify supported systemd version: production requires systemd >= 254" >&2
  exit 1
}
systemd_version=$(sed -n '1s/^systemd \([0-9][0-9]*\).*/\1/p' <<<"$systemd_version_output")
[[ "$systemd_version" =~ ^[0-9]+$ ]] && [ "$systemd_version" -ge 254 ] || {
  echo "unsupported systemd version: production requires systemd >= 254" >&2
  exit 1
}

# shellcheck disable=SC1091
source "$base/updater/release.env"
printf '%s\n' "$UPDATER_PIN_VERSION" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || { echo "invalid updater version pin" >&2; exit 1; }
printf '%s\n' "$UPDATER_PIN_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { echo "invalid updater commit pin" >&2; exit 1; }
printf '%s\n' "$UPDATER_PIN_SHA256" | grep -Eq '^[0-9a-f]{64}$' || { echo "invalid updater SHA-256 pin" >&2; exit 1; }
[ "$UPDATER_PIN_OS/$UPDATER_PIN_ARCH/$UPDATER_PIN_UBUNTU_VERSION" = linux/amd64/24.04 ] || { echo "unsupported updater platform pin" >&2; exit 1; }
[ "$UPDATER_PIN_ASSET" = dirextalk-updater-linux-amd64 ] || { echo "invalid updater asset pin" >&2; exit 1; }
[ "$UPDATER_PIN_URL" = "https://github.com/YingSuiAI/dirextalk-updater/releases/download/$UPDATER_PIN_VERSION/$UPDATER_PIN_ASSET" ] || { echo "invalid updater URL pin" >&2; exit 1; }

updater_binary="$base/dirextalk-updater"
current_sha=""
if [ -f "$updater_binary" ]; then
  current_sha=$(sha256sum "$updater_binary" | awk '{print $1}')
fi
if [ "$current_sha" != "$UPDATER_PIN_SHA256" ]; then
  updater_tmp=$(mktemp "$base/.dirextalk-updater.download.XXXXXX")
  cleanup_updater_tmp() { rm -f "$updater_tmp"; }
  trap cleanup_updater_tmp EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --output "$updater_tmp" "$UPDATER_PIN_URL"
  downloaded_sha=$(sha256sum "$updater_tmp" | awk '{print $1}')
  [ "$downloaded_sha" = "$UPDATER_PIN_SHA256" ] || { echo "downloaded updater SHA-256 does not match deployer pin" >&2; exit 1; }
  chmod 0755 "$updater_tmp"
  sync -f "$updater_tmp"
  mv -f "$updater_tmp" "$updater_binary"
  sync -f "$base"
  trap - EXIT
fi
chmod 0755 "$updater_binary"
[ -x "$updater_binary" ] || { echo "verified updater binary is not executable" >&2; exit 1; }

bash "$base/updater/install.sh" "$updater_binary"
if [ -e "$base/.split-deploy-done" ] || [ -L "$base/.split-deploy-done" ]; then
  [ -f "$base/.split-deploy-done" ] && [ ! -L "$base/.split-deploy-done" ] \
    && [ "$(stat -c '%u' "$base/.split-deploy-done")" = "$(id -u)" ] \
    || { echo "completed split deployment marker is invalid" >&2; exit 1; }
  if bash "$base/production-ops/reconcile-production.sh"; then
    :
  else
    reconcile_status=$?
    case "$reconcile_status" in
      3) echo "existing production reconcile reported an expected negative state" >&2; exit 3 ;;
      *) echo "existing production reconcile failed" >&2; exit 1 ;;
    esac
  fi
else
  if bash "$base/production-ops/bootstrap-production.sh"; then
    :
  else
    bootstrap_status=$?
    case "$bootstrap_status" in
      3) echo "fresh production bootstrap reported an expected negative state" >&2; exit 3 ;;
      *) echo "fresh production bootstrap failed" >&2; exit 1 ;;
    esac
  fi
fi
touch "$base/.deploy-done"
write_bootstrap_stage completed
