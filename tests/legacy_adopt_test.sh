#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
grep -F -q 'for file in legacy-d1-compose.p2p.yml legacy-adopt-compose.yml; do' \
  "$ROOT/scripts/updater/reconcile-host.sh" || {
  echo "legacy adoption templates are not installed for the bootstrap re-probe" >&2
  exit 1
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
host="$tmp/host"
legacy="$host/root/dirextalk/dirextalk-message-server"
mkdir -p "$legacy" "$host/etc/caddy" "$host/usr/bin" "$tmp/bin"

# The simulated remote host requires Python 3. Git Bash can expose the Windows
# Store python3 alias, which exists on PATH but is not executable. Resolve a
# usable local interpreter once, then provide it through the fake remote PATH.
python_bin=
for candidate in "$(command -v python3 2>/dev/null || true)" "$(command -v python 2>/dev/null || true)"; do
  [ -n "$candidate" ] || continue
  if "$candidate" --version >/dev/null 2>&1; then
    python_bin=$candidate
    break
  fi
done
[ -n "$python_bin" ] || {
  echo "legacy adoption test requires a usable Python interpreter" >&2
  exit 1
}
cat > "$tmp/bin/python3" <<EOF
#!/usr/bin/env bash
exec "$python_bin" "\$@"
EOF
chmod 0755 "$tmp/bin/python3"

# This test simulates the remote Ubuntu host. Git Bash's bundled `install` can
# reject NTFS permission changes even though the fixture only needs the files
# and directory layout, so emulate the remote install forms used by adoption.
cat > "$tmp/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
directory=0
mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) directory=1; shift ;;
    -m) mode=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "unexpected install option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [ "$directory" = 1 ]; then
  for destination in "$@"; do
    mkdir -p "$destination"
    [ -z "$mode" ] || chmod "$mode" "$destination" 2>/dev/null || true
  done
  exit 0
fi
[ "$#" = 2 ] || { echo "unexpected install arguments" >&2; exit 2; }
cp -- "$1" "$2"
[ -z "$mode" ] || chmod "$mode" "$2" 2>/dev/null || true
EOF
chmod 0755 "$tmp/bin/install"

cat > "$host/usr/bin/caddy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'validate --config '*) exit "${FAKE_CADDY_VALIDATE_RC:-0}" ;;
  *) echo "unexpected caddy call: $*" >&2; exit 93 ;;
