#!/usr/bin/env bash
# Opt-in local-only acceptance: proves the Message Server's enabled remote
# runner reaches a real Agent over the private Compose network. It never uses
# AWS, a registry login, or host ports for Agent gRPC.
set -euo pipefail

if [ "${DIREXTALK_RUN_AGENT_COMPOSE_ACCEPTANCE:-0}" != 1 ]; then
  echo "agent remote gRPC Compose acceptance skipped (set DIREXTALK_RUN_AGENT_COMPOSE_ACCEPTANCE=1)"
  exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
agent_image=${DIREXTALK_AGENT_COMPOSE_IMAGE:?set DIREXTALK_AGENT_COMPOSE_IMAGE to a local Agent image}
message_server_image=${DIREXTALK_MESSAGE_SERVER_COMPOSE_IMAGE:?set DIREXTALK_MESSAGE_SERVER_COMPOSE_IMAGE to a local Message Server image}
tmp=$(mktemp -d)
project="dirextalk-agent-contract-${RANDOM}${RANDOM}"
compose_file="$tmp/bundle/docker-compose.yml"

cleanup() {
  if [ "${DIREXTALK_KEEP_AGENT_COMPOSE_ACCEPTANCE:-0}" = 1 ]; then
    printf '%s\n' "agent Compose acceptance retained for diagnosis: project=$project bundle=$tmp/bundle" >&2
    return
  fi
  if [ -f "$compose_file" ]; then
    docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

docker image inspect "$agent_image" >/dev/null
docker image inspect "$message_server_image" >/dev/null
docker image inspect postgres:18-alpine >/dev/null

image='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
profiles="$tmp/model-profiles.json"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"test-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$profiles"

bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain agent-local.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  > "$tmp/user-data.yaml"
mkdir "$tmp/bundle"
awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$tmp/user-data.yaml" | base64 -d > "$tmp/bundle.tar.gz"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"
mkdir "$tmp/p2p" "$tmp/updater-run"
: > "$tmp/control-token"

# Keep all bind mounts inside the uniquely-created test directory. The runtime
# contract uses the same paths inside the containers, so init-tokens can run
# without a production host path or an override compose file.
sed -i \
  -e "s#/var/dirextalk-message-server/p2p:#$tmp/p2p:#g" \
  -e "s#/run/dirextalk-updater:#$tmp/updater-run:#g" \
  -e "s#/etc/dirextalk-updater/control-token:#$tmp/control-token:#g" \
  "$compose_file"
printf '%s\n' \
  'DOMAIN=agent-local.test' \
  'ACME_EMAIL=ops@example.test' \
  "MESSAGE_SERVER_IMAGE=$message_server_image" \
  "AGENT_IMAGE=$agent_image" \
  "AGENT_INSTANCE_ID=$instance_id" \
  'TURN_SECRET=compose-acceptance-turn-secret' \
  'P2P_PORTAL_PASSWORD=12345678' \
  'PUBLIC_IP=203.0.113.10' \
  > "$tmp/bundle/.env"

docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" up -d message-server >/dev/null
for _ in $(seq 1 90); do
  if docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" exec -T message-server wget -q -O- http://127.0.0.1:8008/_p2p/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" exec -T message-server wget -q -O- http://127.0.0.1:8008/_p2p/health >/dev/null

# Compose dependency health is necessary but not sufficient evidence: execute
# the Agent's real TLS gRPC healthcheck too, with the exact leaf trust layout
# rendered for this private network.
docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" exec -T agent /usr/local/bin/dirextalk-agent healthcheck >/dev/null

# Bootstrap and read the bearer only inside the Message Server container. Its
# raw HTTP requests travel by stdin to the private helper, so the bearer never
# appears in argv and neither it nor either response reaches stdout. The cloud
# init path runs init-tokens as root; keeping this test inside the container
# avoids weakening its root-owned credential-file permissions for a local bind.
docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" exec -T message-server sh -s <<'MESSAGE_SERVER_P2P'
set -eu
bootstrap_response=$(mktemp)
query_response=$(mktemp)
trap 'rm -f "$bootstrap_response" "$query_response"' EXIT HUP INT TERM

password=$P2P_PORTAL_PASSWORD
[ -n "$password" ]
body=$(printf '{"action":"portal.bootstrap","params":{"password":"%s"}}' "$password")
content_length=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
{
  printf 'POST /_p2p/command HTTP/1.1\r\n'
  printf 'Host: 127.0.0.1:8008\r\n'
  printf 'Content-Type: application/json\r\n'
  printf 'Connection: close\r\n'
  printf 'Content-Length: %s\r\n\r\n' "$content_length"
  printf '%s' "$body"
} | sh /bootstrap/p2p-http-request.sh > "$bootstrap_response"

token=$(grep -oE '"access_token"[[:space:]]*:[[:space:]]*"[^"]+"' /var/dirextalk-message-server/p2p/bootstrap.json | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/')
[ -n "$token" ]
body='{"action":"cloud.deployments.list","params":{}}'
content_length=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
{
  printf 'POST /_p2p/query HTTP/1.1\r\n'
  printf 'Host: 127.0.0.1:8008\r\n'
  printf 'Content-Type: application/json\r\n'
  printf 'Authorization: Bearer %s\r\n' "$token"
  printf 'Connection: close\r\n'
  printf 'Content-Length: %s\r\n\r\n' "$content_length"
  printf '%s' "$body"
} | sh /bootstrap/p2p-http-request.sh > "$query_response"
grep -Eq '"deployments"[[:space:]]*:[[:space:]]*\[' "$query_response"
MESSAGE_SERVER_P2P

agent_container=$(docker compose --project-name "$project" --env-file "$tmp/bundle/.env" -f "$compose_file" ps -q agent)
[ -n "$agent_container" ] || {
  echo "Agent container is missing before host-port assertion" >&2
  exit 1
}
# Some Compose versions print `invalid IP:0` for an exposed-but-unbound port,
# so the daemon's HostConfig is the authority for actual host publication.
agent_9443_bindings=$(docker inspect "$agent_container" --format '{{with index .HostConfig.PortBindings "9443/tcp"}}{{json .}}{{end}}')
if [ -n "$agent_9443_bindings" ]; then
  echo "Agent gRPC must not publish a host port" >&2
  exit 1
fi

echo "agent remote gRPC Compose acceptance ok"
