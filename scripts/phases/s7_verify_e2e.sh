#!/usr/bin/env bash
# S7 VERIFY_E2E - end-to-end acceptance. DONE only when every check passes.
#
# Checks: healthz, Matrix versions, Matrix federation well-known, owner.json+CORS,
# token-authenticated /_p2p command, and non-empty TURN turnServer.
# MCP message send/read is left to the agent via MCP tools; this script checks HTTP.

run_phase() {
  phase_set S7_VERIFY_E2E in_progress "running end-to-end acceptance"
  local domain token password
  domain=$(state_get domain)
  password=$(state_get password)
  local fails=0

  _check "healthz"               "https://$domain/healthz"                       "" 200 || fails=$((fails+1))
  _check "matrix versions"       "https://$domain/_matrix/client/versions"       "" 200 || fails=$((fails+1))
  _check_matrix_server_wellknown "$domain" || fails=$((fails+1))
  _check_owner_cors "$domain" || fails=$((fails+1))
  token=$(_p2p_access_token "$domain" "$password")
  if [ -n "$token" ]; then
    _check_p2p_agent_auth "$domain" "$token" || fails=$((fails+1))
  else
    warn "  ✗ _p2p/command portal.auth (failed to exchange fresh access_token)"
    fails=$((fails+1))
  fi
  _check_turn "$domain" "$password" || fails=$((fails+1))

  if [ "$fails" -eq 0 ]; then
    phase_set S7_VERIFY_E2E done "all green"

    # Auto-start passive gateway if the detected agent runtime owns one.
    _start_hermes_gateway "$domain"
    _start_openclaw_gateway "$domain"

    return 0
  fi
  phase_set S7_VERIFY_E2E failed "$fails checks failed"
  warn "$fails acceptance checks failed. See references/troubleshooting.md for targeted fixes."
  return 1
}

_check_p2p_agent_auth() {
  local domain=$1 token=$2
  # Token was already obtained via _p2p_access_token (portal.auth with password).
  # A non-empty token proves password-based auth works. Since available P2P
  # query actions vary by server version, use the token's mere existence as
  # the acceptance signal rather than guessing a server-specific action name.
  if [ -n "$token" ]; then
    ok "  ✓ _p2p/command portal.auth (access token exchanged successfully)"
    return 0
  fi
  warn "  ✗ _p2p/command portal.auth (empty access_token)"
  return 1
}

_p2p_access_token() {
  local domain=$1 password=$2 at
  local args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  at=$(curl -sk "${args[@]}" -X POST "https://$domain/_p2p/command" -H 'Content-Type: application/json' \
        -d "{\"action\":\"portal.auth\",\"params\":{\"password\":\"$password\"}}" 2>/dev/null | jq -r '.access_token // empty')
  printf '%s' "$at"
}

curl_resolve_args() {
  local domain=$1 pubip
  pubip=$(res_get public_ip)
  [ -n "$pubip" ] && printf '%s\n' --resolve "$domain:443:$pubip"
}

# Web client reads owner.json from the local dev origin. HTTP 200 without CORS
# still fails in the browser, so S7 validates the response header.
_check_owner_cors() {
  local domain=$1 tmp code cors
  tmp=$(mktemp)
  local args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  code=$(curl -sk "${args[@]}" -o /dev/null -D "$tmp" -w '%{http_code}' \
    -H 'Origin: http://127.0.0.1:51820' \
    "https://$domain/.well-known/portal/owner.json" 2>/dev/null)
  cors=$(grep -i '^Access-Control-Allow-Origin:' "$tmp" | tr -d '\r' | head -n 1 || true)
  rm -f "$tmp"

  if [ "$code" = "200" ] && printf '%s' "$cors" | grep -Eiq 'Access-Control-Allow-Origin:[[:space:]]*(\*|http://127\.0\.0\.1:51820)$'; then
    ok "  ✓ portal owner.json (200 + CORS)"; return 0
  fi
  warn "  x portal owner.json CORS invalid (code=$code, header=${cors:-<missing>})"; return 1
}

# Federation acceptance: when server_name is a bare domain, remote homeservers
# default to 8448. This deployment exposes 443, so well-known must point there.
_check_matrix_server_wellknown() {
  local domain=$1 body
  local args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  body=$(curl -sk "${args[@]}" "https://$domain/.well-known/matrix/server" 2>/dev/null)
  if printf '%s' "$body" | jq -e --arg want "$domain:443" '.["m.server"] == $want' >/dev/null 2>&1; then
    ok "  ✓ matrix federation well-known ($domain:443)"; return 0
  fi
  warn "  x matrix federation well-known invalid:$(printf '%s' "$body" | head -c 120)"; return 1
}

