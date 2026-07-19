#!/usr/bin/env bash
# Simulate the limited `flock <file-descriptor>` contract used by remote
# Ubuntu bootstrap tests when Git Bash does not provide util-linux's flock.
set -euo pipefail

[ "$#" = 1 ] || { echo "fake flock expects one file descriptor" >&2; exit 2; }
case "$1" in
  ''|*[!0-9]*) echo "fake flock expects a numeric file descriptor" >&2; exit 2 ;;
esac

lock_dir=${DIREXTALK_TEST_FLOCK_DIR:?DIREXTALK_TEST_FLOCK_DIR is required}
owner_pid=$PPID
while ! mkdir "$lock_dir" 2>/dev/null; do
  sleep 0.02
done

# Keep the directory lock until the shell that owns the descriptor exits. The
# real production path uses Ubuntu's util-linux flock; this merely preserves
# its serialization guarantee for the Git Bash fixture.
(
  while kill -0 "$owner_pid" 2>/dev/null; do
    sleep 0.02
  done
  rmdir "$lock_dir" 2>/dev/null || true
) </dev/null >/dev/null 2>&1 &
