#!/usr/bin/env bash
# lib/paths.sh - local Dirextalk service directory helpers.

dirextalk_home() {
  printf '%s\n' "${DIREXTALK_HOME:-$HOME/.dirextalk}"
}

dirextalk_service_id() {
  local raw=${1:-} host
  host=${raw#http://}
  host=${host#https://}
  host=${host%%/*}
  case "$host" in
    *:*) host="${host%%:*}-${host#*:}" ;;
  esac
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]' | sed -E 's/:/-/g; s/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/^$/dirextalk-service/'
}

dirextalk_service_dir() {
  local service_id
  service_id=$(dirextalk_service_id "$1")
  printf '%s/nodes/%s\n' "$(dirextalk_home)" "$service_id"
}

dirextalk_default_workdir() {
  if [ -n "${DIREXTALK_WORKDIR:-}" ]; then
    printf '%s\n' "$DIREXTALK_WORKDIR"
  elif [ -n "${DOMAIN:-}" ]; then
    dirextalk_service_dir "$DOMAIN"
  else
    printf '%s/nodes\n' "$(dirextalk_home)"
  fi
}