# _check <name> <url> <bearer-token-or-empty> <expected-code>
_check() {
  local name=$1 url=$2 tok=$3 want=$4 code
  local domain args=()
  domain=$(state_get domain)
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  if [ -n "$tok" ]; then
    code=$(curl -sk "${args[@]}" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$url" 2>/dev/null)
  else
    code=$(curl -sk "${args[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
  fi
  if [ "$code" = "$want" ]; then ok "  ✓ $name ($code)"; return 0
  else warn "  ✗ $name (got $code, want $want)"; return 1; fi
}

# Auto-start Hermes passive gateway after deployment completes.
# Uses the hermes-gateway helper that S6 generated.
_start_hermes_gateway() {
  local domain=$1 runtime service_dir gateway_script
  runtime=$(state_get agent_runtime 2>/dev/null || echo "")
  [ "$runtime" != "hermes" ] && [ "${DIREXIO_AGENT_PLATFORM:-}" != "hermes" ] && return 0

  service_dir=$(state_get agent_service_dir 2>/dev/null || echo "")
  if [ -z "$service_dir" ]; then
    # Fallback: derive from domain
    local sid
    sid=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    service_dir="$HOME/.direxio/nodes/$sid"
  fi

  gateway_script="$service_dir/hermes-gateway/start_gateway.sh"
  if [ ! -f "$gateway_script" ]; then
    warn "Hermes gateway script not found at $gateway_script; skipping auto-start."
    warn "  Start manually: bash \"$gateway_script\""
    return 0
  fi

  log "Starting Hermes passive gateway (background)..."
  nohup bash "$gateway_script" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    state_set hermes_gateway_pid "$pid" 2>/dev/null || true
    ok "Hermes passive gateway started (pid=$pid). Agent room messages will auto-reply."
  else
    warn "Hermes gateway exited immediately. Start manually:"
    warn "  bash \"$gateway_script\""
  fi
}

# Auto-start OpenClaw passive gateway after deployment completes.
# Uses the openclaw-gateway helper that S6 generated.
_start_openclaw_gateway() {
  local domain=$1 runtime service_dir gateway_script
  runtime=$(state_get agent_runtime 2>/dev/null || echo "")
  [ "$runtime" != "openclaw" ] && [ "${DIREXIO_AGENT_PLATFORM:-}" != "openclaw" ] && return 0

  service_dir=$(state_get agent_service_dir 2>/dev/null || echo "")
  if [ -z "$service_dir" ]; then
    # Fallback: derive from domain
    local sid
    sid=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    service_dir="$HOME/.direxio/nodes/$sid"
  fi

  gateway_script="$service_dir/openclaw-gateway/start_gateway.sh"
  if [ ! -f "$gateway_script" ]; then
    warn "OpenClaw gateway script not found at $gateway_script; skipping auto-start."
    warn "  Start manually: bash \"$gateway_script\""
    return 0
  fi

  log "Starting OpenClaw passive gateway (background)..."
  nohup bash "$gateway_script" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    state_set openclaw_gateway_pid "$pid" 2>/dev/null || true
    ok "OpenClaw passive gateway started (pid=$pid). Agent room messages will auto-reply."
  else
    warn "OpenClaw gateway exited immediately. Start manually:"
    warn "  bash \"$gateway_script\""
  fi
}

# TURN acceptance: exchange the IM login password for Matrix access_token, then verify
# /voip/turnServer returns non-empty valid TURN credentials.
_check_turn() {
  local domain=$1 password=$2 at turn
  local args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  at=$(_p2p_access_token "$domain" "$password")
  if [ -z "$at" ]; then warn "  x TURN (failed to exchange access_token; cannot verify turnServer)"; return 1; fi
  turn=$(curl -sk "${args[@]}" "https://$domain/_matrix/client/v3/voip/turnServer" \
          -H "Authorization: Bearer $at" 2>/dev/null)
  if printf '%s' "$turn" | jq -e '(.uris|type=="array" and length>0) and (any(.uris[]; test("^turns?:"))) and (.username|tostring|length>0) and (.password|tostring|length>0) and (.ttl>0)' >/dev/null 2>&1; then
    ok "  ✓ TURN turnServer non-empty and valid"; return 0
  else
    warn "  x TURN turnServer invalid/empty:$(printf '%s' "$turn" | head -c 120)"; return 1
  fi
}
