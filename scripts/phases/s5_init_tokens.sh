#!/usr/bin/env bash
# S5 INIT_TOKENS - fetch message-server bootstrap credentials from the instance.
# Also verify owner.json so the client does not report Portal as undeployed.

DIREXTALK_REMOTE_BOOTSTRAP_FILE=${DIREXTALK_REMOTE_BOOTSTRAP_FILE:-/var/dirextalk-message-server/p2p/bootstrap.json}
S5_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$S5_DIR/../lib/remote-mcp-contract.sh"

run_phase() {
  phase_set S5_INIT_TOKENS in_progress "fetching tokens"
  local domain pubip keyfile
  domain=$(state_get domain)
  pubip=$(res_get public_ip)
  keyfile=$(res_get key_file)
  local out="$DIREXTALK_WORKDIR/outputs.json" raw
  raw=$(mktemp "$DIREXTALK_WORKDIR/.bootstrap-output.XXXXXX")
  trap 'rm -f "${raw:-}"; trap - RETURN' RETURN

  log "Fetching ${DIREXTALK_REMOTE_BOOTSTRAP_FILE} ..."
  if ! poll_until "read bootstrap.json" "${TOKEN_POLL_INTERVAL:-10}" "${TOKEN_POLL_MAX:-12}" \
        _read_remote_bootstrap "$keyfile" "$pubip" "$raw"; then
    phase_set S5_INIT_TOKENS failed "failed to fetch bootstrap.json"
    warn "Could not read ${DIREXTALK_REMOTE_BOOTSTRAP_FILE}. Check whether message-server wrote credentials:"
    warn "  ssh -i $keyfile ubuntu@$pubip 'sudo cat ${DIREXTALK_REMOTE_BOOTSTRAP_FILE} 2>/dev/null; cd /var/dirextalk-message-server; sudo docker compose logs message-server | tail -40'"
    return 1
  fi
  if ! _normalize_bootstrap_output "$domain" "$raw" "$out"; then
    phase_set S5_INIT_TOKENS failed "invalid bootstrap.json"
    fail "bootstrap.json could not be normalized."
  fi

  # Verify owner.json; missing file makes the client report Portal as undeployed.
  if _healthz_ok_ownerjson "$domain"; then
    log "owner.json 200 OK (Portal discovery healthy)"
  else
    warn "/.well-known/portal/owner.json did not return 200. The client may report Portal as undeployed."
    warn "  Check Caddy reverse_proxy and message-server /.well-known/portal/owner.json handler."
  fi

  local password token access_token asurl agent_room_id
  if ! IFS=$'\t' read -r password token access_token < <(_extract_output_tokens "$out"); then
    phase_set S5_INIT_TOKENS failed "bootstrap.json missing password/access/agent credentials"
    fail "bootstrap.json must contain password as an eight-digit initialization-code string plus access_token and agent_token."
  fi
  asurl=$(json_get "$out" as_url "https://$domain")
  if ! asurl=$(dirextalk_service_origin "$asurl"); then
    phase_set S5_INIT_TOKENS failed "bootstrap.json contains a non-canonical service URL"
    fail "bootstrap as_url must be an absolute HTTPS origin with no path, query, fragment, or userinfo."
  fi
  agent_room_id=$(json_get "$out" agent_room_id)
  if [ -z "$agent_room_id" ] || [[ "$agent_room_id" == \!agent:* ]]; then
    phase_set S5_INIT_TOKENS failed "bootstrap.json missing real agent_room_id"
    fail "bootstrap.json must contain a real Matrix agent_room_id; legacy !agent:<domain> ids are not supported."
  fi

  # A healthy Agent container alone is not enough: the Message Server must
  # actually exercise its enabled remote runner. The remote command reads the
  # existing bootstrap token only inside the host/container, sends it through
  # the private stdin-to-nc helper, and checks the Agent-backed deployment
  # list without returning the token or service key over SSH.
  if [ "$(state_get agent_release.enabled)" = true ]; then
    log "Verifying the Message Server reaches the enabled Agent gRPC backend..."
    if ! _verify_remote_agent_grpc "$keyfile" "$pubip"; then
      phase_set S5_INIT_TOKENS failed "Message Server could not complete the Agent-backed deployment query"
      warn "Agent gRPC acceptance failed. Inspect the private compose services over SSH; do not copy service-key files or bootstrap tokens into logs."
      return 1
    fi
  fi

  # Store tokens in state for S6. state.json is local-only and chmod 0600.
  state_set as_url "$asurl"
  state_set password "$password"
  state_set agent_token "$token"
  state_set access_token "$access_token"
  state_set agent_room_id "$agent_room_id"

  phase_set S5_INIT_TOKENS done "got password (len=${#password}) as_url=$asurl agent_room_id=$agent_room_id"
  ok "Tokens fetched from bootstrap.json."
  return 0
}

_extract_output_tokens() {
  local out=$1 password token access_token
  [ "$(json_type "$out" password)" = "string" ] || return 1
  password=$(json_get "$out" password)
  token=$(json_get "$out" agent_token)
  access_token=$(json_get "$out" access_token)
  [ -n "$password" ] && [ -n "$token" ] && [ -n "$access_token" ] || return 1
  printf '%s' "$password" | grep -Eq '^[0-9]{8}$' || return 1
  printf '%s\t%s\t%s\n' "$password" "$token" "$access_token"
}

