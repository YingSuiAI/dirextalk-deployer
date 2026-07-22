#!/usr/bin/env bash
# init-tokens.sh - wait for message-server bootstrap credentials after compose is up.
set -euo pipefail

DIREXTALK_DIR=${DIREXTALK_DIR:-/var/dirextalk-message-server}
COMPOSE="docker compose -f ${DIREXTALK_DIR}/docker-compose.yml --env-file ${DIREXTALK_DIR}/.env"
DOMAIN=${DOMAIN:?DOMAIN is required (e.g. __DOMAIN__)}
BOOTSTRAP_FILE=${BOOTSTRAP_FILE:-/var/dirextalk-message-server/p2p/bootstrap.json}
BOOTSTRAP_STAGE_FILE="$DIREXTALK_DIR/.bootstrap-stage"
DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT=${DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT-30}
DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER=${DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER-5}

log() { echo "[init-tokens] $*" >&2; }

# The stage marker is diagnostic-only. Keep its contents to a fixed allow-list
# and make failures non-fatal so it cannot change initialization semantics.
write_bootstrap_stage() {
  local stage=$1 stage_tmp
  case "$stage" in
    init_health|init_portal|init_credentials|init_agent_session|init_room_create|init_room_join|init_complete) ;;
    *) return 0 ;;
  esac
  if ! mkdir -p "$DIREXTALK_DIR" 2>/dev/null; then
    return 0
  fi
  if ! stage_tmp=$(mktemp "$DIREXTALK_DIR/.bootstrap-stage.XXXXXX" 2>/dev/null); then
    return 0
  fi
  if printf '%s\n' "$stage" > "$stage_tmp" \
    && chmod 0600 "$stage_tmp" 2>/dev/null \
    && mv -f "$stage_tmp" "$BOOTSTRAP_STAGE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$stage_tmp" 2>/dev/null || true
}

validate_timeout_setting() {
  local name=$1 value=$2 maximum=$3 value_digits maximum_digits
  value_digits=${#value}
  maximum_digits=${#maximum}
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]] \
    || (( value_digits > maximum_digits )) \
    || { (( value_digits == maximum_digits )) && [[ "$value" > "$maximum" ]]; }; then
    log "FATAL: ${name} must be a whole number of seconds from 1 to ${maximum}"
    return 1
  fi
}

validate_timeout_setting DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT \
  "$DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT" 300
validate_timeout_setting DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER \
  "$DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER" 60

run_bounded_remote() {
  if ! command -v timeout >/dev/null 2>&1; then
    log "FATAL: timeout is required to bound remote init-token commands"
    return 127
  fi
  timeout \
    --kill-after="${DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER}s" \
    "${DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT}s" \
    "$@"
}

