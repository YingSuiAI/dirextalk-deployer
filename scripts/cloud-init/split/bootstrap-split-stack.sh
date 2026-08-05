#!/usr/bin/env bash
set -euo pipefail

base=/var/dirextalk-message-server
run_dir=$base/split
domain=${DOMAIN:?set DOMAIN}
message_image=${MESSAGE_SERVER_IMAGE:?set MESSAGE_SERVER_IMAGE to a digest reference}
agent_image=${AGENT_IMAGE:?set AGENT_IMAGE to a digest reference}

for image in "$message_image" "$agent_image"; do
  printf '%s\n' "$image" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$' || {
    echo "split bootstrap requires immutable image digests" >&2
    exit 1
  }
done

if [ -f "$base/.split-deploy-done" ]; then
  exit 0
fi

install -d -m 0700 "$run_dir"
install -d -m 0755 /var/dirextalk-agent

DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE="$message_image" \
DIREXTALK_AGENT_IMAGE_IMMUTABLE="$agent_image" \
DIREXTALK_EXTENSION_RUNNER_IMAGE_IMMUTABLE="$agent_image" \
DIREXTALK_CORE_RUNNER_IMAGE_IMMUTABLE="$agent_image" \
  "$base/deploy/split-agent/scripts/provision-local.sh" "$run_dir"

env_file=$run_dir/.env
tmp_env=$(mktemp "$run_dir/.env.XXXXXX")
awk '$0 !~ /^(DIREXTALK_MESSAGE_SERVER_NAME|DIREXTALK_MESSAGE_CLIENT_BASE_URL)=/' "$env_file" >"$tmp_env"
printf 'DIREXTALK_MESSAGE_SERVER_NAME=%s\n' "$domain" >>"$tmp_env"
printf 'DIREXTALK_MESSAGE_CLIENT_BASE_URL=https://%s\n' "$domain" >>"$tmp_env"
chmod 0400 "$tmp_env"
mv -f "$tmp_env" "$env_file"

cat >"$run_dir/Caddyfile" <<'CADDY'
{$DOMAIN} {
  handle /.well-known/matrix/server {
    header Content-Type application/json
    respond `{"m.server":"{$DOMAIN}:443"}` 200
  }
  handle /.well-known/matrix/client {
    header Content-Type application/json
    header Access-Control-Allow-Origin *
    respond `{"m.homeserver":{"base_url":"https://{$DOMAIN}"}}` 200
  }
  reverse_proxy message-server:8008
}
CADDY
chmod 0644 "$run_dir/Caddyfile"
cp "$base/deploy/split-agent/edge-compose.yaml" "$run_dir/edge-compose.yaml"

compose=(docker compose --env-file "$env_file" -f "$base/deploy/split-agent/compose.yaml" -f "$run_dir/edge-compose.yaml")
"${compose[@]}" config --quiet
"${compose[@]}" pull
"${compose[@]}" up -d --wait
# $password is expanded only inside message-server, where the secret is mounted.
# shellcheck disable=SC2016
portal_bootstrap='
  password=$(cat /run/secrets/message_portal_password)
  wget -q -O /dev/null --header="Content-Type: application/json" \
    --post-data="{\"action\":\"portal.bootstrap\",\"params\":{\"password\":\"$password\"}}" \
    http://127.0.0.1:8008/_p2p/command || true
'
"${compose[@]}" exec -T message-server sh -ec "$portal_bootstrap"
touch "$base/.split-deploy-done"
