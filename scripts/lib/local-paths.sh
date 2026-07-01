#!/usr/bin/env bash
# lib/local-paths.sh - local host path normalization helpers.

direxio_local_path_style() {
  local style="${DIREXIO_LOCAL_PATH_STYLE:-}"
  if [ -z "$style" ]; then
    case "$(uname -s 2>/dev/null || printf unknown)" in
      *MINGW*|*MSYS*|*CYGWIN*) style=windows ;;
      *) style=posix ;;
    esac
  fi
  printf '%s\n' "$style"
}

direxio_to_windows_local_path() {
  local path=${1:-} drive rest
  path=$(printf '%s' "$path" | sed 's#\\#/#g')
  case "$path" in
    [A-Za-z]:/*|[A-Za-z]:)
      drive=${path%%:*}
      rest=${path#?:}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_direxio_upper_drive "$drive")" "$rest"
      return 0
      ;;
    /mnt/[A-Za-z]/*|/mnt/[A-Za-z])
      drive=${path#/mnt/}
      drive=${drive%%/*}
      rest=${path#/mnt/$drive}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_direxio_upper_drive "$drive")" "$rest"
      return 0
      ;;
    /cygdrive/[A-Za-z]/*|/cygdrive/[A-Za-z])
      drive=${path#/cygdrive/}
      drive=${drive%%/*}
      rest=${path#/cygdrive/$drive}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_direxio_upper_drive "$drive")" "$rest"
      return 0
      ;;
    /[A-Za-z]/*|/[A-Za-z])
      drive=${path#/}
      drive=${drive%%/*}
      rest=${path#/$drive}
      [ -n "$rest" ] || rest=/
      printf '%s:%s\n' "$(_direxio_upper_drive "$drive")" "$rest"
      return 0
      ;;
  esac
  if [ "${path#/}" != "$path" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path" 2>/dev/null && return 0
  fi
  printf '%s\n' "$path"
}

direxio_normalize_local_path() {
  local path=${1:-}
  case "$(direxio_local_path_style)" in
    windows) path=$(direxio_to_windows_local_path "$path") ;;
    *) path=$(printf '%s' "$path" | sed 's#\\#/#g') ;;
  esac
  _direxio_trim_trailing_slashes "$path"
}

direxio_paths_equal() {
  local left right
  left=$(direxio_normalize_local_path "$1")
  right=$(direxio_normalize_local_path "$2")
  case "$left:$right" in
    [A-Za-z]:/*:[A-Za-z]:/*|[A-Za-z]:[A-Za-z]:)
      [ "$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')" ]
      ;;
    *)
      [ "$left" = "$right" ]
      ;;
  esac
}

_direxio_upper_drive() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

_direxio_trim_trailing_slashes() {
  local path=${1:-}
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    case "$path" in [A-Za-z]:/) break ;; esac
    path=${path%/}
  done
  printf '%s\n' "$path"
}
