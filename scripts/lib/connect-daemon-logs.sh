# connect-daemon-logs.sh - shared dirextalk-connect daemon log classification.

connect_recent_daemon_logs() {
  awk '
    /config loaded|dirextalk-connect is running|acquired instance lock/ {
      buffer = ""
    }
    {
      buffer = buffer $0 "\n"
    }
    END {
      printf "%s", buffer
    }
  ' <<EOF
$1
EOF
}

connect_daemon_agent_error_from_text() {
  connect_recent_daemon_logs "$1" \
    | grep -Eio 'ACP_SESSION_INIT_FAILED|ACP metadata is missing|Recreate this ACP session|failed to create agent|failed to create platform|run_as_user: startup checks failed|CLI not found in PATH|Authentication required|agent login|not logged in|login required|not authenticated|Workspace Trust Required|agent backend offline|agent is offline|agent[^"]*offline|offline[^"]*agent' \
    | head -n 1 || true
}

connect_daemon_ready_from_text() {
  connect_recent_daemon_logs "$1" \
    | grep -Eio 'dirextalk-connect is running' \
    | head -n 1 || true
}

connect_daemon_agent_error_from_logs() {
  local binary=$1 service_name=$2 logs
  logs=$("$binary" daemon logs --service-name "$service_name" -n "${DIREXTALK_CONNECT_LOG_TAIL_LINES:-120}" 2>/dev/null || true)
  connect_daemon_agent_error_from_text "$logs"
}

connect_daemon_ready_from_logs() {
  local binary=$1 service_name=$2 logs
  logs=$("$binary" daemon logs --service-name "$service_name" -n "${DIREXTALK_CONNECT_LOG_TAIL_LINES:-120}" 2>/dev/null || true)
  connect_daemon_ready_from_text "$logs"
}
