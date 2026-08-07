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
split_revision=2222222222222222222222222222222222222222
printf 'DOMAIN=service.example.test\nSPLIT_SOURCE_REVISION=%s\n' "$split_revision" >"$base/.env"
chmod 0600 "$base/.env"
touch "$base/deploy/split-agent/compose.yaml"
printf '%s\n' "$split_revision" >"$base/deploy/split-agent/SOURCE_REVISION"
calls="$tmp/calls"
: >"$calls"

cat >"$base/updater/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'install\n' >>"$BOOTSTRAP_CALLS"
EOF
cat >"$base/production-ops/bootstrap-production.sh" <<'EOF'
#!/usr/bin/env bash
printf 'split-production\n' >>"$BOOTSTRAP_CALLS"
touch "$BOOTSTRAP_BASE/.split-deploy-done"
EOF
cat >"$base/production-ops/reconcile-production.sh" <<'EOF'
#!/usr/bin/env bash
printf 'reconcile\n' >>"$BOOTSTRAP_CALLS"
exit "${RECONCILE_STATUS:-0}"
EOF
cat >"$base/dirextalk-updater" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$base/updater/install.sh" "$base/production-ops/bootstrap-production.sh" \
  "$base/production-ops/reconcile-production.sh" "$base/dirextalk-updater"

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
export UPDATER_PIN_SHA256 BOOTSTRAP_CALLS="$calls" BOOTSTRAP_BASE="$base"
PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2 \
  bash "$ROOT/scripts/updater/bootstrap-host.sh" 203.0.113.20

[ "$(cat "$base/.bootstrap-stage")" = completed ]
[ -f "$base/.deploy-done" ]
[ "$(grep -c '^install$' "$calls")" = 1 ]
[ "$(grep -c '^split-production$' "$calls")" = 1 ]
grep -Fxq 203.0.113.20 "$base/stable-public-ip"

PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" \
  bash "$ROOT/scripts/updater/bootstrap-host.sh" --preflight 203.0.113.20
if PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" \
    bash "$ROOT/scripts/updater/bootstrap-host.sh" --preflight 203.0.113.99 >/dev/null 2>&1; then
  echo 'bootstrap preflight accepted a changed stable public IP' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
printf '%s\n' 3333333333333333333333333333333333333333 >"$base/deploy/split-agent/SOURCE_REVISION"
if PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" \
    bash "$ROOT/scripts/updater/bootstrap-host.sh" --preflight 203.0.113.20 >/dev/null 2>&1; then
  echo 'bootstrap preflight accepted a changed canonical split revision' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
printf '%s\n' "$split_revision" >"$base/deploy/split-agent/SOURCE_REVISION"

cp "$calls" "$tmp/calls-before-resume"
PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2 \
  bash "$ROOT/scripts/updater/bootstrap-host.sh" 203.0.113.20
[ "$(grep -c '^install$' "$calls")" = 2 ]
[ "$(grep -c '^split-production$' "$calls")" = 1 ]
[ "$(grep -c '^reconcile$' "$calls")" = 1 ]
second_install_line=$(grep -n '^install$' "$calls" | tail -n 1 | cut -d: -f1)
reconcile_line=$(grep -n '^reconcile$' "$calls" | tail -n 1 | cut -d: -f1)
[ "$second_install_line" -lt "$reconcile_line" ] || {
  echo 'existing bootstrap must install the current updater pin before reconcile' >&2
  exit 1
}
grep -Fxq 203.0.113.20 "$base/stable-public-ip"

if RECONCILE_STATUS=3 PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2 \
    bash "$ROOT/scripts/updater/bootstrap-host.sh" 203.0.113.20 >/dev/null 2>&1; then
  echo 'existing bootstrap accepted an expected-negative portal refresh' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
if RECONCILE_STATUS=17 PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2 \
    bash "$ROOT/scripts/updater/bootstrap-host.sh" 203.0.113.20 >/dev/null 2>&1; then
  echo 'existing bootstrap accepted an infrastructure-failed portal refresh' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]

if grep -Eq 'docker compose|pin-initial-latest|adopt' "$calls"; then
  echo "split bootstrap executed a removed standard/legacy path" >&2
  exit 1
fi

# The real reconcile consumer must run preflight before replacing live updater
# integration files for both protected-negative and infrastructure failures.
reconcile_root="$tmp/reconcile-root"
reconcile_base="$reconcile_root/var/dirextalk-message-server"
mkdir -p "$reconcile_base/updater" "$reconcile_base/deploy/split-agent"
printf 'live-updater-sentinel\n' >"$reconcile_base/updater/bootstrap-host.sh"
printf '203.0.113.20\n' >"$reconcile_base/stable-public-ip"
printf 'SPLIT_SOURCE_REVISION=%s\n' "$split_revision" >"$reconcile_base/.env"
printf '%s\n' 3333333333333333333333333333333333333333 \
  >"$reconcile_base/deploy/split-agent/SOURCE_REVISION"
touch "$reconcile_base/.split-deploy-done"
chmod 0600 "$reconcile_base/stable-public-ip" "$reconcile_base/.env"
before=$(sha256sum "$reconcile_base/updater/bootstrap-host.sh")
if DIREXTALK_BOOTSTRAP_ROOT="$reconcile_root" \
    bash "$ROOT/scripts/updater/reconcile-host.sh" "$ROOT/scripts/updater" \
    "$reconcile_base" 203.0.113.20 >/dev/null 2>&1; then
  echo 'reconcile-host accepted a protected split revision mismatch' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
[ "$before" = "$(sha256sum "$reconcile_base/updater/bootstrap-host.sh")" ]
chmod 0644 "$reconcile_base/stable-public-ip"
if DIREXTALK_BOOTSTRAP_ROOT="$reconcile_root" \
    bash "$ROOT/scripts/updater/reconcile-host.sh" "$ROOT/scripts/updater" \
    "$reconcile_base" 203.0.113.20 >/dev/null 2>&1; then
  echo 'reconcile-host accepted an invalid protected stable IP receipt' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ "$before" = "$(sha256sum "$reconcile_base/updater/bootstrap-host.sh")" ]

echo "split updater bootstrap resume test passed"
