#!/usr/bin/env bash
# Portable JSON helpers backed by Node.js.

JSON_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JSON_HELPER="$JSON_LIB_DIR/../json.mjs"

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
      echo "POSIX node is required for JSON processing in Linux/WSL; Windows node.exe cannot read POSIX paths." >&2
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

json_cli() {
  local node_bin
  node_bin=$(json_node) || return 1
  case "${1:-}" in
    stdin-*) "$node_bin" "$JSON_HELPER" "$@" ;;
    *) printf '%s\0' "$@" | "$node_bin" "$JSON_HELPER" --args0 ;;
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
