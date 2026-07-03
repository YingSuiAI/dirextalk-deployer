#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$ROOT/scripts/render/render-lightsail-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image direxio/message-server:test \
  > "$tmp/user-data.sh"

head -n 1 "$tmp/user-data.sh" | grep -Fx -q '#!/usr/bin/env bash'
grep -q '^set -euo pipefail$' "$tmp/user-data.sh"
if grep -q '^#cloud-config\|^package_update:' "$tmp/user-data.sh"; then
  echo "Lightsail user-data must be a shell script, not cloud-config YAML" >&2
  exit 1
fi

awk '/DIREXIO_BUNDLE/ && /<</ { getline; print; exit }' "$tmp/user-data.sh" \
  | base64 -d > "$tmp/bundle.tar.gz"
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"

grep -q '^DOMAIN=service.example.test$' "$tmp/user-data.sh"
grep -q '^ACME_EMAIL=ops@example.test$' "$tmp/user-data.sh"
grep -q '^MESSAGE_SERVER_IMAGE=direxio/message-server:test$' "$tmp/user-data.sh"
grep -q 'curl -fsSL https://get.docker.com | sh' "$tmp/user-data.sh"
grep -q 'docker compose --env-file .env up -d' "$tmp/user-data.sh"
grep -q 'DOMAIN=$(grep' "$tmp/user-data.sh"
grep -q 'bash init-tokens.sh' "$tmp/user-data.sh"
grep -q '.deploy-done' "$tmp/user-data.sh"

grep -q '/etc/direxio-message-server/message-server.yaml' "$tmp/bundle/docker-compose.yml"
grep -F -q 'handle /.well-known/portal/*' "$tmp/bundle/Caddyfile"
grep -q 'agent.matrix_session.create' "$tmp/bundle/init-tokens.sh"

echo "render lightsail userdata ok"
