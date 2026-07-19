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
      *" i/crlf "*|*" i/mixed "*|*" w/crlf "*|*" w/mixed "*)
        printf '%s\t%s\n' "$metadata" "$path" >&2
        failed=1
        ;;
    esac
    [ -e "$repo/$path" ] || continue
    if LC_ALL=C grep -q $'\r' "$repo/$path"; then
      printf 'raw CR byte\t%s\n' "$path" >&2
      failed=1
    fi
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

printf 'first\nsecond\n' > "$fixture/index-crlf.txt"
git -C "$fixture" add index-crlf.txt
index_crlf_blob=$(printf 'first\r\nsecond\r\n' | git -C "$fixture" hash-object -w --stdin)
git -C "$fixture" update-index --cacheinfo "100644,$index_crlf_blob,index-crlf.txt"
if check_tracked_text_lf "$fixture" > /dev/null 2>&1; then
  echo "tracked CRLF text in the Git index must fail even when the worktree copy is LF" >&2
  exit 1
fi

if ! check_tracked_text_lf "$ROOT"; then
  echo "tracked text files must use LF in the Git index and worktree" >&2
  exit 1
fi

echo "tracked text LF check ok"
