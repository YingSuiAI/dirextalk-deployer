#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
base="$root/var/dirextalk-message-server"
mkdir -p "$base/updater" "$base/production-ops" "$base/deploy/split-agent" "$root/etc" "$root/run/lock" "$tmp/bin"
printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$root/etc/os-release"
cp "$ROOT/scripts/updater/release.env" "$base/updater/release.env"
printf 'DOMAIN=service.example.test\n' >"$base/.env"
chmod 0600 "$base/.env"
touch "$base/deploy/split-agent/compose.yaml"
calls="$tmp/calls"
: >"$calls"

cat >"$base/updater/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'install\n' >>"$BOOTSTRAP_CALLS"
EOF
cat >"$base/production-ops/bootstrap-production.sh" <<'EOF'
#!/usr/bin/env bash
printf 'split-production\n' >>"$BOOTSTRAP_CALLS"
EOF
cat >"$base/dirextalk-updater" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$base/updater/install.sh" "$base/production-ops/bootstrap-production.sh" "$base/dirextalk-updater"

cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  */dirextalk-updater) printf '%s  %s\n' "$UPDATER_PIN_SHA256" "$1" ;;
  *) exec /usr/bin/sha256sum "$@" ;;
esac
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 90
printf 'systemd 254\n'
EOF
chmod 0755 "$tmp/bin/sha256sum" "$tmp/bin/systemctl"

# shellcheck disable=SC1090
source "$ROOT/scripts/updater/release.env"
export UPDATER_PIN_SHA256 BOOTSTRAP_CALLS="$calls"
PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2 \
  bash "$ROOT/scripts/updater/bootstrap-host.sh" 203.0.113.20

[ "$(cat "$base/.bootstrap-stage")" = completed ]
[ -f "$base/.deploy-done" ]
[ "$(grep -c '^install$' "$calls")" = 1 ]
[ "$(grep -c '^split-production$' "$calls")" = 1 ]
grep -Fxq 203.0.113.20 "$base/stable-public-ip"

cp "$calls" "$tmp/calls-before-resume"
PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2 \
  bash "$ROOT/scripts/updater/bootstrap-host.sh" 203.0.113.99
cmp "$tmp/calls-before-resume" "$calls"
grep -Fxq 203.0.113.20 "$base/stable-public-ip"

if grep -Eq 'docker compose|pin-initial-latest|adopt' "$calls"; then
  echo "split bootstrap executed a removed standard/legacy path" >&2
  exit 1
fi

echo "split updater bootstrap resume test passed"
