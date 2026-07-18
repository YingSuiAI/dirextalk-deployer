#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  > "$tmp/user-data.yaml"

bash "$ROOT/scripts/render/render-userdata.sh" \
  --format shell \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  > "$tmp/user-data.sh"

grep -q '^#cloud-config' "$tmp/user-data.yaml"
grep -q '^#!/usr/bin/env bash' "$tmp/user-data.sh"
grep -q '^package_update: false' "$tmp/user-data.yaml"
if grep -q '^package_update: true' "$tmp/user-data.yaml"; then
  echo "cloud-init user-data must not run a redundant package update before Docker's installer" >&2
  exit 1
fi
grep -q 'if ! command -v docker >/dev/null 2>&1' "$tmp/user-data.yaml"
grep -q 'if ! command -v docker >/dev/null 2>&1' "$tmp/user-data.sh"
grep -q 'bash /var/dirextalk-message-server/updater/bootstrap-host.sh' "$tmp/user-data.yaml"
grep -q 'cd /var/dirextalk-message-server' "$tmp/user-data.sh"
grep -q 'bash updater/bootstrap-host.sh' "$tmp/user-data.sh"
if grep -q '^#cloud-config' "$tmp/user-data.sh"; then
  echo "Lightsail shell user-data must not be rendered as cloud-config" >&2
  exit 1
fi
grep -q 'base64 --decode > bundle.tar.gz' "$tmp/user-data.sh"

awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$tmp/user-data.yaml" \
  | base64 -d > "$tmp/bundle.tar.gz"
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"

if grep -q 'P2P_REMOTE_NODE_' "$tmp/user-data.yaml"; then
  echo "rendered user-data must not configure fixed remote P2P nodes" >&2
  exit 1
fi

grep -q '/var/dirextalk-message-server/bundle.tar.gz' "$tmp/user-data.yaml"
grep -q 'docker compose --env-file .env pull' "$tmp/bundle/updater/bootstrap-host.sh"
grep -q 'docker compose --env-file .env up -d' "$tmp/bundle/updater/bootstrap-host.sh"
grep -q 'cd "$base"' "$tmp/bundle/updater/bootstrap-host.sh"
grep -q '/etc/dirextalk-message-server/message-server.yaml' "$tmp/bundle/docker-compose.yml"
grep -q '/var/dirextalk-message-server/p2p/bootstrap.json' "$tmp/bundle/docker-compose.yml"
grep -q 'P2P_PORTAL_CREDENTIALS_FILE: /var/dirextalk-message-server/p2p/bootstrap.json' "$tmp/bundle/docker-compose.yml"
grep -q 'P2P_PORTAL_PASSWORD: ${P2P_PORTAL_PASSWORD}' "$tmp/bundle/docker-compose.yml"
awk '
  /^  message-server:/ { in_service=1; next }
  /^  [^[:space:]].*:/ { in_service=0 }
  in_service && /\/var\/dirextalk-message-server\/p2p:\/var\/dirextalk-message-server\/p2p/ { found=1 }
  END { exit found ? 0 : 1 }
' "$tmp/bundle/docker-compose.yml"
grep -F -q 'handle /.well-known/portal/*' "$tmp/bundle/Caddyfile"
grep -F -q 'reverse_proxy message-server:8008' "$tmp/bundle/Caddyfile"
deprecated_wellknown_dir="/var/dirextalk-message-server/""wellknown"
deprecated_caddy_mount="/srv/""p2p"
deprecated_static_server="file_""server"
if grep -R -q "$deprecated_wellknown_dir\\|$deprecated_caddy_mount\\|$deprecated_static_server" "$tmp/bundle/docker-compose.yml" "$tmp/bundle/Caddyfile" "$tmp/user-data.yaml"; then
  echo "portal well-known must be served by message-server, not static mounted files" >&2
  exit 1
fi
grep -q 'first_nonempty_env_value TURN_SECRET' "$tmp/bundle/updater/bootstrap-host.sh"
grep -q 'first_nonempty_env_value P2P_PORTAL_PASSWORD' "$tmp/bundle/updater/bootstrap-host.sh"
if grep -q '^    grep -q .*\(TURN_SECRET\|P2P_PORTAL_PASSWORD\)=' "$tmp/user-data.yaml"; then
  echo "service secrets must be normalized by the locked bootstrap, not a separate cloud-init command" >&2
  exit 1
fi
grep -q '/var/dirextalk-message-server/p2p/bootstrap.json' "$tmp/bundle/init-tokens.sh"
grep -q 'BOOTSTRAP_FILE=${BOOTSTRAP_FILE:-/var/dirextalk-message-server/p2p/bootstrap.json}' "$tmp/bundle/init-tokens.sh"
grep -q 'if \[ -s "$BOOTSTRAP_FILE" \]' "$tmp/bundle/init-tokens.sh"
if grep -q 'exec -T message-server sh -c .*bootstrap.json' "$tmp/bundle/init-tokens.sh"; then
  echo "init-tokens.sh must not copy bootstrap credentials out of the container" >&2
  exit 1
fi
if grep -q 'owner.json' "$tmp/bundle/init-tokens.sh"; then
  echo "init-tokens.sh must not write owner.json; message-server serves it dynamically" >&2
  exit 1
fi
deprecated_remote_dir="/opt""/p2p"
if grep -q "$deprecated_remote_dir/bootstrap.json" "$tmp/bundle/init-tokens.sh"; then
  echo "init-tokens.sh must not mirror bootstrap credentials to the deprecated bootstrap path" >&2
  exit 1
fi
if grep -R -q "$deprecated_remote_dir" "$tmp/bundle" "$tmp/user-data.yaml"; then
  echo "rendered remote deployment bundle must not use deprecated remote deployment paths" >&2
  exit 1
fi
grep -q 'portal.bootstrap' "$tmp/bundle/init-tokens.sh"
grep -q 'agent.matrix_session.create' "$tmp/bundle/init-tokens.sh"
grep -q 'agent_auth_token=$(json_string agent_token "$BOOTSTRAP_FILE")' "$tmp/bundle/init-tokens.sh"
grep -q 'agent.matrix_session.create.*"$agent_auth_token"' "$tmp/bundle/init-tokens.sh"
if grep -q -- '--header="Authorization: Bearer' "$tmp/bundle/init-tokens.sh"; then
  echo "bootstrap bearer tokens must not be passed in wget argv" >&2
  exit 1
fi
grep -q '/_matrix/client/v3/createRoom' "$tmp/bundle/init-tokens.sh"
grep -q '/_matrix/client/v3/rooms/${room_path}/join' "$tmp/bundle/init-tokens.sh"

if grep -R -q '/etc/dendrite\|/var/dendrite\|dendrite.yaml' "$tmp/bundle"; then
  echo "rendered bundle must use dirextalk-message-server paths, not legacy dendrite paths" >&2
  exit 1
fi

echo "render userdata remote node config absent ok"
