#!/usr/bin/env bash
# Secret-bearing curl material is passed through protected files, never argv.

HTTP_SECRETS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$HTTP_SECRETS_LIB_DIR/private-files.sh"

dirextalk_private_temp_file() {
  local directory=$1 prefix=${2:-dirextalk-secret} file
  mkdir -p "$directory" || return 1
  file=$(mktemp "$directory/.${prefix}.XXXXXX") || return 1
  if ! dirextalk_restrict_private_file "$file"; then
    rm -f "$file" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$file"
}

dirextalk_curl_secret_headers() {
  local directory=$1 token=$2 node_id=${3:-} file
  file=$(dirextalk_private_temp_file "$directory" curl-headers) || return 1
  if ! {
    printf 'Authorization: Bearer %s\n' "$token"
    [ -z "$node_id" ] || printf 'DIREXTALK-Agent-Node-Id: %s\n' "$node_id"
  } > "$file"; then
    rm -f "$file" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$file"
}
