#!/usr/bin/env bash
# Install the current deployer/updater integration, bootstrap, and prove the active identity.
set -euo pipefail

source_dir=${1:-}
base=${2:-/var/dirextalk-message-server}
stable_ip=${3:-}
[ -d "$source_dir" ] && [ -n "$stable_ip" ] || {
  echo "usage: reconcile-host.sh <integration-dir> <deployment-dir> <stable-public-ip>" >&2
  exit 1
}

integration_dir="$base/updater"
install -d -m 0755 "$integration_dir"
for file in bootstrap-host.sh install.sh reconcile-host.sh; do
  install -m 0755 "$source_dir/$file" "$integration_dir/$file"
done
for file in release.env config.json dirextalk-updater.service dirextalk-updater-discovery.service dirextalk-updater-discovery.timer; do
  install -m 0644 "$source_dir/$file" "$integration_dir/$file"
done

bash "$integration_dir/bootstrap-host.sh" "$stable_ip"
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