container_wget_script='
    set -eu
    wget_pid=
    watchdog_pid=
    cleanup() {
      status=$?
      trap - EXIT HUP INT TERM
      [ -z "${wget_pid:-}" ] || kill "$wget_pid" 2>/dev/null || true
      [ -z "${watchdog_pid:-}" ] || kill "$watchdog_pid" 2>/dev/null || true
      [ -z "${watchdog_pid:-}" ] || wait "$watchdog_pid" 2>/dev/null || true
      exit "$status"
    }
    trap cleanup EXIT HUP INT TERM
    wget -T "$2" -q -O - "$1" &
    wget_pid=$!
    (
      sleep "$2"
      kill "$wget_pid" 2>/dev/null || true
      sleep "$3"
      kill -9 "$wget_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    wait "$wget_pid"
  '

container_wget() {
  local url=$1
  run_bounded_remote $COMPOSE exec -T message-server sh -c "$container_wget_script" sh \
    "$url" "$DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT" "$DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER"
}

env_string() {
  local key=$1
  grep -E "^${key}=" "${DIREXTALK_DIR}/.env" 2>/dev/null \
    | tail -1 \
    | cut -d= -f2- \
    || true
}

json_string() {
  local key=$1 file=$2
  grep -oE '"'"$key"'"[[:space:]]*:[[:space:]]*"[^"]+"' "$file" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/' \
    || true
}

matrix_room_path() {
  printf '%s' "$1" | sed 's/%/%25/g; s/!/%21/g; s/:/%3A/g'
}

container_post_json() {
  local path=$1 json=$2 token=${3:-} url
  url="http://127.0.0.1:8008${path}"
  run_bounded_remote $COMPOSE exec -T message-server sh -c '
    set -eu
    wget_pid=
    watchdog_pid=
    cleanup() {
      status=$?
      trap - EXIT HUP INT TERM
      [ -z "${wget_pid:-}" ] || kill "$wget_pid" 2>/dev/null || true
      [ -z "${watchdog_pid:-}" ] || kill "$watchdog_pid" 2>/dev/null || true
      [ -z "${watchdog_pid:-}" ] || wait "$watchdog_pid" 2>/dev/null || true
      exit "$status"
    }
    trap cleanup EXIT HUP INT TERM
    if [ -n "$2" ]; then
      wget -T "$4" -q -O - \
        --header="Content-Type: application/json" \
        --header="Authorization: Bearer $2" \
        --post-data="$3" "$1" &
    else
      wget -T "$4" -q -O - \
        --header="Content-Type: application/json" \
        --post-data="$3" "$1" &
    fi
    wget_pid=$!
    (
      sleep "$4"
      kill "$wget_pid" 2>/dev/null || true
      sleep "$5"
      kill -9 "$wget_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    wait "$wget_pid"
  ' sh "$url" "$token" "$json" "$DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT" "$DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER"
}

wait_for_message_server() {
  log "waiting for message-server /_p2p/health ..."
  for i in $(seq 1 90); do
    if container_wget http://127.0.0.1:8008/_p2p/health >/dev/null 2>&1; then
      log "message-server is healthy."
      return 0
    fi
    sleep 5
  done
  log "message-server did not become healthy in time"
  return 1
}

bootstrap_file_ready() {
  if [ -s "$BOOTSTRAP_FILE" ]; then
    chmod 0600 "$BOOTSTRAP_FILE" 2>/dev/null || true
    return 0
  fi
  return 1
}

bootstrap_has_core_credentials() {
  local password agent_token access_token file=$1
  password=$(json_string password "$file")
  agent_token=$(json_string agent_token "$file")
  access_token=$(json_string access_token "$file")
  [ -n "$password" ] && [ -n "$agent_token" ] && [ -n "$access_token" ]
}

bootstrap_has_real_agent_room() {
  local room file=$1
  room=$(json_string agent_room_id "$file")
  case "$room" in
    !agent:*|"") return 1 ;;
    !*) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_portal() {
  local password tmp
  if bootstrap_file_ready && bootstrap_has_core_credentials "$BOOTSTRAP_FILE"; then
    log "portal bootstrap credentials are already present."
    return 0
  fi
  password=${P2P_PORTAL_PASSWORD:-}
  [ -n "$password" ] || password=$(env_string P2P_PORTAL_PASSWORD)
  if [ -z "$password" ]; then
    log "FATAL: P2P_PORTAL_PASSWORD is missing from environment and ${DIREXTALK_DIR}/.env"
    return 1
  fi
  tmp=$(mktemp)
  if container_post_json "/_p2p/command" "{\"action\":\"portal.bootstrap\",\"params\":{\"password\":\"${password}\"}}" > "$tmp" 2>/dev/null; then
    log "portal.bootstrap accepted."
    rm -f "$tmp"
    return 0
  fi
  if bootstrap_file_ready && bootstrap_has_core_credentials "$BOOTSTRAP_FILE"; then
    log "portal bootstrap completed concurrently."
    rm -f "$tmp"
    return 0
  fi
  log "portal.bootstrap failed: $(head -c 160 "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  return 1
}

wait_for_core_bootstrap_file() {
  local password agent_token access_token
  log "waiting for ${BOOTSTRAP_FILE} ..."
  for i in $(seq 1 90); do
    if bootstrap_file_ready; then
      if bootstrap_has_core_credentials "$BOOTSTRAP_FILE"; then
        log "credentials file is ready."
        return 0
      fi
      log "credentials file exists but is missing password/access/agent token"
    fi
    sleep 5
  done
  log "FATAL: ${BOOTSTRAP_FILE} was not written with complete credentials in time."
  return 1
}

write_agent_room_to_bootstrap() {
  local room_id=$1
  python3 - "$BOOTSTRAP_FILE" "$room_id" "$DOMAIN" <<'PY'
import json
import sys

path, room_id, domain = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["agent_room_id"] = room_id
data.setdefault("domain", domain)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, separators=(",", ":"))
    fh.write("\n")
PY
  chmod 0600 "$BOOTSTRAP_FILE"
}

