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
    local split_diagnostics
    split_diagnostics='printf "init_tokens_stage="; sudo cat /var/dirextalk-message-server/.bootstrap-stage 2>/dev/null || echo unavailable; sudo stat -c "bootstrap.json size=%s mode=%a owner=%U:%G modified=%y" /var/dirextalk-message-server/p2p/bootstrap.json 2>/dev/null || echo "bootstrap.json unavailable"; stack=$(sudo sed -n "s/^stack_name=//p" /var/dirextalk-message-server/split/.manifest); sudo docker compose --project-name "$stack" -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml --env-file /var/dirextalk-message-server/split/.env ps; sudo docker compose --project-name "$stack" -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml --env-file /var/dirextalk-message-server/split/.env logs --tail=40 message-server'
    warn "Could not read ${DIREXTALK_REMOTE_BOOTSTRAP_FILE}. Inspect the non-secret initialization stage, file metadata, and split message-server status:"
    warn "  ssh -i $keyfile ubuntu@$pubip '$split_diagnostics'"
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

  local password token bootstrap_access_token asurl agent_room_id owner_session owner_auth_status
  if ! IFS=$'\t' read -r password token bootstrap_access_token < <(_extract_output_tokens "$out"); then
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

  owner_session=$(mktemp "$DIREXTALK_WORKDIR/.owner-matrix-session.XXXXXX") || {
    phase_set S5_INIT_TOKENS failed "failed to allocate owner Matrix session file"
    return 1
  }
  chmod 600 "$owner_session" || {
    rm -f "$owner_session"
    phase_set S5_INIT_TOKENS failed "failed to protect owner Matrix session file"
    return 1
  }
  owner_auth_status=0
  _create_owner_matrix_session "$domain" "$pubip" "$password" "$owner_session" || owner_auth_status=$?
  case "$owner_auth_status" in
    0) ;;
    3)
      rm -f "$owner_session"
      phase_set S5_INIT_TOKENS failed "portal authentication rejected initialization code"
      warn "portal.auth rejected the protected eight-digit initialization code."
      return 3
      ;;
    *)
      rm -f "$owner_session"
      phase_set S5_INIT_TOKENS failed "failed to create owner Matrix session"
      warn "portal.auth could not create a valid owner Matrix session."
      return 1
      ;;
  esac

  local access_token owner_user_id owner_homeserver owner_device_id
  access_token=$(json_get "$owner_session" access_token)
  owner_user_id=$(json_get "$owner_session" user_id)
  owner_homeserver=$(json_get "$owner_session" homeserver)
  owner_device_id=$(json_get "$owner_session" device_id)
  rm -f "$owner_session"
  if [ "$owner_user_id" != "@owner:$domain" ] ||
     [ "$owner_homeserver" != "$asurl" ] ||
     [ -z "$owner_device_id" ] || [ -z "$access_token" ]; then
    phase_set S5_INIT_TOKENS failed "portal authentication returned invalid owner Matrix identity"
    fail "portal.auth must return the canonical owner Matrix session for this deployment."
    return 1
  fi

  # Store tokens in state for S6. state.json is local-only and chmod 0600.
  state_set as_url "$asurl"
  state_set password "$password"
  state_set agent_token "$token"
  state_set access_token "$access_token"
  state_set agent_room_id "$agent_room_id"

  phase_set S5_INIT_TOKENS done "got password (len=${#password}) as_url=$asurl agent_room_id=$agent_room_id"
  ok "Bootstrap credentials fetched and owner Matrix session created."
  return 0
}

_create_owner_matrix_session() {
  local domain=$1 pubip=$2 password=$3 out=$4 request response
  local request_curl response_curl request_arg code curl_status
  [ -n "$domain" ] && [ -n "$pubip" ] || return 1
  mkdir -p "$(dirname "$out")" || return 1
  request=$(mktemp "$(dirname "$out")/.portal-auth-request.XXXXXX") || return 1
  response=$(mktemp "$(dirname "$out")/.portal-auth-response.XXXXXX") || {
    rm -f "$request"
    return 1
  }
  if ! chmod 600 "$request" "$response" || ! json_build portal-auth "$password" > "$request"; then
    rm -f "$request" "$response"
    return 1
  fi
  request_curl=$(dirextalk_native_tool_path "$request") || { rm -f "$request" "$response"; return 1; }
  response_curl=$(dirextalk_native_tool_path "$response") || { rm -f "$request" "$response"; return 1; }
  request_arg="@$request_curl"
  curl_status=0
  code=$(curl -sS \
    --connect-timeout "${DIREXTALK_PORTAL_AUTH_CURL_CONNECT_TIMEOUT:-10}" \
    --max-time "${DIREXTALK_PORTAL_AUTH_CURL_MAX_TIME:-20}" \
    --resolve "$domain:443:$pubip" \
    --output "$response_curl" --write-out '%{http_code}' \
    --request POST --header 'Content-Type: application/json' \
    --data-binary "$request_arg" "https://$domain/_p2p/command" 2>/dev/null) || curl_status=$?
  rm -f "$request"
  if [ "$curl_status" -ne 0 ]; then
    rm -f "$response"
    return 1
  fi
  case "$code" in
    200)
      if [ "$(json_type "$response" access_token)" != "string" ] ||
         [ "$(json_type "$response" device_id)" != "string" ] ||
         [ "$(json_type "$response" user_id)" != "string" ] ||
         [ "$(json_type "$response" homeserver)" != "string" ] ||
         ! json_assert "$response" matrix-session >/dev/null ||
         ! chmod 600 "$response" || ! mv -f "$response" "$out"; then
        rm -f "$response"
        return 1
      fi
      return 0
      ;;
    401|403)
      rm -f "$response"
      return 3
      ;;
    *)
      rm -f "$response"
      return 1
      ;;
  esac
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