_read_remote_bootstrap() {
  local keyfile=$1 pubip=$2 out=$3
  local ssh_args cmd timeout_seconds
  ssh_args=(
    -i "$keyfile"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}"
    -o BatchMode=yes
    -o ServerAliveInterval="${SSH_SERVER_ALIVE_INTERVAL:-5}"
    -o ServerAliveCountMax="${SSH_SERVER_ALIVE_COUNT_MAX:-2}"
  )
  cmd=(ssh "${ssh_args[@]}" ubuntu@"$pubip" "sudo test -s '${DIREXTALK_REMOTE_BOOTSTRAP_FILE}' && sudo cat '${DIREXTALK_REMOTE_BOOTSTRAP_FILE}'")
  timeout_seconds=${SSH_COMMAND_TIMEOUT:-30}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" "${cmd[@]}" > "$out" 2>/dev/null
  else
    "${cmd[@]}" > "$out" 2>/dev/null
  fi
}

_verify_remote_agent_grpc() {
  local keyfile=$1 pubip=$2 timeout_seconds
  local -a ssh_args cmd
  ssh_args=(
    -i "$keyfile"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}"
    -o BatchMode=yes
    -o ServerAliveInterval="${SSH_SERVER_ALIVE_INTERVAL:-5}"
    -o ServerAliveCountMax="${SSH_SERVER_ALIVE_COUNT_MAX:-2}"
  )
  cmd=(ssh "${ssh_args[@]}" ubuntu@"$pubip" "sudo sh -s")
  timeout_seconds=${SSH_COMMAND_TIMEOUT:-30}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" "${cmd[@]}" <<'REMOTE_AGENT_GRPC'
set -eu
deploy_dir=/var/dirextalk-message-server
bootstrap=/var/dirextalk-message-server/p2p/bootstrap.json
test -s "$bootstrap"
cd "$deploy_dir"
sudo docker compose --env-file .env exec -T message-server sh -ceu '
  token=$(grep -oE '"'"'access_token'"'"'[[:space:]]*:[[:space:]]*"[^"]+"'"'"' /var/dirextalk-message-server/p2p/bootstrap.json | head -1 | sed -E '"'"'s/.*:[[:space:]]*"([^"]+)".*/\1/'"'"')
  [ -n "$token" ]
  response=$(mktemp)
  trap '"'"'rm -f "$response"'"'"' EXIT HUP INT TERM
  body='{"action":"cloud.deployments.list","params":{}}'
  content_length=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
  {
    printf '"'"'POST /_p2p/query HTTP/1.1\r\n'"'"'
    printf '"'"'Host: 127.0.0.1:8008\r\n'"'"'
    printf '"'"'Content-Type: application/json\r\n'"'"'
    printf '"'"'Authorization: Bearer %s\r\n'"'"' "$token"
    printf '"'"'Connection: close\r\n'"'"'
    printf 'Content-Length: %s\r\n\r\n' "$content_length"
    printf '%s' "$body"
  } | sh /bootstrap/p2p-http-request.sh > "$response"
  grep -Eq '"'"'"deployments"[[:space:]]*:[[:space:]]*\['"'"' "$response"
'
REMOTE_AGENT_GRPC
  else
    "${cmd[@]}" <<'REMOTE_AGENT_GRPC'
set -eu
deploy_dir=/var/dirextalk-message-server
bootstrap=/var/dirextalk-message-server/p2p/bootstrap.json
test -s "$bootstrap"
cd "$deploy_dir"
sudo docker compose --env-file .env exec -T message-server sh -ceu '
  token=$(grep -oE '"'"'access_token'"'"'[[:space:]]*:[[:space:]]*"[^"]+"'"'"' /var/dirextalk-message-server/p2p/bootstrap.json | head -1 | sed -E '"'"'s/.*:[[:space:]]*"([^"]+)".*/\1/'"'"')
  [ -n "$token" ]
  response=$(mktemp)
  trap '"'"'rm -f "$response"'"'"' EXIT HUP INT TERM
  body='{"action":"cloud.deployments.list","params":{}}'
  content_length=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
  {
    printf '"'"'POST /_p2p/query HTTP/1.1\r\n'"'"'
    printf '"'"'Host: 127.0.0.1:8008\r\n'"'"'
    printf '"'"'Content-Type: application/json\r\n'"'"'
    printf '"'"'Authorization: Bearer %s\r\n'"'"' "$token"
    printf '"'"'Connection: close\r\n'
    printf 'Content-Length: %s\r\n\r\n' "$content_length"
    printf '%s' "$body"
  } | sh /bootstrap/p2p-http-request.sh > "$response"
  grep -Eq '"'"'"deployments"[[:space:]]*:[[:space:]]*\['"'"' "$response"
'
REMOTE_AGENT_GRPC
  fi
}

_normalize_bootstrap_output() {
  local domain=$1 src=$2 out=$3
  local tmp
  tmp=$(mktemp "$DIREXTALK_WORKDIR/.outputs.XXXXXX")
  if ! json_build bootstrap-normalized "$src" "$domain" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
  chmod 600 "$out" 2>/dev/null || true
}

_healthz_ok_ownerjson() {
  local domain=$1 pubip null_device args=()
  pubip=$(res_get public_ip)
  null_device=$(dirextalk_native_null_device) || return 1
  [ -n "$pubip" ] && args=(--resolve "$domain:443:$pubip")
  [ "$(curl -sk "${args[@]}" -o "$null_device" -w '%{http_code}' "https://$domain/.well-known/portal/owner.json" 2>/dev/null)" = "200" ]
}
