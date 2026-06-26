#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image direxio/message-server:test \
  > "$tmp/user-data.yaml"

awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$tmp/user-data.yaml" \
  | base64 -d > "$tmp/bundle.tar.gz"
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"

if grep -q 'P2P_REMOTE_NODE_' "$tmp/user-data.yaml"; then
  echo "rendered user-data must not configure fixed remote P2P nodes" >&2
  exit 1
fi

grep -q '/etc/direxio-message-server/message-server.yaml' "$tmp/bundle/docker-compose.yml"
grep -q '/var/direxio-message-server/p2p/bootstrap.json' "$tmp/bundle/docker-compose.yml"
grep -q 'P2P_PORTAL_CREDENTIALS_FILE: /var/direxio-message-server/p2p/bootstrap.json' "$tmp/bundle/docker-compose.yml"
grep -q 'P2P_PORTAL_PASSWORD: ${P2P_PORTAL_PASSWORD}' "$tmp/bundle/docker-compose.yml"
grep -q '^    grep -q .*P2P_PORTAL_PASSWORD=' "$tmp/user-data.yaml"
grep -q '/var/direxio-message-server/p2p/bootstrap.json' "$tmp/bundle/init-tokens.sh"
grep -q 'portal.bootstrap' "$tmp/bundle/init-tokens.sh"
grep -q 'agent.matrix_session.create' "$tmp/bundle/init-tokens.sh"
grep -q '/_matrix/client/v3/createRoom' "$tmp/bundle/init-tokens.sh"
grep -q '/_matrix/client/v3/rooms/${room_path}/join' "$tmp/bundle/init-tokens.sh"

if grep -R -q '/etc/dendrite\|/var/dendrite\|dendrite.yaml' "$tmp/bundle"; then
  echo "rendered bundle must use direxio-message-server paths, not legacy dendrite paths" >&2
  exit 1
fi

echo "render userdata remote node config absent ok"
