#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_updater="$tmp/dirextalk-updater"
head -c 65536 /dev/urandom >"$fake_updater"
chmod 0755 "$fake_updater"

config="$ROOT/scripts/updater/config.json"
python3 - "$config" <<'PY'
import json
import pathlib
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schema_version": 1,
    "state_dir": "/var/lib/dirextalk-updater",
    "socket_path": "/run/dirextalk-updater/http.sock",
    "control_token_file": "/etc/dirextalk-updater/control-token",
    "watchdog_enabled": False,
}
if config != expected:
    raise SystemExit(f"unexpected deployer updater config: {config!r}")
PY

bootstrap="$ROOT/scripts/updater/bootstrap-host.sh"
grep -Fq 'bash "$base/production-ops/bootstrap-production.sh"' "$bootstrap"
grep -Fq 'bash "$base/production-ops/reconcile-production.sh"' "$bootstrap"
grep -Fq '.split-deploy-done' "$bootstrap"
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
cmp "$config" "$tmp/root/etc/dirextalk-updater/config.json"

grep -Fq 'UPDATER_PIN_VERSION=v1.0.17' "$ROOT/scripts/updater/release.env"
grep -Fq 'UPDATER_PIN_COMMIT=d10bcae89522c172f9d32ed7d7bbf7c85ffbf77b' "$ROOT/scripts/updater/release.env"
grep -Fq 'UPDATER_PIN_SHA256=029c09b4b2f50090ad88076fbbedf95f0d912a64f9ce888f138ebad4face20ec' "$ROOT/scripts/updater/release.env"

echo "split-only updater bundle test passed"
