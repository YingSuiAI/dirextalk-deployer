#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_updater="$tmp/dirextalk-updater"
head -c 65536 /dev/urandom >"$fake_updater"
chmod 0755 "$fake_updater"

config="$ROOT/scripts/updater/config.json"
if grep -Eq '"(compose_project|caddy_mode|runtime_layout)"' "$config"; then
  echo "updater config retained a removed runtime selector" >&2
  exit 1
fi
grep -Fq '"schema_version": 1' "$config"
grep -Fq '"socket_path": "/run/dirextalk-updater/http.sock"' "$config"

bootstrap="$ROOT/scripts/updater/bootstrap-host.sh"
grep -Fq 'bash "$base/production-ops/bootstrap-production.sh"' "$bootstrap"
if grep -Eq 'docker compose|pin-initial-latest|adopt_existing|legacy_source|deployment_layout' "$bootstrap"; then
  echo "updater bootstrap retained a removed standard/legacy branch" >&2
  exit 1
fi

mkdir "$tmp/install-bin"
cp "$ROOT/tests/lib/linux-install.sh" "$tmp/install-bin/install"
chmod 0755 "$tmp/install-bin/install"
PATH="$tmp/install-bin:$PATH" DESTDIR="$tmp/root" DIREXTALK_UPDATER_SKIP_SYSTEMD=1 \
  bash "$ROOT/scripts/updater/install.sh" "$fake_updater"

assert_linux_mode() {
  local expected=$1 path=$2
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    Darwin|*BSD) [ "$(stat -f '%Lp' "$path")" = "$expected" ] ;;
    *) [ "$(stat -c '%a' "$path")" = "$expected" ] ;;
  esac
}
assert_linux_mode 600 "$tmp/root/etc/dirextalk-updater/config.json"
assert_linux_mode 600 "$tmp/root/etc/dirextalk-updater/control-token"
assert_linux_mode 755 "$tmp/root/usr/local/bin/dirextalk-updater"

grep -Fq 'UPDATER_PIN_VERSION=v1.0.11' "$ROOT/scripts/updater/release.env"
grep -Fq 'UPDATER_PIN_COMMIT=720a2bb824b8b7aef9275db060cfe08c6b93b1ab' "$ROOT/scripts/updater/release.env"
grep -Fq 'UPDATER_PIN_SHA256=17712c2b6ff61fd014c6badd0d0e019f30d54181c168735c61de449e8ad4d790' "$ROOT/scripts/updater/release.env"

echo "split-only updater bundle test passed"