esac
EOF
chmod 0755 "$host/usr/bin/caddy"
cp "$ROOT/scripts/updater/legacy-d1-compose.p2p.yml" "$legacy/docker-compose.p2p.yml"
printf 'DOMAIN=legacy.example.test\n' > "$legacy/.env"
cat > "$host/etc/caddy/Caddyfile" <<'EOF'
d1.example.test {
	encode gzip
	header /.well-known/matrix/* Content-Type application/json
	handle {
		reverse_proxy 127.0.0.1:8008
	}
}
EOF
cp "$host/etc/caddy/Caddyfile" "$tmp/original-Caddyfile"

cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fixed_digest=sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c
case "$*" in
  'ps -aq --filter label=com.docker.compose.project=dirextalk-p2p --filter label=com.docker.compose.service=message-server')
    printf 'container-legacy\n'
    ;;
  'inspect --format {{.State.Running}} container-legacy') printf 'true\n' ;;
  'inspect --format {{if .State.Health}}{{.State.Health.Status}}{{end}} container-legacy') printf '%s\n' "${FAKE_HEALTH_STATUS:-healthy}" ;;
  'inspect --format {{.Config.Image}} container-legacy') printf 'dirextalk/message-server:latest\n' ;;
  'inspect --format {{.Image}} container-legacy') printf 'sha256:image-config\n' ;;
  'image inspect --format {{join .RepoDigests "\n"}} sha256:image-config')
    printf 'dirextalk/message-server@%s\n' "${FAKE_IMAGE_DIGEST:-$fixed_digest}"
    ;;
  'exec container-legacy wget -q -O- http://127.0.0.1:8008/_p2p/health')
    printf '{"status":"%s"}\n' "${FAKE_SERVER_HEALTH:-ok}"
    ;;
  'exec container-legacy /usr/bin/dirextalk-message-server --version')
    printf '%s\n' "${FAKE_SERVER_VERSION:-0.15.2}"
    ;;
  'cp container-legacy:/var/dirextalk-message-server/p2p/. '*)
    destination=${*: -1}
    mkdir -p "$destination"
    printf '{"legacy":true}\n' > "$destination/bootstrap.json"
    ;;
  *' config') : ;;
  *) echo "unexpected docker call: $*" >&2; exit 91 ;;
esac
EOF
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'is-active caddy.service') printf 'active\n' ;;
  'show -p User --value caddy.service') printf '%s\n' "${FAKE_CADDY_USER:-caddy}" ;;
  'daemon-reload') : ;;
  'reload caddy.service') exit "${FAKE_CADDY_RELOAD_RC:-0}" ;;
  *) echo "unexpected systemctl call: $*" >&2; exit 92 ;;
esac
EOF
cat > "$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = 'group caddy' ] || exit 1
printf 'caddy:x:991:\n'
EOF
chmod 0755 "$tmp/bin/"*
expected=$'legacy_adoptable\tv0.15.2\tdirextalk/message-server:v0.15.2@sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c\t/root/dirextalk/dirextalk-message-server\tdocker-compose.p2p.yml\tsystemd_caddy'
actual=$(PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" \
  bash "$ROOT/scripts/updater/adopt-legacy-host.sh" probe \
    /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater")
[ "$actual" = "$expected" ] || {
  printf 'unexpected legacy probe result:\n%s\n' "$actual" >&2
  exit 1
}

expect_probe_failure() {
  if PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" "$@" \
      bash "$ROOT/scripts/updater/adopt-legacy-host.sh" probe \
        /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater" \
        >/dev/null 2>&1; then
    echo "unsafe legacy probe was accepted: $*" >&2
    exit 1
  fi
}
expect_probe_failure env FAKE_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_probe_failure env FAKE_SERVER_HEALTH=down
printf '\n# drift\n' >> "$legacy/docker-compose.p2p.yml"
expect_probe_failure env
cp "$ROOT/scripts/updater/legacy-d1-compose.p2p.yml" "$legacy/docker-compose.p2p.yml"

# The approved d1 host uses the Compose defaults and has no source .env.
# Adoption must remain read-only during probe and create only the controlled
# target env during commit.
rm -f "$legacy/.env"
actual=$(PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" \
  bash "$ROOT/scripts/updater/adopt-legacy-host.sh" probe \
    /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater")
[ "$actual" = "$expected" ] || {
  echo "approved legacy host without a source .env was rejected" >&2
  exit 1
}

PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" \
  DIREXTALK_LEGACY_ADOPT_ALLOW_NON_ROOT_TEST=1 \
  bash "$ROOT/scripts/updater/adopt-legacy-host.sh" commit \
    /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater"

target="$host/var/dirextalk-message-server"
cmp "$target/docker-compose.yml" "$ROOT/scripts/updater/legacy-adopt-compose.yml"
grep -F -x -q \
  'MESSAGE_SERVER_IMAGE=dirextalk/message-server:v0.15.2@sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c' \
  "$target/.env"
grep -F -x -q 'DOMAIN=d1.example.test' "$target/.env"
[ "$(grep -c '^MESSAGE_SERVER_IMAGE=' "$target/.env")" = 1 ]
grep -F -q '"legacy":true' "$target/p2p/bootstrap.json"
grep -F -q 'handle /_dirextalk/updater/v1/jobs/* {' "$host/etc/caddy/Caddyfile"
! grep -F -q '/_dirextalk/updater/v1/control' "$host/etc/caddy/Caddyfile"
[ -f "$host/etc/caddy/Caddyfile.dirextalk-legacy-adopt.bak" ]
dropin="$host/etc/systemd/system/dirextalk-updater.service.d/legacy-systemd-caddy.conf"
grep -F -q 'chgrp caddy /run/dirextalk-updater/http.sock' "$dropin"

# Repeating the confirmed host commit is idempotent and does not rotate backups.
sed -i '/^DOMAIN=/d' "$target/.env"
PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" \
  DIREXTALK_LEGACY_ADOPT_ALLOW_NON_ROOT_TEST=1 \
  bash "$ROOT/scripts/updater/adopt-legacy-host.sh" commit \
    /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater"
grep -F -x -q 'DOMAIN=d1.example.test' "$target/.env"
[ "$(grep -F -c 'handle /_dirextalk/updater/v1/jobs/* {' "$host/etc/caddy/Caddyfile")" = 1 ]
[ "$(find "$host/etc/caddy" -maxdepth 1 -name 'Caddyfile.dirextalk-legacy-adopt.bak*' | wc -l | tr -d ' ')" = 1 ]

# A transient reload failure during a later idempotent run must preserve the
# already-adopted route, its rollback backup, and the controlled target.
if PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" \
    DIREXTALK_LEGACY_ADOPT_ALLOW_NON_ROOT_TEST=1 FAKE_CADDY_RELOAD_RC=1 \
    bash "$ROOT/scripts/updater/adopt-legacy-host.sh" commit \
      /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater" \
      >/dev/null 2>&1; then
  echo "legacy idempotent commit ignored a Caddy reload failure" >&2
  exit 1
fi
[ "$(grep -F -c 'handle /_dirextalk/updater/v1/jobs/* {' "$host/etc/caddy/Caddyfile")" = 1 ]
[ -f "$host/etc/caddy/Caddyfile.dirextalk-legacy-adopt.bak" ]
[ -d "$target" ]

rm -rf "$target" "$host/etc/systemd/system/dirextalk-updater.service.d"
cp "$tmp/original-Caddyfile" "$host/etc/caddy/Caddyfile"
rm -f "$host/etc/caddy/Caddyfile.dirextalk-legacy-adopt.bak"
if PATH="$tmp/bin:$PATH" DIREXTALK_LEGACY_ADOPT_ROOT="$host" \
    DIREXTALK_LEGACY_ADOPT_ALLOW_NON_ROOT_TEST=1 FAKE_CADDY_VALIDATE_RC=1 \
    bash "$ROOT/scripts/updater/adopt-legacy-host.sh" commit \
      /root/dirextalk/dirextalk-message-server "$ROOT/scripts/updater" \
      >/dev/null 2>&1; then
  echo "invalid adopted Caddy configuration was accepted" >&2
  exit 1
fi
cmp "$host/etc/caddy/Caddyfile" "$tmp/original-Caddyfile"
[ ! -e "$host/etc/caddy/Caddyfile.dirextalk-legacy-adopt.bak" ]
[ ! -e "$host/etc/systemd/system/dirextalk-updater.service.d/legacy-systemd-caddy.conf" ]
[ ! -e "$target" ]

local_home="$tmp/local-home"
work="$tmp/local-work"
calls="$tmp/ssh-calls"
key_file="$tmp/legacy.pem"
mkdir -p "$local_home" "$work"
printf 'test-key\n' > "$key_file"
: > "$calls"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command=${!#}
printf '%s\n' "$command" >> "$CALLS"
cat >/dev/null
if [[ "$command" == *'adopt-legacy-host.sh'* && "$command" == *' probe '* ]]; then
  printf 'legacy_adoptable\tv0.15.2\tdirextalk/message-server:v0.15.2@sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c\t/root/dirextalk/dirextalk-message-server\tdocker-compose.p2p.yml\tsystemd_caddy\n'
elif [[ "$command" == *'reconcile-host.sh'* ]]; then
  printf 'v1.0.10\ta8971d7b04e8fef29b35ef889cc1b70d7ceca7a5\t730f3d1e4c6f604069e1b6eed60121bffb47f32d2f1d960cb3f8a0121974b6b8\n'
else
  echo "unexpected ssh command: $command" >&2
  exit 94
fi
EOF
chmod 0755 "$tmp/bin/ssh"

export HOME="$local_home" DIREXTALK_WORKDIR="$work" CALLS="$calls" PATH="$tmp/bin:$PATH"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
res_set instance_id legacy-instance
res_set public_ip 203.0.113.44
res_set key_file "$key_file"

state_set_raw server_release '{"source":"github_release","version":"v1.0.4","image":"dirextalk/message-server:v1.0.4","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_ref":"dirextalk/message-server:v1.0.4@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifest_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
if DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server \
    DIREXTALK_LEGACY_ADOPT_SSH_USER=root \
    bash "$ROOT/scripts/adopt-legacy-node.sh" --dry-run "$STATE_JSON" >/dev/null 2>&1; then
  echo "existing formal release state was overwritten by legacy adoption" >&2
  exit 1
fi
[ ! -s "$calls" ]

state_set_raw server_release '{}'
DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server \
  DIREXTALK_LEGACY_ADOPT_SSH_USER=root \
  bash "$ROOT/scripts/adopt-legacy-node.sh" --dry-run "$STATE_JSON" >/dev/null
[ "$(wc -l < "$calls" | tr -d ' ')" = 1 ]
[ "$(state_get server_release.source)" = "" ]

if DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server \
    DIREXTALK_LEGACY_ADOPT_SSH_USER=root \
    bash "$ROOT/scripts/adopt-legacy-node.sh" "$STATE_JSON" >/dev/null 2>&1; then
  echo "legacy adoption ran without explicit confirmation" >&2
  exit 1
fi
[ "$(state_get server_release.source)" = "" ]

confirm=adopt-legacy-v0.15.2-d57a0b7830f7248e
DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server \
  DIREXTALK_LEGACY_ADOPT_SSH_USER=root DIREXTALK_LEGACY_ADOPT_CONFIRM="$confirm" \
  DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=1 DIREXTALK_BOOTSTRAP_SSH_DELAY=0 \
  bash "$ROOT/scripts/adopt-legacy-node.sh" "$STATE_JSON" >/dev/null
[ "$(state_get server_release.source)" = legacy_adopted ]
[ "$(state_get server_release.version)" = v0.15.2 ]
[ "$(state_get server_release.digest)" = sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c ]
[ "$(state_get updater_release.version)" = v1.0.10 ]
grep -F -q 'reconcile-host.sh' "$calls"
grep -F -q '/root/dirextalk/dirextalk-message-server' "$calls"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/server-release.sh"
server_release_prepare_state

# A completed adoption is safe to resume and preserves the exact adopted state.
DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server \
  DIREXTALK_LEGACY_ADOPT_SSH_USER=root DIREXTALK_LEGACY_ADOPT_CONFIRM="$confirm" \
  DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=1 DIREXTALK_BOOTSTRAP_SSH_DELAY=0 \
  bash "$ROOT/scripts/adopt-legacy-node.sh" "$STATE_JSON" >/dev/null
[ "$(state_get server_release.source)" = legacy_adopted ]

echo "legacy adopt contract ok"
