#!/usr/bin/env bash
# Install the current deployer/updater integration, bootstrap, and prove the active identity.
set -euo pipefail

source_dir=${1:-}
base=${2:-/var/dirextalk-message-server}
stable_ip=${3:-}
legacy_source=${4:-}
[ -d "$source_dir" ] && [ -n "$stable_ip" ] || {
  echo "usage: reconcile-host.sh <integration-dir> <deployment-dir> <stable-public-ip> [approved-legacy-source]" >&2
  exit 1
}
if [ -n "$legacy_source" ]; then
  for file in adopt-legacy-host.sh legacy-d1-compose.p2p.yml legacy-adopt-compose.yml config.legacy-systemd-caddy.json; do
    [ -f "$source_dir/$file" ] || { echo "legacy integration file is missing: $file" >&2; exit 1; }
  done
fi

if [ -n "$legacy_source" ]; then
  bash "$source_dir/adopt-legacy-host.sh" commit "$legacy_source" "$source_dir"
fi

integration_dir="$base/updater"
install -d -m 0755 "$integration_dir"
for file in bootstrap-host.sh install.sh reconcile-host.sh adopt-legacy-host.sh set-desired-state.sh; do
  install -m 0755 "$source_dir/$file" "$integration_dir/$file"
done
for file in release.env config.json dirextalk-updater.service dirextalk-updater-discovery.service dirextalk-updater-discovery.timer; do
  install -m 0644 "$source_dir/$file" "$integration_dir/$file"
done
if [ -n "$legacy_source" ]; then
  install -m 0600 "$source_dir/config.legacy-systemd-caddy.json" "$integration_dir/config.json"
  for file in legacy-d1-compose.p2p.yml legacy-adopt-compose.yml; do
    install -m 0600 "$source_dir/$file" "$integration_dir/$file"
  done
fi

if [ -n "$legacy_source" ]; then
  DIREXTALK_BOOTSTRAP_ADOPT_EXISTING=1 DIREXTALK_LEGACY_ADOPT_SOURCE_DIR="$legacy_source" \
    bash "$integration_dir/bootstrap-host.sh" "$stable_ip"
else
  bash "$integration_dir/bootstrap-host.sh" "$stable_ip"
fi
systemctl is-active --quiet dirextalk-updater.service

# shellcheck disable=SC1091
source "$integration_dir/release.env"
identity=$(/usr/local/bin/dirextalk-updater version)
version=$(printf '%s\n' "$identity" | awk -F'"' '$2 == "version" { print $4; exit }')
commit=$(printf '%s\n' "$identity" | awk -F'"' '$2 == "commit" { print $4; exit }')
sha256=$(sha256sum /usr/local/bin/dirextalk-updater | awk '{print $1}')
[ "$version" = "$UPDATER_PIN_VERSION" ] \
  && [ "$commit" = "$UPDATER_PIN_COMMIT" ] \
  && [ "$sha256" = "$UPDATER_PIN_SHA256" ] || {
    echo "active updater identity does not match the deployer pin" >&2
    exit 1
  }
printf '%s\t%s\t%s\n' "$version" "$commit" "$sha256"
