#!/usr/bin/env bash
# lib/local-paths.sh - local host path normalization helpers.

dirextalk_local_path_style() {
  local style="${DIREXTALK_LOCAL_PATH_STYLE:-}"
  if [ -z "$style" ]; then
    case "$(uname -s 2>/dev/null || printf unknown)" in
      *MINGW*|*MSYS*|*CYGWIN*) style=windows ;;
      *) style=posix ;;
    esac
  fi
  printf '%s\n' "$style"
}

dirextalk_to_windows_local_path() {
  local path=${1:-} drive rest
  path=$(printf '%s' "$path" | sed 's#\\#/#g')
  case "$path" in
    [A-Za-z]:/*|[A-Za-z]:)
      drive=${path%%:*}
      rest=${path#?:}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_dirextalk_upper_drive "$drive")" "$rest"
      return 0
      ;;
    /mnt/[A-Za-z]/*|/mnt/[A-Za-z])
      drive=${path#/mnt/}
      drive=${drive%%/*}
      rest=${path#/mnt/$drive}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_dirextalk_upper_drive "$drive")" "$rest"
      return 0
      ;;
    /cygdrive/[A-Za-z]/*|/cygdrive/[A-Za-z])
      drive=${path#/cygdrive/}
      drive=${drive%%/*}
      rest=${path#/cygdrive/$drive}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_dirextalk_upper_drive "$drive")" "$rest"
      return 0
      ;;
    /[A-Za-z]/*|/[A-Za-z])
      drive=${path#/}
      drive=${drive%%/*}
      rest=${path#/$drive}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_dirextalk_upper_drive "$drive")" "$rest"
      return 0
      ;;
  esac
  if [ "${path#/}" != "$path" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path" 2>/dev/null && return 0
  fi
  printf '%s\n' "$path"
}

# Paths passed as argv to a native local tool must not rely on MSYS automatic
# conversion. Parent runtimes may disable it while Bash redirections still
# resolve paths such as /tmp in the Git Bash filesystem.
dirextalk_native_tool_path() {
  local path=${1:-}
  case "$(uname -s 2>/dev/null || printf unknown)" in
    *MINGW*|*MSYS*|*CYGWIN*) dirextalk_to_windows_local_path "$path" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

dirextalk_native_tool_at_path() {
  local path
  path=$(dirextalk_native_tool_path "${1:-}") || return 1
  printf '@%s\n' "$path"
}

dirextalk_native_null_device() {
  case "$(uname -s 2>/dev/null || printf unknown)" in
    *MINGW*|*MSYS*|*CYGWIN*) printf 'NUL\n' ;;
    *) printf '/dev/null\n' ;;
  esac
}

dirextalk_normalize_local_path() {
  local path=${1:-}
  case "$(dirextalk_local_path_style)" in
    windows) path=$(dirextalk_to_windows_local_path "$path") ;;
    *) path=$(printf '%s' "$path" | sed 's#\\#/#g') ;;
  esac
  _dirextalk_trim_trailing_slashes "$path"
}

dirextalk_paths_equal() {
  local left right
  left=$(dirextalk_normalize_local_path "$1")
  right=$(dirextalk_normalize_local_path "$2")
  case "$left:$right" in
    [A-Za-z]:/*:[A-Za-z]:/*|[A-Za-z]:[A-Za-z]:)
      [ "$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')" ]
      ;;
    *)
      [ "$left" = "$right" ]
      ;;
  esac
}

dirextalk_render_local_command() {
  local first=1 argument quoted
  [ "$#" -gt 0 ] || return 1
  for argument in "$@"; do
    [ "$first" -eq 1 ] || printf ' ' || return 1
    printf '%q' "$argument" || return 1
    first=0
  done
}

dirextalk_render_env_command() {
  local name=$1 value=$2
  shift 2
  case "$name" in
    ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 1 ;;
    *) ;;
  esac
  printf '%s=' "$name" || return 1
  printf '%q ' "$value" || return 1
  dirextalk_render_local_command "$@"
}

_dirextalk_upper_drive() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

_dirextalk_trim_trailing_slashes() {
  local path=${1:-}
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    case "$path" in [A-Za-z]:/) break ;; esac
    path=${path%/}
  done
  printf '%s\n' "$path"
}
