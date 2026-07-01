#!/usr/bin/env bash
# S5 INIT_TOKENS - fetch message-server bootstrap credentials from the instance.
# Also verify owner.json so the client does not report Portal as undeployed.

DIREXIO_REMOTE_BOOTSTRAP_FILE=${DIREXIO_REMOTE_BOOTSTRAP_FILE:-/var/direxio-message-server/p2p/bootstrap.json}
DIREXIO_LEGACY_REMOTE_BOOTSTRAP_FILE=${DIREXIO_LEGACY_REMOTE_BOOTSTRAP_FILE:-/opt/p2p/bootstrap.json}

run_phase() {
  phase_set S5_INIT_TOKENS in_progress "fetching tokens"
  local domain pubip keyfile
  domain=$(state_get domain)
  pubip=$(res_get public_ip)
  keyfile=$(res_get key_file)
  local out="$DIREXIO_WORKDIR/outputs.json" raw
  raw=$(mktemp)
  trap 'rm -f "${raw:-}"; trap - RETURN' RETURN

  log "Fetching ${DIREXIO_REMOTE_BOOTSTRAP_FILE} ..."
  if ! poll_until "read bootstrap.json" "${TOKEN_POLL_INTERVAL:-10}" "${TOKEN_POLL_MAX:-12}" \
        _read_remote_bootstrap "$keyfile" "$pubip" "$raw"; then
    phase_set S5_INIT_TOKENS failed "failed to fetch bootstrap.json"
    warn "Could not read ${DIREXIO_REMOTE_BOOTSTRAP_FILE}. Check whether message-server wrote credentials:"
    warn "  ssh -i $keyfile ubuntu@$pubip 'sudo cat ${DIREXIO_REMOTE_BOOTSTRAP_FILE} 2>/dev/null; cd /var/direxio-message-server; sudo docker compose logs message-server | tail -40'"
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
    warn "  Check Caddy file_server and /var/direxio-message-server/wellknown/owner.json generation."
  fi

  local password token access_token asurl agent_room_id
  if ! IFS=$'\t' read -r password token access_token < <(_extract_output_tokens "$out"); then
    phase_set S5_INIT_TOKENS failed "bootstrap.json missing password/access/agent credentials"
    fail "bootstrap.json must contain password as an eight-digit initialization-code string plus access_token and agent_token."
  fi
  asurl=$(json_get "$out" as_url "https://$domain")
  agent_room_id=$(json_get "$out" agent_room_id)
  if [ -z "$agent_room_id" ] || [[ "$agent_room_id" == \!agent:* ]]; then
    phase_set S5_INIT_TOKENS failed "bootstrap.json missing real agent_room_id"
    fail "bootstrap.json must contain a real Matrix agent_room_id; legacy !agent:<domain> ids are not supported."
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
  cmd=(ssh "${ssh_args[@]}" ubuntu@"$pubip" "if sudo test -s '${DIREXIO_REMOTE_BOOTSTRAP_FILE}'; then sudo cat '${DIREXIO_REMOTE_BOOTSTRAP_FILE}'; elif sudo test -s '${DIREXIO_LEGACY_REMOTE_BOOTSTRAP_FILE}'; then sudo cat '${DIREXIO_LEGACY_REMOTE_BOOTSTRAP_FILE}'; else exit 1; fi")
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
  tmp=$(mktemp)
  if ! json_build bootstrap-normalized "$src" "$domain" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
  chmod 600 "$out" 2>/dev/null || true
}

_healthz_ok_ownerjson() {
  local domain=$1 pubip args=()
  pubip=$(res_get public_ip)
  [ -n "$pubip" ] && args=(--resolve "$domain:443:$pubip")
  [ "$(curl -sk "${args[@]}" -o /dev/null -w '%{http_code}' "https://$domain/.well-known/portal/owner.json" 2>/dev/null)" = "200" ]
}
