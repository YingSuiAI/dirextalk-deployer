#!/usr/bin/env bash
# atomic-write.sh - guarded same-directory writes for local generated files.

ATOMIC_WRITE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$ATOMIC_WRITE_LIB_DIR/private-files.sh"

dirextalk_atomic_write() {
  local destination=$1 mode=$2 directory base temporary
  shift 2
  [ "$#" -gt 0 ] || return 1

  directory=$(dirname "$destination") || return 1
  base=$(basename "$destination") || return 1
  mkdir -p "$directory" || return 1
  if [ -d "$destination" ]; then
    return 1
  fi

  umask 077
  temporary=$(mktemp "$directory/.${base}.tmp.XXXXXX") || return 1
  if ! dirextalk_restrict_private_file "$temporary"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
  if ! "$@" > "$temporary"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
  if ! chmod "$mode" "$temporary"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
}
