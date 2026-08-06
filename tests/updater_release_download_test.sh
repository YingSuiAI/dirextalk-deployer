#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
script="$ROOT/scripts/updater/bootstrap-host.sh"
pin="$ROOT/scripts/updater/release.env"
[ -f "$pin" ] || { echo "missing pinned updater release metadata" >&2; exit 1; }
# shellcheck disable=SC1090
source "$pin"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
base="$root/var/dirextalk-message-server"
calls="$tmp/calls"
mkdir -p "$base/updater" "$base/production-ops" "$base/deploy/split-agent" "$root/etc" "$tmp/bin"
: > "$calls"
cp "$pin" "$base/updater/release.env"
cat > "$root/etc/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF
cat > "$base/.env" <<'EOF'
DOMAIN=service.example.test
EOF
touch "$base/deploy/split-agent/compose.yaml"
printf '#!/bin/sh\nprintf "split-production\\n" >> "$BOOTSTRAP_CALLS"\n' > "$base/production-ops/bootstrap-production.sh"
printf '#!/bin/sh\nprintf "install %%s\\n" "$1" >> "$BOOTSTRAP_CALLS"\n' > "$base/updater/install.sh"
chmod 0755 "$base/production-ops/bootstrap-production.sh" "$base/updater/install.sh"

cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
cat "$UNAME_VALUE"
EOF
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 90
printf 'systemd %s\n' "$SYSTEMD_VERSION"
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl' >> "$BOOTSTRAP_CALLS"; printf ' %q' "$@" >> "$BOOTSTRAP_CALLS"; printf '\n' >> "$BOOTSTRAP_CALLS"
output=""
while [ $# -gt 0 ]; do
  case "$1" in --output) output=$2; shift 2 ;; *) shift ;; esac
done
[ -n "$output" ] || exit 91
if [ "$DOWNLOAD_MODE" = good ]; then
  printf '#!/bin/sh\nprintf "updater %%s\\n" "$*" >> "$BOOTSTRAP_CALLS"\n' > "$output"
else
  printf '%s' "$DOWNLOAD_MODE" > "$output"
fi
EOF
cat > "$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if grep -F -q 'updater %s' "$1"; then digest=$PIN_SHA; else digest=$(printf '0%.0s' {1..64}); fi
printf '%s  %s\n' "$digest" "$1"
EOF
cat > "$tmp/bin/sync" <<'EOF'
#!/usr/bin/env bash
printf 'sync' >> "$BOOTSTRAP_CALLS"; printf ' %q' "$@" >> "$BOOTSTRAP_CALLS"; printf '\n' >> "$BOOTSTRAP_CALLS"
EOF
chmod 0755 "$tmp/bin/"*
case "$(uname -s 2>/dev/null || true)" in
  *MINGW*|*MSYS*|*CYGWIN*)
    cp "$ROOT/tests/lib/linux-flock.sh" "$tmp/bin/flock"
    chmod 0755 "$tmp/bin/flock"
    export DIREXTALK_TEST_FLOCK_DIR="$tmp/flock.lock"
    ;;
esac

# Git Bash's NTFS fixture cannot mark an extensionless downloaded file as
# executable. Preserve the production Linux assertion by representing only the
# fixture's committed updater with Git Bash's executable-suffix lookup.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    cat > "$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=${!#}
/bin/mv "$@"
case "$destination" in
  */dirextalk-updater)
    /bin/mv "$destination" "$destination.exe"
    ;;
esac
EOF
    chmod 0755 "$tmp/bin/mv"
    ;;
esac

printf 'x86_64\n' > "$tmp/uname.value"
printf bad > "$base/dirextalk-updater"
chmod 0755 "$base/dirextalk-updater"
export BOOTSTRAP_CALLS="$calls" PIN_SHA="$UPDATER_PIN_SHA256" DOWNLOAD_MODE=good UNAME_VALUE="$tmp/uname.value" SYSTEMD_VERSION=254
export PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2
bash "$script" 203.0.113.20

