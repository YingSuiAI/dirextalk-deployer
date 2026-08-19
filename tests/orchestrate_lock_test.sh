#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
work="$tmp/work"
mkdir -p "$tmp/home"

holder_ready="$tmp/holder.ready"
DIREXTALK_ORCHESTRATE_LIB_ONLY=1 DIREXTALK_WORKDIR="$work" HOME="$tmp/home" RUN_ID=lock-holder \
  bash -c '
    set -euo pipefail
    source "$1/scripts/orchestrate.sh"
    state_ensure >/dev/null
    acquire_orchestrate_lock
    : >"$2"
    trap "exit 0" TERM INT
    while :; do sleep 1; done
  ' bash "$ROOT" "$holder_ready" &
holder_pid=$!
for _ in $(seq 1 50); do
  [ -f "$holder_ready" ] && break
  sleep 0.1
done
[ -f "$holder_ready" ]
receipt="$work/.orchestrate.lock/owner/receipt"
grep -Fxq "pid=$holder_pid" "$receipt"
grep -Eq '^starttime=[0-9]+$|^starttime=unknown$' "$receipt"

if DIREXTALK_ORCHESTRATE_LIB_ONLY=1 DIREXTALK_WORKDIR="$work" HOME="$tmp/home" \
    bash -c 'source "$1/scripts/orchestrate.sh"; acquire_orchestrate_lock' bash "$ROOT"; then
  echo 'a second orchestrate owner acquired the active universal lock' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi

kill "$holder_pid"
wait "$holder_pid" || true
[ ! -e "$work/.orchestrate.lock/owner/receipt" ]

# A dead owner receipt is recoverable, while retaining the same universal
# owner directory and receipt contract used by the flock path.
mkdir -p "$work/.orchestrate.lock/owner"
cat >"$work/.orchestrate.lock/owner/receipt" <<EOF
pid=999999
starttime=1
run_id=dead-owner
state=$work/state.json
EOF
DIREXTALK_ORCHESTRATE_LIB_ONLY=1 DIREXTALK_WORKDIR="$work" HOME="$tmp/home" \
  bash -c 'source "$1/scripts/orchestrate.sh"; acquire_orchestrate_lock; grep -q "^pid=$$" "$DIREXTALK_WORKDIR/.orchestrate.lock/owner/receipt"; _orchestrate_lock_cleanup' bash "$ROOT"
[ ! -e "$work/.orchestrate.lock/owner/receipt" ]

echo 'orchestrate universal owner lock ok'
