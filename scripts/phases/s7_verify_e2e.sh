#!/usr/bin/env bash
# S7 VERIFY_E2E - end-to-end acceptance. DONE only when every check passes.
#
# Checks: healthz, Matrix versions, Matrix federation well-known, owner.json+CORS,
# token-authenticated HTTP MCP read action, and non-empty TURN turnServer.
# Local bridge message send/read is validated separately; this script checks HTTP actions.

S7_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$S7_DIR/../lib/http-secrets.sh"

run_phase() {
  phase_set S7_VERIFY_E2E in_progress "running end-to-end acceptance"
  local domain password
  domain=$(state_get domain)
  password=$(state_get password)
  local fails=0

  _check "healthz"               "https://$domain/healthz"                       "" 200 || fails=$((fails+1))
  _check "matrix versions"       "https://$domain/_matrix/client/versions"       "" 200 || fails=$((fails+1))
  _check_matrix_server_wellknown "$domain" || fails=$((fails+1))
  _check_owner_cors "$domain" || fails=$((fails+1))
  _check_mcp_agent_auth || fails=$((fails+1))
  _check_turn "$domain" "$password" || fails=$((fails+1))

  if [ "$fails" -eq 0 ]; then
    phase_set S7_VERIFY_E2E done "all green"
    return 0
  fi
  phase_set S7_VERIFY_E2E failed "$fails checks failed"
  warn "$fails acceptance checks failed. See references/troubleshooting.md for targeted fixes."
  return 1
}

_check_mcp_agent_auth() {
  if cmd_verify_mcp_smoke >/dev/null; then
    ok "  ✓ HTTP MCP dirextalk_messages_list (agent token)"
    return 0
  fi
  warn "  ✗ HTTP MCP dirextalk_messages_list (agent token)"
  return 1
}

_p2p_access_token() {
  local domain=$1 password=$2 at payload_file
  local args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  payload_file=$(dirextalk_private_temp_file "${TMPDIR:-/tmp}" portal-auth) || return 1
  if ! json_build portal-auth "$password" > "$payload_file"; then
    rm -f "$payload_file"
    return 1
  fi
  at=$(curl -sk "${args[@]}" -X POST "https://$domain/_p2p/command" -H 'Content-Type: application/json' \
        --data-binary "@$payload_file" 2>/dev/null | json_stdin_get access_token)
  rm -f "$payload_file"
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
  if printf '%s' "$body" | json_stdin_assert well-known-server "$domain:443" >/dev/null 2>&1; then
    ok "  ✓ matrix federation well-known ($domain:443)"; return 0
  fi
  warn "  x matrix federation well-known invalid:$(printf '%s' "$body" | head -c 120)"; return 1
}

# _check <name> <url> <bearer-token-or-empty> <expected-code>
_check() {
  local name=$1 url=$2 tok=$3 want=$4 code headers
  local domain args=()
  domain=$(state_get domain)
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  if [ -n "$tok" ]; then
    headers=$(dirextalk_curl_secret_headers "${TMPDIR:-/tmp}" "$tok") || return 1
    code=$(curl -sk "${args[@]}" -o /dev/null -w '%{http_code}' -H "@$headers" "$url" 2>/dev/null)
    rm -f "$headers"
  else
    code=$(curl -sk "${args[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
  fi
  if [ "$code" = "$want" ]; then ok "  ✓ $name ($code)"; return 0
  else warn "  ✗ $name (got $code, want $want)"; return 1; fi
}

# TURN acceptance: exchange the backend password/init-code field for Matrix access_token, then verify
# /voip/turnServer returns non-empty valid TURN credentials.
_check_turn() {
  local domain=$1 password=$2 at turn headers
  local args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(curl_resolve_args "$domain")
  at=$(_p2p_access_token "$domain" "$password")
  if [ -z "$at" ]; then warn "  x TURN (failed to exchange access_token; cannot verify turnServer)"; return 1; fi
  headers=$(dirextalk_curl_secret_headers "${TMPDIR:-/tmp}" "$at") || return 1
  turn=$(curl -sk "${args[@]}" "https://$domain/_matrix/client/v3/voip/turnServer" \
          -H "@$headers" 2>/dev/null)
  rm -f "$headers"
  if printf '%s' "$turn" | json_stdin_assert turn-credentials >/dev/null 2>&1; then
    ok "  ✓ TURN turnServer non-empty and valid"; return 0
  else
    warn "  x TURN turnServer invalid/empty:$(printf '%s' "$turn" | head -c 120)"; return 1
  fi
}
