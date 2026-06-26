#!/usr/bin/env bash
# init-tokens.sh - wait for message-server bootstrap credentials after compose is up.
set -euo pipefail

P2P_DIR=${P2P_DIR:-/opt/p2p}
COMPOSE="docker compose -f ${P2P_DIR}/docker-compose.yml --env-file ${P2P_DIR}/.env"
DOMAIN=${DOMAIN:?DOMAIN is required (e.g. __DOMAIN__)}
CONTAINER_BOOTSTRAP_FILE=${CONTAINER_BOOTSTRAP_FILE:-/var/direxio-message-server/p2p/bootstrap.json}
BOOTSTRAP_FILE=${BOOTSTRAP_FILE:-/opt/p2p/bootstrap.json}
WELLKNOWN_DIR=${WELLKNOWN_DIR:-/opt/p2p/wellknown}

log() { echo "[init-tokens] $*" >&2; }

json_string() {
  local key=$1 file=$2
  grep -oE '"'"$key"'"[[:space:]]*:[[:space:]]*"[^"]+"' "$file" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/' \
    || true
}

wait_for_message_server() {
  log "waiting for message-server /_p2p/health ..."
  for i in $(seq 1 90); do
    if $COMPOSE exec -T message-server wget -q -O - http://127.0.0.1:8008/_p2p/health >/dev/null 2>&1; then
      log "message-server is healthy."
      return 0
    fi
    sleep 5
  done
  log "message-server did not become healthy in time"
  return 1
}

copy_bootstrap_file() {
  local tmp
  tmp=$(mktemp)
  if ! $COMPOSE exec -T message-server sh -c "test -s '$CONTAINER_BOOTSTRAP_FILE' && cat '$CONTAINER_BOOTSTRAP_FILE'" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  install -m 0600 "$tmp" "$BOOTSTRAP_FILE"
  rm -f "$tmp"
}

wait_for_bootstrap_file() {
  local password agent_token access_token
  log "waiting for ${CONTAINER_BOOTSTRAP_FILE} ..."
  for i in $(seq 1 90); do
    if copy_bootstrap_file; then
      password=$(json_string password "$BOOTSTRAP_FILE")
      agent_token=$(json_string agent_token "$BOOTSTRAP_FILE")
      access_token=$(json_string access_token "$BOOTSTRAP_FILE")
      if [ -n "$password" ] && [ -n "$agent_token" ] && [ -n "$access_token" ]; then
        log "credentials file is ready."
        return 0
      fi
      log "credentials file exists but is missing password/access/agent token"
    fi
    sleep 5
  done
  log "FATAL: ${CONTAINER_BOOTSTRAP_FILE} was not written with complete credentials in time."
  return 1
}

write_owner_json() {
  local user_id homeserver
  mkdir -p "$WELLKNOWN_DIR"
  user_id=$(json_string user_id "$BOOTSTRAP_FILE")
  [ -n "$user_id" ] || user_id=$(json_string owner_user_id "$BOOTSTRAP_FILE")
  [ -n "$user_id" ] || user_id="@owner:${DOMAIN}"
  homeserver=$(json_string homeserver "$BOOTSTRAP_FILE")
  [ -n "$homeserver" ] || homeserver="https://${DOMAIN}"
  cat > "${WELLKNOWN_DIR}/owner.json" <<EOF
{"user_id":"${user_id}","owner_user_id":"${user_id}","display_name":"owner","domain":"${DOMAIN}","homeserver":"${homeserver}"}
EOF
  chmod 0644 "${WELLKNOWN_DIR}/owner.json"
}

mkdir -p "$(dirname "$BOOTSTRAP_FILE")" "$WELLKNOWN_DIR"
wait_for_message_server
wait_for_bootstrap_file
write_owner_json
echo "$BOOTSTRAP_FILE"
