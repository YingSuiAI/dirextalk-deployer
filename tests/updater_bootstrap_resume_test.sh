#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
script="$ROOT/scripts/updater/bootstrap-host.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
calls="$tmp/calls"
mkdir -p "$root/var/dirextalk-message-server/updater" "$tmp/bin"
: > "$calls"

if DIREXTALK_BOOTSTRAP_ROOT="$root" DIREXTALK_BOOTSTRAP_TIMEOUT=0 bash "$script" >"$tmp/timeout.out" 2>&1; then
  echo "bootstrap without uploaded prerequisites must time out" >&2
  exit 1
fi
grep -q 'timed out' "$tmp/timeout.out"

cat > "$root/var/dirextalk-message-server/.env" <<'EOF'
DOMAIN=service.example.test
PUBLIC_IP=198.51.100.10
P2P_PORTAL_PASSWORD=
P2P_PORTAL_PASSWORD=
EOF
touch "$root/var/dirextalk-message-server/docker-compose.yml"
printf '#!/bin/sh\nprintf "init\\n" >> "$BOOTSTRAP_CALLS"\n' > "$root/var/dirextalk-message-server/init-tokens.sh"
printf '#!/bin/sh\nprintf "install %%s\\n" "$1" >> "$BOOTSTRAP_CALLS"\n' > "$root/var/dirextalk-message-server/updater/install.sh"
printf '#!/bin/sh\nexit 0\n' > "$root/var/dirextalk-message-server/dirextalk-updater"
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
chmod 0755 "$tmp/bin/docker"

export BOOTSTRAP_CALLS="$calls" BOOTSTRAP_ENV="$root/var/dirextalk-message-server/.env"
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
grep -q '^install ' "$calls"
grep -q 'docker compose --env-file .env pull' "$calls"
grep -q 'docker compose --env-file .env up -d' "$calls"
grep -q '^init$' "$calls"
if grep -q '^invalid-secret ' "$calls"; then
  cat "$calls" >&2
  exit 1
fi
grep -q 'flock' "$script"

bash "$script" 203.0.113.20
[ -f "$root/var/dirextalk-message-server/.deploy-done" ]

echo "updater bootstrap resumes after timeout ok"
