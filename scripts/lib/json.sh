#!/usr/bin/env bash
# Portable JSON helpers backed by Node.js.

JSON_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JSON_HELPER="$JSON_LIB_DIR/../json.mjs"
# shellcheck disable=SC1090
source "$JSON_LIB_DIR/local-paths.sh"

json_native_file_path() {
  dirextalk_native_tool_path "${1:-}"
}

json_normalize_file_arguments() {
  local command=${1:-}
  shift || true
  case "$command" in
    get|assert|check|entries|length|type|mutate|valid|lightsail-availability-zone|lightsail-bundle-select)
      [ "$#" -gt 0 ] || return 0
      set -- "$(json_native_file_path "$1")" "${@:2}"
      ;;
    operation-report)
      [ "$#" -ge 3 ] || return 0
      set -- "$1" "$2" "$(json_native_file_path "$3")" "${@:4}"
      ;;
    build)
      if [ "${1:-}" = "bootstrap-normalized" ] && [ "$#" -ge 2 ]; then
        set -- "$1" "$(json_native_file_path "$2")" "${@:3}"
      fi
      ;;
  esac
  printf '%s\0' "$command" "$@"
}

json_node() {
  local uname_s node_path
  if [ -n "${NODE:-}" ]; then
    printf '%s\n' "$NODE"
    return 0
  fi
  uname_s=$(uname -s 2>/dev/null || printf unknown)
  if command -v node >/dev/null 2>&1; then
    node_path=$(command -v node)
    case "$uname_s:$node_path" in
      Linux*:*.exe|Linux*:/mnt/*|Linux*:/c/*) ;;
      *)
        printf '%s\n' "$node_path"
        return 0
        ;;
    esac
  fi
  case "$uname_s" in
    Linux*)
      local user_home
      user_home=$(eval "printf '%s' ~${USER:-}" 2>/dev/null || true)
      for node_path in "$HOME/.local/node/bin/node" "$user_home/.local/node/bin/node" /usr/local/bin/node /usr/bin/node; do
        if [ -x "$node_path" ]; then
          printf '%s\n' "$node_path"
          return 0
        fi
      done
      echo "POSIX node is required for JSON processing on Linux; Windows node.exe cannot read POSIX paths." >&2
      return 1
      ;;
  esac
  if command -v node.exe >/dev/null 2>&1; then
    command -v node.exe
    return 0
  fi
  echo "node is required for JSON processing." >&2
  return 1
}

json_worker_connect() {
  [ -n "${DIREXTALK_JSON_WORKER_SOCKET:-}" ] && return 0
  if ! exec {DIREXTALK_JSON_WORKER_SOCKET}<>"/dev/tcp/127.0.0.1/${DIREXTALK_JSON_WORKER_PORT}"; then
    unset DIREXTALK_JSON_WORKER_SOCKET
    return 1
  fi
}

json_worker_cli() {
  local stdin_payload= status stdout stderr
  local -a normalized_args=("$@")
  case "${1:-}" in
    stdin-*)
      IFS= read -r -d '' stdin_payload || true
      ;;
  esac

  if ! json_worker_connect; then
    echo "Dirextalk test JSON worker is unavailable on its isolated loopback port." >&2
    return 125
  fi
  printf '%s\0%s\0%s\0%s\0' \
    "$DIREXTALK_JSON_WORKER_TOKEN" "$stdin_payload" "$PWD" "${#normalized_args[@]}" >&$DIREXTALK_JSON_WORKER_SOCKET
  printf '%s\0' "${normalized_args[@]}" >&$DIREXTALK_JSON_WORKER_SOCKET

  IFS= read -r -d '' status <&$DIREXTALK_JSON_WORKER_SOCKET || status=125
  IFS= read -r -d '' stdout <&$DIREXTALK_JSON_WORKER_SOCKET || stdout=
  IFS= read -r -d '' stderr <&$DIREXTALK_JSON_WORKER_SOCKET || stderr="JSON worker returned an incomplete response."

  [ -z "$stdout" ] || printf '%s' "$stdout"
  [ -z "$stderr" ] || printf '%s' "$stderr" >&2
  case "$status" in
    ''|*[!0-9]*) return 125 ;;
    *) return "$status" ;;
  esac
}

json_cli() {
  local node_bin helper command
  if [ -n "${DIREXTALK_TEST_ROOT:-}" ] && \
     [ -n "${DIREXTALK_JSON_WORKER_PORT:-}" ] && \
     [ -n "${DIREXTALK_JSON_WORKER_TOKEN:-}" ]; then
    json_worker_cli "$@"
    return $?
  fi
  node_bin=$(json_node) || return 1
  helper=$(dirextalk_native_tool_path "$JSON_HELPER") || return 1
  command=${1:-}
  case "$command" in
    stdin-*) "$node_bin" "$helper" "$@" ;;
    *) json_normalize_file_arguments "$@" | "$node_bin" "$helper" --args0 ;;
  esac
}

json_get() {
  json_cli get "$@"
}

json_stdin_get() {
  json_cli stdin-get "$@"
}

json_assert() {
  json_cli assert "$@"
}

json_stdin_assert() {
  json_cli stdin-assert "$@"
}

json_check() {
  json_cli check "$@"
}

json_entries() {
  json_cli entries "$@"
}

json_stdin_tsv() {
  json_cli stdin-tsv "$@"
}

json_stdin_join() {
  json_cli stdin-join "$@"
}

json_stdin_route53_a_values() {
  json_cli stdin-route53-a-values "$@"
}

json_stdin_route53_a_present() {
  json_cli stdin-route53-a-present "$@"
}

json_stdin_price_usd() {
  json_cli stdin-price-usd "$@"
}

json_lightsail_availability_zone() {
  json_cli lightsail-availability-zone "$@"
}

json_lightsail_bundle_select() {
  json_cli lightsail-bundle-select "$@"
}

json_length() {
  json_cli length "$@"
}

json_type() {
  json_cli type "$@"
}

json_build() {
  json_cli build "$@"
}

json_mutate() {
  local file=${1:-}
  json_cli mutate "$@" || return 1
  chmod 600 "$file" || return 1
  if declare -F dirextalk_restrict_private_file >/dev/null 2>&1; then
    dirextalk_restrict_private_file "$file" || return 1
  fi
}

json_valid() {
  json_cli valid "$@"
}

if [ -n "${DIREXTALK_TEST_ROOT:-}" ] && \
   [ -n "${DIREXTALK_JSON_WORKER_PORT:-}" ] && \
   [ -n "${DIREXTALK_JSON_WORKER_TOKEN:-}" ]; then
  json_worker_connect || true
fi