grep -F -q 'updater %s' "$base/dirextalk-updater"
assert_linux_mode() {
  local expected=$1 path=$2
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    Darwin|*BSD) [ "$(stat -f '%Lp' "$path")" = "$expected" ] ;;
    *) [ "$(stat -c '%a' "$path")" = "$expected" ] ;;
  esac
}

assert_linux_mode 755 "$base/dirextalk-updater"
grep -F -q "$UPDATER_PIN_URL" "$calls"
if grep '^curl ' "$calls" | grep -qi latest; then
  echo "bootstrap downloaded a mutable updater URL" >&2
  exit 1
fi
grep -q 'sync -f .*\.dirextalk-updater\.download\.' "$calls"
grep -q '^install ' "$calls"
grep -q '^split-production$' "$calls"
if grep -Fq 'pin-initial-latest' "$calls"; then
  echo "bootstrap called the removed updater pin-initial-latest command" >&2
  exit 1
fi

before=$(grep -c '^curl' "$calls")
chmod 0644 "$base/dirextalk-updater"
rm -f "$base/.deploy-done"
bash "$script" 203.0.113.20
after=$(grep -c '^curl' "$calls")
[ "$before" = "$after" ] || { echo "matching updater binary should be reused" >&2; exit 1; }
assert_linux_mode 755 "$base/dirextalk-updater"

printf corrupt > "$base/dirextalk-updater"
rm -f "$base/.deploy-done"
DOWNLOAD_MODE=bad bash "$script" 203.0.113.20 >"$tmp/bad.out" 2>&1 && {
  echo "wrong downloaded updater hash was accepted" >&2
  exit 1
}
[ "$(cat "$base/dirextalk-updater")" = corrupt ] || { echo "failed download replaced existing binary" >&2; exit 1; }

sed -i 's/24\.04/22.04/' "$root/etc/os-release"
: > "$calls"
rm -f "$base/.deploy-done"
if DOWNLOAD_MODE=good bash "$script" 203.0.113.20 >"$tmp/ubuntu22.out" 2>&1; then
  echo "Ubuntu 22.04 host was accepted" >&2
  exit 1
fi
grep -Fq 'production requires Ubuntu 24.04+' "$tmp/ubuntu22.out"
[ ! -s "$calls" ] || { echo "unsupported Ubuntu reached download/split bootstrap" >&2; cat "$calls" >&2; exit 1; }

sed -i 's/22\.04/24.04/' "$root/etc/os-release"
: > "$calls"
rm -f "$base/.deploy-done"
DOWNLOAD_MODE=good bash "$script" 203.0.113.20
grep -q '^split-production$' "$calls"

sed -i 's/24\.04/26.04/' "$root/etc/os-release"
: > "$calls"
rm -f "$base/.deploy-done"
DOWNLOAD_MODE=good bash "$script" 203.0.113.20
grep -q '^split-production$' "$calls"

SYSTEMD_VERSION=253
: > "$calls"
rm -f "$base/.deploy-done"
if DOWNLOAD_MODE=good bash "$script" 203.0.113.20 >"$tmp/systemd253.out" 2>&1; then
  echo "systemd 253 host was accepted" >&2
  exit 1
fi
grep -Fq 'production requires systemd >= 254' "$tmp/systemd253.out"
[ ! -s "$calls" ] || { echo "unsupported systemd reached download/split bootstrap" >&2; cat "$calls" >&2; exit 1; }
SYSTEMD_VERSION=254

sed -i 's/26.04/24.04/' "$root/etc/os-release"
printf 'aarch64\n' > "$tmp/uname.value"
: > "$calls"
if DOWNLOAD_MODE=good bash "$script" 203.0.113.20 >"$tmp/arm64.out" 2>&1; then
  echo "arm64 host was accepted" >&2
  exit 1
fi
[ ! -s "$calls" ] || { echo "unsupported architecture reached download/split bootstrap" >&2; cat "$calls" >&2; exit 1; }

echo "updater pinned release download ok"
