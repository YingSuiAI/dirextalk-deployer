#!/usr/bin/env bash
set -euo pipefail

binary=${1:-}
[ -n "$binary" ] && [ -f "$binary" ] || { echo "usage: install.sh <dirextalk-updater-binary>" >&2; exit 1; }
root=${DESTDIR:-}
if [ -z "$root" ] && [ "$(id -u)" -ne 0 ]; then
  echo "dirextalk updater installation requires root" >&2
  exit 1
fi
here=$(cd "$(dirname "$0")" && pwd)

install -d -m 0755 "$root/usr/local/bin" "$root/etc/systemd/system"
install -d -m 0700 "$root/etc/dirextalk-updater" "$root/var/lib/dirextalk-updater"
install -m 0600 "$here/config.json" "$root/etc/dirextalk-updater/config.json"
install -m 0644 "$here/dirextalk-updater.service" "$root/etc/systemd/system/dirextalk-updater.service"
install -m 0644 "$here/dirextalk-updater-discovery.service" "$root/etc/systemd/system/dirextalk-updater-discovery.service"
install -m 0644 "$here/dirextalk-updater-discovery.timer" "$root/etc/systemd/system/dirextalk-updater-discovery.timer"

token="$root/etc/dirextalk-updater/control-token"
if [ ! -s "$token" ]; then
  umask 077
  temporary="$token.tmp.$$"
  trap 'rm -f "$temporary"' EXIT
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$token"
  trap - EXIT
fi
chmod 0700 "$root/etc/dirextalk-updater" "$root/var/lib/dirextalk-updater"
chmod 0600 "$root/etc/dirextalk-updater/config.json" "$token"

# Commit the service binary only after all integration/config staging succeeds.
binary_target="$root/usr/local/bin/dirextalk-updater"
binary_tmp=$(mktemp "$root/usr/local/bin/.dirextalk-updater.install.XXXXXX")
cleanup_binary_tmp() { rm -f "$binary_tmp"; }
trap cleanup_binary_tmp EXIT
install -m 0600 "$binary" "$binary_tmp"
chmod 0755 "$binary_tmp"
sync -f "$binary_tmp"
mv -f "$binary_tmp" "$binary_target"
sync -f "$root/usr/local/bin"
trap - EXIT

if [ "$(id -u)" -eq 0 ]; then
  chown root:root \
    "$root/usr/local/bin/dirextalk-updater" \
    "$root/etc/dirextalk-updater" \
    "$root/etc/dirextalk-updater/config.json" \
    "$token" \
    "$root/var/lib/dirextalk-updater" \
    "$root/etc/systemd/system/dirextalk-updater.service" \
    "$root/etc/systemd/system/dirextalk-updater-discovery.service" \
    "$root/etc/systemd/system/dirextalk-updater-discovery.timer"
fi

if [ "${DIREXTALK_UPDATER_SKIP_SYSTEMD:-0}" != "1" ] && [ -z "$root" ]; then
  systemctl daemon-reload
  if systemctl is-active --quiet dirextalk-updater.service; then
    systemctl restart dirextalk-updater.service
  else
    systemctl enable --now dirextalk-updater.service
  fi
  systemctl start dirextalk-updater-discovery.service
  systemctl enable --now dirextalk-updater-discovery.timer
fi
