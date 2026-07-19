#!/usr/bin/env bash
# lib/paths.sh - local Dirextalk service directory helpers.

PATHS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Git Bash launches Windows-native Node and AWS binaries. Keep paths handed to
# those consumers in native C:/ form, while Bash itself can still use them.
# shellcheck disable=SC1090
source "$PATHS_LIB_DIR/local-paths.sh"

dirextalk_execution_path() {
  local path=${1:-}
  if [ "$(dirextalk_local_path_style)" = "windows" ]; then
    dirextalk_to_windows_local_path "$path"
    return 0
  fi
  printf '%s\n' "$path"
}

dirextalk_home() {
  dirextalk_execution_path "${DIREXTALK_HOME:-$HOME/.dirextalk}"
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
    dirextalk_execution_path "$DIREXTALK_WORKDIR"
  elif [ -n "${DOMAIN:-}" ]; then
    dirextalk_service_dir "$DOMAIN"
  else
    printf '%s/nodes\n' "$(dirextalk_home)"
  fi
}
