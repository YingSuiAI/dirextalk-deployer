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
  > "$tmp/user-data.yaml"

awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$tmp/user-data.yaml" \
  | base64 -d > "$tmp/bundle.tar.gz"
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"

for path in \
  updater/install.sh \
  updater/bootstrap-host.sh \
  updater/set-desired-state.sh \
  updater/release.env \
  updater/config.json \
  updater/config.legacy-compose-caddy.json \
  updater/dirextalk-updater.service \
  updater/dirextalk-updater-discovery.service \
  updater/dirextalk-updater-discovery.timer; do
  [ -f "$tmp/bundle/$path" ] || { echo "missing updater bundle file: $path" >&2; exit 1; }
done
grep -q 'systemctl cat dirextalk-updater.service' "$tmp/bundle/updater/set-desired-state.sh"
grep -q 'systemctl start dirextalk-updater.service' "$tmp/bundle/updater/set-desired-state.sh"
grep -q -- '--config -' "$tmp/bundle/updater/set-desired-state.sh"
if [ -e "$tmp/bundle/dirextalk-updater" ]; then
  echo "the updater ELF must be downloaded from the pinned independent Release, not embedded in user-data" >&2
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
grep -F -q '"compose_project": "dirextalk-message-server"' "$tmp/bundle/updater/config.json"

awk '
  /^  caddy:/ { in_service=1; next }
  /^  [a-zA-Z0-9_-]+:/ { if (in_service) exit }
  in_service && /message-server:/ { bad=1 }
  END { exit bad ? 1 : 0 }
' "$compose" || { echo "Caddy must not depend on message-server health" >&2; exit 1; }

updater_route=$(grep -n -F 'handle /_dirextalk/updater/v1/jobs/*' "$caddy" | cut -d: -f1)
catch_all=$(grep -n $'^\thandle {$' "$caddy" | cut -d: -f1)
[ -n "$updater_route" ] && [ -n "$catch_all" ] && [ "$updater_route" -lt "$catch_all" ] \
  || { echo "updater Unix-socket route must precede Caddy catch-all" >&2; exit 1; }
grep -F -q 'reverse_proxy unix//run/dirextalk-updater/http.sock' "$caddy"
if grep -F -q 'handle /_dirextalk/updater/v1/*' "$caddy" || grep -q '/control/' "$caddy"; then
  echo "Caddy must expose only public updater job paths, never the control namespace" >&2
  exit 1
fi
for private_path in control/status control/desired-state; do
  if grep -F -q "/_dirextalk/updater/v1/$private_path" "$caddy"; then
    echo "Caddy exposed private updater endpoint: $private_path" >&2
    exit 1
  fi
done

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
grep -q '^After=network-online.target docker.service$' "$main_unit"
grep -q '^Wants=network-online.target docker.service$' "$main_unit"
grep -q '^RuntimeDirectory=dirextalk-updater$' "$main_unit"
grep -q '^RuntimeDirectoryMode=0755$' "$main_unit"
grep -q '^RuntimeDirectoryPreserve=yes$' "$main_unit"
grep -q '^StateDirectory=dirextalk-updater$' "$main_unit"
grep -q '^StateDirectoryMode=0700$' "$main_unit"
grep -q '^ConfigurationDirectory=dirextalk-updater$' "$main_unit"
grep -q '^ConfigurationDirectoryMode=0700$' "$main_unit"
grep -q '^ReadWritePaths=/var/lib/dirextalk-updater /run/dirextalk-updater /var/dirextalk-message-server$' "$main_unit"

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

grep -q 'bash /var/dirextalk-message-server/updater/bootstrap-host.sh' "$tmp/user-data.yaml"
install_line=$(grep -n 'bash "$base/updater/install.sh"' "$tmp/bundle/updater/bootstrap-host.sh" | cut -d: -f1 | head -n1)
compose_line=$(grep -n 'docker compose --env-file .env up -d' "$tmp/bundle/updater/bootstrap-host.sh" | cut -d: -f1 | head -n1)
[ -n "$install_line" ] && [ -n "$compose_line" ] && [ "$install_line" -lt "$compose_line" ] \
  || { echo "host bootstrap must install updater before Compose starts" >&2; exit 1; }

mkdir "$tmp/install-bin"
cp "$ROOT/tests/lib/linux-install.sh" "$tmp/install-bin/install"
chmod 0755 "$tmp/install-bin/install"
PATH="$tmp/install-bin:$PATH" DESTDIR="$tmp/root" DIREXTALK_UPDATER_SKIP_SYSTEMD=1 \
  bash "$tmp/bundle/updater/install.sh" "$fake_updater"

# The installer executes on Ubuntu in production. Git Bash's NTFS test
# filesystem cannot represent owner-only modes, so retain the assertions where
# the underlying filesystem has Unix permissions.
assert_linux_mode() {
  local expected=$1 path=$2
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [ "$(stat -c '%a' "$path")" = "$expected" ]
}

assert_linux_mode 700 "$tmp/root/etc/dirextalk-updater"
assert_linux_mode 600 "$tmp/root/etc/dirextalk-updater/config.json"
assert_linux_mode 600 "$tmp/root/etc/dirextalk-updater/control-token"
assert_linux_mode 700 "$tmp/root/var/lib/dirextalk-updater"
assert_linux_mode 755 "$tmp/root/usr/local/bin/dirextalk-updater"
[ "$(wc -c < "$tmp/root/etc/dirextalk-updater/control-token")" -ge 32 ]
grep -q 'chown root:root' "$tmp/bundle/updater/install.sh"
grep -q 'systemctl start dirextalk-updater-discovery.service' "$tmp/bundle/updater/install.sh"
grep -q 'flock' "$tmp/bundle/updater/bootstrap-host.sh"
grep -q 'docker compose --env-file .env up -d' "$tmp/bundle/updater/bootstrap-host.sh"
grep -F -q 'github.com/YingSuiAI/dirextalk-updater/releases/download/v1.0.6/dirextalk-updater-linux-amd64' "$tmp/bundle/updater/release.env"
grep -F -q 'fc25f8ff811313dfc18c2b4e0f01b46802697385b24395f9c78e634e5ac426e4' "$tmp/bundle/updater/release.env"
if grep -q 'latest/meta-data/public-ipv4\|api.ipify.org\|ifconfig.me' "$tmp/user-data.yaml"; then
  echo "cloud-init must not persist a temporary pre-EIP public address" >&2
  exit 1
fi

echo "updater bundle and Caddy continuity ok"
