#!/usr/bin/env bash
# Complete an interrupted first boot after the updater and stable public IP are available.
set -euo pipefail

root=${DIREXTALK_BOOTSTRAP_ROOT:-}
base="$root/var/dirextalk-message-server"
timeout=${DIREXTALK_BOOTSTRAP_TIMEOUT:-900}
adopt_existing=${DIREXTALK_BOOTSTRAP_ADOPT_EXISTING:-0}
legacy_source=${DIREXTALK_LEGACY_ADOPT_SOURCE_DIR:-}
stable_ip=${1:-}
lock_dir="$root/run/lock"
lock_file="$lock_dir/dirextalk-bootstrap.lock"

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

if [ -n "$stable_ip" ]; then
  valid_public_ip "$stable_ip" || { echo "invalid stable public IP" >&2; exit 1; }
  mkdir -p "$base"
  stable_tmp=$(mktemp "$base/.stable-public-ip.XXXXXX")
  printf '%s\n' "$stable_ip" > "$stable_tmp"
  chmod 0600 "$stable_tmp"
  mv -f "$stable_tmp" "$base/stable-public-ip"
fi

ready() {
  [ -s "$base/stable-public-ip" ] \
    && [ -f "$base/.env" ] \
    && [ -f "$base/docker-compose.yml" ] \
    && [ -x "$base/updater/install.sh" ] \
    && [ -f "$base/updater/release.env" ] \
    && { [ "$adopt_existing" = 1 ] || [ -x "$base/init-tokens.sh" ]; }
}

deadline=$(($(date +%s) + timeout))
until ready; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out waiting ${timeout} seconds for stable IP and deployment prerequisites" >&2
    exit 1
  fi
  sleep 5
done

mkdir -p "$lock_dir"
exec 9>"$lock_file"
flock 9

# A concurrent cloud-init/S3 invocation may have completed while this process waited.
ready || { echo "deployment prerequisites disappeared while waiting for bootstrap lock" >&2; exit 1; }
stable_ip=$(cat "$base/stable-public-ip")
valid_public_ip "$stable_ip" || { echo "invalid recorded stable public IP" >&2; exit 1; }

arch=$(uname -m)
os_release="$root/etc/os-release"
[ "$arch" = x86_64 ] || { echo "unsupported host architecture: v1 requires x86_64" >&2; exit 1; }
[ -f "$os_release" ] || { echo "cannot identify supported Ubuntu 22.04 or 24.04 host" >&2; exit 1; }
os_id=$(sed -n 's/^ID=//p' "$os_release" | tr -d '"' | head -n 1)
os_version=$(sed -n 's/^VERSION_ID=//p' "$os_release" | tr -d '"' | head -n 1)
[ "$os_id" = ubuntu ] && { [ "$os_version" = 22.04 ] || [ "$os_version" = 24.04 ]; } || {
  echo "unsupported host distribution: v1 requires Ubuntu 22.04 or 24.04" >&2
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

first_nonempty_env_value() {
  local key=$1
  awk -F= -v key="$key" '
    $1 == key {
      value=substr($0, index($0, "=") + 1)
      if (value != "") { print value; exit }
    }
  ' "$base/.env"
}

turn_secret=$(first_nonempty_env_value TURN_SECRET)
if [ -z "$turn_secret" ]; then
  turn_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fi
p2p_portal_password=$(first_nonempty_env_value P2P_PORTAL_PASSWORD)
if [ -z "$p2p_portal_password" ]; then
  random_number=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  p2p_portal_password=$(printf '%08d' "$((random_number % 100000000))")
fi
[ -n "$turn_secret" ] && [ -n "$p2p_portal_password" ] || {
  echo "failed to establish non-empty service secrets" >&2
  exit 1
}

env_tmp=$(mktemp "$base/.env.XXXXXX")
awk '$0 !~ /^(PUBLIC_IP|TURN_SECRET|P2P_PORTAL_PASSWORD)=/' "$base/.env" > "$env_tmp"
printf 'PUBLIC_IP=%s\n' "$stable_ip" >> "$env_tmp"
printf 'TURN_SECRET=%s\n' "$turn_secret" >> "$env_tmp"
printf 'P2P_PORTAL_PASSWORD=%s\n' "$p2p_portal_password" >> "$env_tmp"
chmod 0600 "$env_tmp"
mv -f "$env_tmp" "$base/.env"

bash "$base/updater/install.sh" "$updater_binary"
if [ "$adopt_existing" = 1 ]; then
  [ "$legacy_source" = /root/dirextalk/dirextalk-message-server ] || {
    echo "legacy adoption source is not approved" >&2
    exit 1
  }
  bash "$base/updater/adopt-legacy-host.sh" probe "$legacy_source" "$base/updater" >/dev/null
  touch "$base/.deploy-done"
  exit 0
fi
mkdir -p "$base/p2p"
chmod 0700 "$base"
cd "$base"
docker compose --env-file .env pull
docker compose --env-file .env up -d
domain=$(awk -F= '$1 == "DOMAIN" { print substr($0, index($0, "=") + 1); exit }' .env)
DOMAIN="$domain" bash init-tokens.sh
touch .deploy-done
