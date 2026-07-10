#!/usr/bin/env bash
# Canonical remote MCP endpoint validation shared by token and wiring phases.

dirextalk_service_origin() {
  local service_url=${1:-} authority host= port= label
  case "$service_url" in
    https://*) ;;
    *) return 1 ;;
  esac
  service_url=${service_url%/}
  authority=${service_url#https://}
  [ -n "$authority" ] || return 1
  case "$authority" in *[/?#@]*) return 1 ;; esac
  if [[ "$authority" =~ ^\[[0-9A-Fa-f:]+\](:[0-9]+)?$ ]]; then
    case "$authority" in
      *]:*) port=${authority##*]:} ;;
    esac
  elif [[ "$authority" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    host=${authority%%:*}
    case "$authority" in *:*) port=${authority##*:} ;; esac
    case "$host" in .*|*..*|*.) return 1 ;; esac
    while IFS= read -r label; do
      case "$label" in ''|-*|*-) return 1 ;; esac
    done < <(printf '%s\n' "$host" | tr '.' '\n')
  else
    return 1
  fi
  if [ -n "$port" ]; then
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] || return 1
  fi
  printf '%s\n' "$service_url"
}

dirextalk_mcp_endpoint_url() {
  local origin
  origin=$(dirextalk_service_origin "$1") || return 1
  printf '%s/mcp\n' "$origin"
}
