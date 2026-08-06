#!/usr/bin/env bash
# S4 BOOTSTRAP_STACK - cloud-init installs Docker, starts the stack, and gets TLS.
# The local agent polls the message-server-owned health endpoint until it returns 200.

run_phase() {
  phase_set S4_BOOTSTRAP_STACK polling "waiting for instance bootstrap and services"
  local domain pubip keyfile curl_connect_timeout curl_max_time
  domain=$(state_get domain)
  pubip=$(res_get public_ip)
  keyfile=$(res_get key_file)
  curl_connect_timeout=${HEALTH_CURL_CONNECT_TIMEOUT:-10}
  curl_max_time=${HEALTH_CURL_MAX_TIME:-20}

  log "Waiting for bootstrap (install Docker -> start postgres/message-server/caddy/coturn -> issue Let's Encrypt certificate)..."
  log "First image pull and certificate issuance usually take 5-10 minutes. Checking https://$domain/_p2p/health every ${HEALTH_POLL_INTERVAL:-10}s (curl connect timeout ${curl_connect_timeout}s, max ${curl_max_time}s) ..."

  if poll_until "health check https://$domain/_p2p/health == 200" \
       "${HEALTH_POLL_INTERVAL:-10}" "${HEALTH_POLL_MAX:-90}" _server_health_ok "$domain"; then
    phase_set S4_BOOTSTRAP_STACK done "_p2p/health 200 @ https://$domain"
    return 0
  fi

  phase_set S4_BOOTSTRAP_STACK failed "_p2p/health did not return 200 before timeout"
  local split_diagnostics
  split_diagnostics='stack=$(sudo sed -n "s/^stack_name=//p" /var/dirextalk-message-server/split/.manifest); sudo docker compose --project-name "$stack" -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml --env-file /var/dirextalk-message-server/split/.env ps; sudo docker compose --project-name "$stack" -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml --env-file /var/dirextalk-message-server/split/.env logs --tail=80 message-server'
  warn "Health check timed out. Inspect cloud-init logs over SSH:"
  warn "  ssh -i $keyfile ubuntu@$pubip 'sudo tail -n 80 /var/log/cloud-init-output.log; $split_diagnostics'"
  warn "See references/troubleshooting.md for targeted troubleshooting."
  return 1
}

_server_health_ok() {
  local domain=$1 pubip curl_args
  pubip=$(res_get public_ip)
  curl_args=(-skf --connect-timeout "${HEALTH_CURL_CONNECT_TIMEOUT:-10}" --max-time "${HEALTH_CURL_MAX_TIME:-20}")
  if [ -n "$pubip" ]; then
    curl "${curl_args[@]}" --resolve "$domain:443:$pubip" "https://$domain/_p2p/health" >/dev/null 2>&1 && return 0
  fi
  curl "${curl_args[@]}" "https://$domain/_p2p/health" >/dev/null 2>&1
}
