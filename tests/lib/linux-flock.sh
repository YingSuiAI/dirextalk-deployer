#!/usr/bin/env bash
# Simulate the limited `flock <file-descriptor>` and `flock -u
# <file-descriptor>` contract used by remote Ubuntu bootstrap tests when Git
# Bash does not provide util-linux's flock.
set -euo pipefail

mode=lock
case "$#" in
  1) fd=$1 ;;
  2)
    [ "$1" = -u ] || { echo "fake flock expects -u before the file descriptor" >&2; exit 2; }
    mode=unlock
    fd=$2
    ;;
  *) echo "fake flock expects a file descriptor or -u plus one" >&2; exit 2 ;;
esac
case "$fd" in
  ''|*[!0-9]*) echo "fake flock expects a numeric file descriptor" >&2; exit 2 ;;
esac

lock_dir=${DIREXTALK_TEST_FLOCK_DIR:?DIREXTALK_TEST_FLOCK_DIR is required}
owner_pid=$PPID
owner_file="$lock_dir/owner"

if [ "$mode" = unlock ]; then
  if [ -f "$owner_file" ] && [ "$(cat "$owner_file")" = "$owner_pid" ]; then
    rm -f "$owner_file"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  exit 0
fi

while ! mkdir "$lock_dir" 2>/dev/null; do
  sleep 0.02
done
printf '%s\n' "$owner_pid" > "$owner_file"

# Keep the directory lock until the shell that owns the descriptor exits. The
# real production path uses Ubuntu's util-linux flock; this merely preserves
# its serialization guarantee for the Git Bash fixture.
(
  while kill -0 "$owner_pid" 2>/dev/null; do
    sleep 0.02
  done
  if [ -f "$owner_file" ] && [ "$(cat "$owner_file")" = "$owner_pid" ]; then
    rm -f "$owner_file"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
) </dev/null >/dev/null 2>&1 &
