#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
script="$ROOT/scripts/updater/bootstrap-host.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
calls="$tmp/calls"
stage_file="$root/var/dirextalk-message-server/.bootstrap-stage"
mkdir -p "$root/var/dirextalk-message-server/updater" "$root/etc" "$tmp/bin"
: > "$calls"
cp "$ROOT/scripts/updater/release.env" "$root/var/dirextalk-message-server/updater/release.env"
cat > "$root/etc/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF

if DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=0 bash "$script" >"$tmp/timeout.out" 2>&1; then
  echo "bootstrap without uploaded prerequisites must time out" >&2
  exit 1
fi
grep -q 'timed out' "$tmp/timeout.out"
[ "$(cat "$stage_file")" = prerequisites ]

cat > "$root/var/dirextalk-message-server/.env" <<'EOF'
DOMAIN=service.example.test
PUBLIC_IP=198.51.100.10
P2P_PORTAL_PASSWORD=
P2P_PORTAL_PASSWORD=
EOF
touch "$root/var/dirextalk-message-server/docker-compose.yml"
printf '#!/bin/sh\nprintf "init\\n" >> "$BOOTSTRAP_CALLS"\n' > "$root/var/dirextalk-message-server/init-tokens.sh"
printf '#!/bin/sh\nprintf "install %%s\\n" "$1" >> "$BOOTSTRAP_CALLS"\n' > "$root/var/dirextalk-message-server/updater/install.sh"
printf '#!/bin/sh\nprintf "pin %%s\\n" "$*" >> "$BOOTSTRAP_CALLS"\n' > "$root/var/dirextalk-message-server/dirextalk-updater"
chmod 0755 "$root/var/dirextalk-message-server/init-tokens.sh" "$root/var/dirextalk-message-server/updater/install.sh" "$root/var/dirextalk-message-server/dirextalk-updater"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${*: -2}" = "up -d" ]; then
  for key in TURN_SECRET P2P_PORTAL_PASSWORD; do
    count=$(grep -c "^${key}=" "$BOOTSTRAP_ENV")
    value=$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$BOOTSTRAP_ENV")
    [ "$count" = 1 ] && [ -n "$value" ] || {
      printf 'invalid-secret %s count=%s value=%s\n' "$key" "$count" "$value" >> "$BOOTSTRAP_CALLS"
      exit 80
    }
  done
fi
printf 'docker' >> "$BOOTSTRAP_CALLS"
printf ' %s' "$@" >> "$BOOTSTRAP_CALLS"
printf '\n' >> "$BOOTSTRAP_CALLS"
EOF
cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'x86_64\n'
EOF
cat > "$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf '%s  %s\n' "$PIN_SHA" "$1"
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "matching updater binary should not be downloaded" >&2
exit 99
EOF
chmod 0755 "$tmp/bin/docker"
chmod 0755 "$tmp/bin/uname" "$tmp/bin/sha256sum" "$tmp/bin/curl"
case "$(uname -s 2>/dev/null || true)" in
  *MINGW*|*MSYS*|*CYGWIN*)
    cp "$ROOT/tests/lib/linux-flock.sh" "$tmp/bin/flock"
    chmod 0755 "$tmp/bin/flock"
    export DIREXTALK_TEST_FLOCK_DIR="$tmp/flock.lock"
    ;;
esac

export BOOTSTRAP_CALLS="$calls" BOOTSTRAP_ENV="$root/var/dirextalk-message-server/.env"
source "$ROOT/scripts/updater/release.env"
export PIN_SHA="$UPDATER_PIN_SHA256"
export PATH="$tmp/bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=2
bash "$script" 203.0.113.20 &
first_pid=$!
bash "$script" 203.0.113.20 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
grep -q '^PUBLIC_IP=203\.0\.113\.20$' "$root/var/dirextalk-message-server/.env"
[ "$(grep -c '^PUBLIC_IP=' "$root/var/dirextalk-message-server/.env")" = 1 ]
for key in TURN_SECRET P2P_PORTAL_PASSWORD; do
  [ "$(grep -c "^${key}=" "$root/var/dirextalk-message-server/.env")" = 1 ]
  grep -q "^${key}=." "$root/var/dirextalk-message-server/.env"
done
[ -f "$root/var/dirextalk-message-server/.deploy-done" ]
[ "$(cat "$stage_file")" = completed ]
[ "$(wc -l < "$stage_file")" -eq 1 ]
! grep -Eq 'service\.example\.test|203\.0\.113\.20|TURN_SECRET|P2P_PORTAL_PASSWORD|token|secret' "$stage_file"
for expected in '^install ' 'docker compose --env-file .env pull' 'docker compose --env-file .env up -d' '^pin ' '^init$'; do
  [ "$(grep -c -- "$expected" "$calls")" = 1 ] || {
    echo "only the incomplete bootstrap owner may run: $expected" >&2
    cat "$calls" >&2
    exit 1
  }
done
if grep -q '^invalid-secret ' "$calls"; then
  cat "$calls" >&2
  exit 1
fi
grep -q 'flock' "$script"

cp "$calls" "$tmp/calls-after-complete"
cp "$root/var/dirextalk-message-server/stable-public-ip" "$tmp/stable-ip-after-complete"
cp "$root/var/dirextalk-message-server/.env" "$tmp/env-after-complete"
rm -f "$root/var/dirextalk-message-server/init-tokens.sh"
bash "$script" 203.0.113.99
[ -f "$root/var/dirextalk-message-server/.deploy-done" ]
[ ! -e "$root/var/dirextalk-message-server/init-tokens.sh" ] || {
  echo "completed bootstrap must not repair missing prerequisites" >&2
  exit 1
}
[ "$(cat "$stage_file")" = completed ]
cmp -s "$tmp/stable-ip-after-complete" "$root/var/dirextalk-message-server/stable-public-ip" || {
  echo "completed bootstrap must not replace the recorded stable IP" >&2
  exit 1
}
cmp -s "$tmp/env-after-complete" "$root/var/dirextalk-message-server/.env" || {
  echo "completed bootstrap must not rewrite the environment" >&2
  exit 1
}
cmp -s "$tmp/calls-after-complete" "$calls" || {
  echo "completed bootstrap must not rerun updater, compose, pin, or init" >&2
  exit 1
}

echo "updater bootstrap resumes after timeout ok"
