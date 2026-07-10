#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_updater="$tmp/dirextalk-updater"
head -c 65536 /dev/urandom > "$fake_updater"
chmod 0755 "$fake_updater"

bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image 'dirextalk/message-server:v1.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  --updater-binary "$fake_updater" \
  > "$tmp/user-data.yaml"

awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$tmp/user-data.yaml" \
  | base64 -d > "$tmp/bundle.tar.gz"
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"

for path in \
  updater/install.sh \
  updater/config.json \
  updater/dirextalk-updater.service \
  updater/dirextalk-updater-discovery.service \
  updater/dirextalk-updater-discovery.timer; do
  [ -f "$tmp/bundle/$path" ] || { echo "missing updater bundle file: $path" >&2; exit 1; }
done
if [ -e "$tmp/bundle/dirextalk-updater" ]; then
  echo "the updater ELF must be transferred separately, not embedded in size-limited user-data" >&2
  exit 1
fi
[ "$(wc -c < "$tmp/user-data.yaml")" -lt 16384 ] || {
  echo "rendered AWS user-data exceeds the 16384-byte limit" >&2
  exit 1
}

compose="$tmp/bundle/docker-compose.yml"
caddy="$tmp/bundle/Caddyfile"
main_unit="$tmp/bundle/updater/dirextalk-updater.service"
discovery_unit="$tmp/bundle/updater/dirextalk-updater-discovery.service"
timer="$tmp/bundle/updater/dirextalk-updater-discovery.timer"

awk '
  /^  caddy:/ { in_service=1; next }
  /^  [a-zA-Z0-9_-]+:/ { if (in_service) exit }
  in_service && /message-server:/ { bad=1 }
  END { exit bad ? 1 : 0 }
' "$compose" || { echo "Caddy must not depend on message-server health" >&2; exit 1; }

updater_route=$(grep -n -F 'handle /_dirextalk/updater/v1/*' "$caddy" | cut -d: -f1)
catch_all=$(grep -n $'^\thandle {$' "$caddy" | cut -d: -f1)
[ -n "$updater_route" ] && [ -n "$catch_all" ] && [ "$updater_route" -lt "$catch_all" ] \
  || { echo "updater Unix-socket route must precede Caddy catch-all" >&2; exit 1; }
grep -F -q 'reverse_proxy unix//run/dirextalk-updater/http.sock' "$caddy"

extract_service() {
  local name=$1 file=$2
  awk -v service="$name" '
    $0 == "  " service ":" { in_service=1; print; next }
    /^  [a-zA-Z0-9_-]+:/ { if (in_service) exit }
    in_service { print }
  ' "$file"
}

extract_service caddy "$compose" > "$tmp/caddy-service.yml"
extract_service message-server "$compose" > "$tmp/message-service.yml"
grep -F -q '/run/dirextalk-updater:/run/dirextalk-updater:ro' "$tmp/caddy-service.yml"
if grep -q 'control-token\|/etc/dirextalk-updater' "$tmp/caddy-service.yml"; then
  echo "Caddy must never receive the updater control token" >&2
  exit 1
fi
grep -F -q '/run/dirextalk-updater:/run/dirextalk-updater:ro' "$tmp/message-service.yml"
grep -F -q '/etc/dirextalk-updater/control-token:/etc/dirextalk-updater/control-token:ro' "$tmp/message-service.yml"
if grep -q '/var/run/docker.sock\|/run/docker.sock' "$tmp/message-service.yml"; then
  echo "message-server must never receive the Docker socket" >&2
  exit 1
fi

grep -q '^User=root$' "$main_unit"
grep -q '^Group=root$' "$main_unit"
grep -q '^RuntimeDirectory=dirextalk-updater$' "$main_unit"
grep -q '^RuntimeDirectoryMode=0755$' "$main_unit"
grep -q '^StateDirectory=dirextalk-updater$' "$main_unit"
grep -q '^StateDirectoryMode=0700$' "$main_unit"
grep -q '^ConfigurationDirectory=dirextalk-updater$' "$main_unit"
grep -q '^ConfigurationDirectoryMode=0700$' "$main_unit"

grep -q '^OnCalendar=\*-\*-\* 03:00:00$' "$timer"
grep -q '^RandomizedDelaySec=45m$' "$timer"
grep -q '^Persistent=true$' "$timer"
grep -q '^Unit=dirextalk-updater-discovery.service$' "$timer"
grep -q 'trigger-discovery' "$discovery_unit"
grep -q -- '--config /etc/dirextalk-updater/config.json' "$discovery_unit"
if grep -q 'runtime.json\|curl\|\$(cat\|--header' "$discovery_unit" \
  || grep -Eq '^ExecStart=.*[[:space:]]serve([[:space:]]|$)' "$discovery_unit"; then
  echo "daily timer must call the resident Unix-socket control client without token argv or direct state access" >&2
  exit 1
fi

install_line=$(grep -n '/updater/install.sh' "$tmp/user-data.yaml" | cut -d: -f1 | head -n1)
compose_line=$(grep -n 'docker compose --env-file .env up -d' "$tmp/user-data.yaml" | cut -d: -f1 | head -n1)
[ -n "$install_line" ] && [ -n "$compose_line" ] && [ "$install_line" -lt "$compose_line" ] \
  || { echo "updater must install before Compose starts" >&2; exit 1; }

DESTDIR="$tmp/root" DIREXTALK_UPDATER_SKIP_SYSTEMD=1 \
  bash "$tmp/bundle/updater/install.sh" "$fake_updater"
[ "$(stat -c '%a' "$tmp/root/etc/dirextalk-updater")" = 700 ]
[ "$(stat -c '%a' "$tmp/root/etc/dirextalk-updater/config.json")" = 600 ]
[ "$(stat -c '%a' "$tmp/root/etc/dirextalk-updater/control-token")" = 600 ]
[ "$(stat -c '%a' "$tmp/root/var/lib/dirextalk-updater")" = 700 ]
[ "$(stat -c '%a' "$tmp/root/usr/local/bin/dirextalk-updater")" = 755 ]
[ "$(wc -c < "$tmp/root/etc/dirextalk-updater/control-token")" -ge 32 ]
grep -q 'chown root:root' "$tmp/bundle/updater/install.sh"
grep -q 'systemctl start dirextalk-updater-discovery.service' "$tmp/bundle/updater/install.sh"

echo "updater bundle and Caddy continuity ok"
