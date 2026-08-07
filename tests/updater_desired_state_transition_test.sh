#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
cleanup() {
  if [ -f "$tmp/socket.pid" ]; then kill "$(cat "$tmp/socket.pid")" >/dev/null 2>&1 || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

test_root=$tmp/root
test_bin=$tmp/bin
scenario=$tmp/scenario
mkdir -p "$test_root/run/dirextalk-updater" "$test_root/etc/dirextalk-updater" "$test_bin"
printf 'control-token\n' >"$test_root/etc/dirextalk-updater/control-token"
chmod 0600 "$test_root/etc/dirextalk-updater/control-token"
printf 'success\n' >"$scenario"

python3 - "$test_root/run/dirextalk-updater/http.sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
time.sleep(300)
PY
printf '%s\n' "$!" >"$tmp/socket.pid"
for _ in 1 2 3 4 5; do [ -S "$test_root/run/dirextalk-updater/http.sock" ] && break; sleep 0.1; done
[ -S "$test_root/run/dirextalk-updater/http.sock" ]

cat >"$test_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  cat|start|is-active) exit 0 ;;
  *) exit 91 ;;
esac
EOF
cat >"$test_bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
EOF
cat >"$test_bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
format=
for arg in "$@"; do case "$arg" in %*) format=$arg ;; esac; done
if [ "$format" = %u:%g:%a ]; then
  printf '0:0:%s\n' "$(/usr/bin/stat -c '%a' "${!#}")"
else
  exec /usr/bin/stat "$@"
fi
EOF
cat >"$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output= desired=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --data) desired=$2; shift 2 ;;
    --unix-socket|--header|--write-out|--config) shift 2 ;;
    --silent|--show-error) shift ;;
    *) shift ;;
  esac
done
case "$(cat "$TEST_SCENARIO")" in
  success)
    state=$(sed -n 's/.*"desired_state":"\([^"]*\)".*/\1/p' <<<"$desired")
    printf '{"desired_state":"%s"}\n' "$state" >"$output"
    printf '200'
    ;;
  active)
    printf '{"error":"operation_in_progress"}\n' >"$output"
    printf '409'
    ;;
  transport) exit 7 ;;
  invalid)
    printf '{"desired_state":"maintenance"}\n' >"$output"
    printf '200'
    ;;
  *) exit 92 ;;
esac
EOF
chmod 0755 "$test_bin/"*
export TEST_SCENARIO=$scenario

run_helper() {
  PATH="$test_bin:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$test_root" \
    DIREXTALK_UPDATER_READY_ATTEMPTS=1 \
    bash "$ROOT/scripts/updater/set-desired-state.sh" running
}

run_helper >/dev/null

printf 'active\n' >"$scenario"
if run_helper >/dev/null 2>&1; then echo 'active updater operation was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 3 ]

printf 'transport\n' >"$scenario"
if run_helper >/dev/null 2>&1; then echo 'updater transport failure was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 1 ]

printf 'invalid\n' >"$scenario"
if run_helper >/dev/null 2>&1; then echo 'invalid updater response was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 1 ]

echo 'updater desired state transition ok'