ensure_agent_room() {
  local owner_token agent_auth_token agent_user session room_resp join_resp matrix_agent_token room_id room_path
  if bootstrap_file_ready && bootstrap_has_real_agent_room "$BOOTSTRAP_FILE"; then
    log "agent_room_id is already present."
    return 0
  fi

  owner_token=$(json_string access_token "$BOOTSTRAP_FILE")
  if [ -z "$owner_token" ]; then
    log "FATAL: access_token is missing; cannot create agent room"
    return 1
  fi
  agent_auth_token=$(json_string agent_token "$BOOTSTRAP_FILE")
  if [ -z "$agent_auth_token" ]; then
    log "FATAL: agent_token is missing; cannot create agent Matrix session"
    return 1
  fi
  agent_user="@agent:${DOMAIN}"
  session=$(mktemp)
  if ! container_post_json "/_p2p/command" '{"action":"agent.matrix_session.create","params":{"device_id":"DIREXTALK_DEPLOY_BOOTSTRAP"}}' "$agent_auth_token" > "$session" 2>/dev/null; then
    log "FATAL: agent.matrix_session.create failed: $(head -c 160 "$session" 2>/dev/null)"
    rm -f "$session"
    return 1
  fi
  matrix_agent_token=$(json_string access_token "$session")
  if [ -z "$matrix_agent_token" ]; then
    log "FATAL: agent.matrix_session.create did not return access_token: $(head -c 160 "$session" 2>/dev/null)"
    rm -f "$session"
    return 1
  fi
  rm -f "$session"

  write_bootstrap_stage init_room_create
  room_resp=$(mktemp)
  if ! container_post_json "/_matrix/client/v3/createRoom" "{\"preset\":\"private_chat\",\"visibility\":\"private\",\"name\":\"Dirextalk Agent\",\"invite\":[\"${agent_user}\"],\"is_direct\":false}" "$owner_token" > "$room_resp" 2>/dev/null; then
    log "FATAL: Matrix createRoom failed: $(head -c 160 "$room_resp" 2>/dev/null)"
    rm -f "$room_resp"
    return 1
  fi
  room_id=$(json_string room_id "$room_resp")
  rm -f "$room_resp"
  if [ -z "$room_id" ]; then
    log "FATAL: Matrix createRoom did not return room_id"
    return 1
  fi

  room_path=$(matrix_room_path "$room_id")
  write_bootstrap_stage init_room_join
  join_resp=$(mktemp)
  if ! container_post_json "/_matrix/client/v3/rooms/${room_path}/join" '{}' "$matrix_agent_token" > "$join_resp" 2>/dev/null; then
    log "FATAL: agent join failed for ${room_id}: $(head -c 160 "$join_resp" 2>/dev/null)"
    rm -f "$join_resp"
    return 1
  fi
  rm -f "$join_resp"

  write_agent_room_to_bootstrap "$room_id"
  log "created and persisted agent_room_id=${room_id}"
}

wait_for_complete_bootstrap_file() {
  log "waiting for complete bootstrap credentials with agent_room_id ..."
  for i in $(seq 1 30); do
    if bootstrap_file_ready && bootstrap_has_core_credentials "$BOOTSTRAP_FILE" && bootstrap_has_real_agent_room "$BOOTSTRAP_FILE"; then
      log "complete credentials file is ready."
      return 0
    fi
    sleep 2
  done
  log "FATAL: bootstrap credentials never contained a real agent_room_id."
  return 1
}

mkdir -p "$(dirname "$BOOTSTRAP_FILE")"
write_bootstrap_stage init_health
wait_for_message_server
write_bootstrap_stage init_portal
bootstrap_portal
write_bootstrap_stage init_credentials
wait_for_core_bootstrap_file
write_bootstrap_stage init_agent_session
ensure_agent_room
write_bootstrap_stage init_complete
wait_for_complete_bootstrap_file
echo "$BOOTSTRAP_FILE"
