#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

check_tracked_text_lf() {
  local repo=$1 record metadata path failed=0
  while IFS= read -r -d '' record; do
    metadata=${record%%$'\t'*}
    path=${record#*$'\t'}
    case " $metadata " in
      *" i/-text "*) continue ;;
    esac
    case " $metadata " in
      *" w/crlf "*|*" w/mixed "*)
        printf '%s\t%s\n' "$metadata" "$path" >&2
        failed=1
        ;;
    esac
  done < <(git -C "$repo" ls-files --eol -z)
  [ "$failed" -eq 0 ]
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q
git -C "$fixture" config core.autocrlf false
printf '\000\r\001\002' > "$fixture/binary-with-cr.bin"
git -C "$fixture" add binary-with-cr.bin
check_tracked_text_lf "$fixture" || {
  echo "binary files classified as i/-text must not fail the LF gate" >&2
  exit 1
}
printf 'first\r\nsecond\r\n' > "$fixture/crlf.txt"
git -C "$fixture" add crlf.txt
if check_tracked_text_lf "$fixture" > /dev/null 2>&1; then
  echo "tracked CRLF text must fail the LF gate" >&2
  exit 1
fi

if ! check_tracked_text_lf "$ROOT"; then
  echo "tracked text files must use LF in the worktree" >&2
  exit 1
fi

echo "tracked text LF check ok"
