#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
new_binary="$tmp/new-updater"
printf 'new updater\n' > "$new_binary"
chmod 0755 "$new_binary"

prepare_root() {
  local root=$1
  mkdir -p "$root/usr/local/bin" "$root/etc/dirextalk-updater"
  printf 'old updater\n' > "$root/usr/local/bin/dirextalk-updater"
  chmod 0755 "$root/usr/local/bin/dirextalk-updater"
  printf 'existing-control-token\n' > "$root/etc/dirextalk-updater/control-token"
  chmod 0600 "$root/etc/dirextalk-updater/control-token"
}

assert_linux_mode() {
  local expected=$1 path=$2
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [ "$(stat -c '%a' "$path")" = "$expected" ]
}

root="$tmp/success-root"
prepare_root "$root"
mkdir "$tmp/bin-direct"
cp "$ROOT/tests/lib/linux-install.sh" "$tmp/bin-direct/install"
chmod 0755 "$tmp/bin-direct/install"
PATH="$tmp/bin-direct:$PATH" DIREXTALK_TEST_INSTALL_FAIL_PATTERN='*/usr/local/bin/dirextalk-updater' DIREXTALK_TEST_INSTALL_FAIL_CODE=91 DESTDIR="$root" DIREXTALK_UPDATER_SKIP_SYSTEMD=1 \
  bash "$ROOT/scripts/updater/install.sh" "$new_binary"
[ "$(cat "$root/usr/local/bin/dirextalk-updater")" = "new updater" ]
assert_linux_mode 755 "$root/usr/local/bin/dirextalk-updater"
[ -z "$(find "$root/usr/local/bin" -maxdepth 1 -name '.dirextalk-updater.install.*' -print -quit)" ]

root="$tmp/failure-root"
prepare_root "$root"
mkdir "$tmp/bin-mv"
cp "$ROOT/tests/lib/linux-install.sh" "$tmp/bin-mv/install"
cat > "$tmp/bin-mv/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last=${!#}
case "$last" in */usr/local/bin/dirextalk-updater) exit 92 ;; esac
exec /bin/mv "$@"
EOF
chmod 0755 "$tmp/bin-mv/install" "$tmp/bin-mv/mv"
if PATH="$tmp/bin-mv:$PATH" DESTDIR="$root" DIREXTALK_UPDATER_SKIP_SYSTEMD=1 \
    bash "$ROOT/scripts/updater/install.sh" "$new_binary" >/dev/null 2>&1; then
  echo "interrupted final updater rename was accepted" >&2
  exit 1
fi
[ "$(cat "$root/usr/local/bin/dirextalk-updater")" = "old updater" ] || {
  echo "failed final install did not preserve the old updater" >&2
  exit 1
}

# A failure while staging config/units must happen before the binary commit.
root="$tmp/config-failure-root"
prepare_root "$root"
mkdir "$tmp/bin-config"
cp "$ROOT/tests/lib/linux-install.sh" "$tmp/bin-config/install"
chmod 0755 "$tmp/bin-config/install"
if PATH="$tmp/bin-config:$PATH" DIREXTALK_TEST_INSTALL_FAIL_PATTERN='*/etc/dirextalk-updater/config.json' DIREXTALK_TEST_INSTALL_FAIL_CODE=93 DESTDIR="$root" DIREXTALK_UPDATER_SKIP_SYSTEMD=1 \
    bash "$ROOT/scripts/updater/install.sh" "$new_binary" >/dev/null 2>&1; then
  echo "interrupted updater config staging was accepted" >&2
  exit 1
fi
[ "$(cat "$root/usr/local/bin/dirextalk-updater")" = "old updater" ] || {
  echo "config staging failure replaced the old updater too early" >&2
  exit 1
}

install_script="$ROOT/scripts/updater/install.sh"
grep -F -q 'systemctl daemon-reload' "$install_script"
grep -F -q 'systemctl is-active --quiet dirextalk-updater.service' "$install_script"
grep -F -q 'systemctl restart dirextalk-updater.service' "$install_script"
grep -F -q 'systemctl enable --now dirextalk-updater.service' "$install_script"
grep -F -q 'if ! systemctl start dirextalk-updater-discovery.service; then' "$install_script"
grep -F -q 'the timer will retry' "$install_script"

echo "updater atomic final install ok"
