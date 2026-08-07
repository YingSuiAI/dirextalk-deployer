#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)" in
  Linux) ;;
  *) printf 'updater existing state transition skipped on non-Linux host\n'; exit 0 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
cleanup() {
  if [ -f "$tmp/socket.pid" ]; then kill "$(cat "$tmp/socket.pid")" >/dev/null 2>&1 || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

make_fixture() {
  local name=$1
  if [ -f "$tmp/socket.pid" ]; then
    kill "$(cat "$tmp/socket.pid")" >/dev/null 2>&1 || true
    rm -f "$tmp/socket.pid"
  fi
  TEST_ROOT="$tmp/$name/root"
  TEST_BASE="$TEST_ROOT/var/dirextalk-message-server"
  TEST_SOURCE="$tmp/$name/source"
  TEST_BIN="$tmp/$name/bin"
  TEST_CALLS="$tmp/$name/calls"
  TEST_SERVICE_STATE="$tmp/$name/service-state"
  TEST_SCENARIO="$tmp/$name/scenario"
  TEST_SOCKET_PID="$tmp/socket.pid"
  export TEST_ROOT TEST_BASE TEST_SOURCE TEST_BIN TEST_CALLS TEST_SERVICE_STATE TEST_SCENARIO TEST_SOCKET_PID
  mkdir -p "$TEST_SOURCE" "$TEST_BIN" "$TEST_BASE" \
    "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/etc/dirextalk-updater" \
    "$TEST_ROOT/var/lib/dirextalk-updater" "$TEST_ROOT/run/dirextalk-updater" \
    "$TEST_ROOT/usr/local/bin"
  : >"$TEST_CALLS"
  printf 'active\n' >"$TEST_SERVICE_STATE"
  printf 'idle\n' >"$TEST_SCENARIO"
  printf '[Unit]\nDescription=fixture\n' >"$TEST_ROOT/etc/systemd/system/dirextalk-updater.service"
  printf 'control-token\n' >"$TEST_ROOT/etc/dirextalk-updater/control-token"
  chmod 0600 "$TEST_ROOT/etc/dirextalk-updater/control-token"
  printf '%s\n' '{"schema_version":7,"desired_state":"running","watchdog":{"status":"unknown"}}' \
    >"$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
  chmod 0600 "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"

  cat >"$TEST_ROOT/usr/local/bin/dirextalk-updater" <<'EOF'
#!/usr/bin/env bash
printf '{"version":"v1.0.0","commit":"1111111111111111111111111111111111111111"}\n'
EOF
  chmod 0755 "$TEST_ROOT/usr/local/bin/dirextalk-updater"
  cat >"$tmp/$name/target-updater" <<'EOF'
#!/usr/bin/env bash
printf '{"version":"v2.0.0","commit":"2222222222222222222222222222222222222222"}\n'
EOF
  chmod 0755 "$tmp/$name/target-updater"
  TEST_TARGET="$tmp/$name/target-updater"
  TEST_TARGET_SHA=$(sha256sum "$TEST_TARGET" | awk '{print $1}')
  export TEST_TARGET TEST_TARGET_SHA

  for file in install.sh reconcile-host.sh set-desired-state.sh; do
    cp "$ROOT/scripts/updater/$file" "$TEST_SOURCE/$file"
  done
  cat >"$TEST_SOURCE/bootstrap-host.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --preflight ]; then
  printf 'preflight\n' >>"$TEST_CALLS"
  exit 0
fi
printf 'bootstrap\n' >>"$TEST_CALLS"
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ] \
  || printf 'fresh-reset\n' >>"$TEST_CALLS"
cp "$TEST_TARGET" "$TEST_ROOT/usr/local/bin/dirextalk-updater"
chmod 0755 "$TEST_ROOT/usr/local/bin/dirextalk-updater"
EOF
  cat >"$TEST_SOURCE/release.env" <<EOF
UPDATER_PIN_VERSION=v2.0.0
UPDATER_PIN_COMMIT=2222222222222222222222222222222222222222
UPDATER_PIN_URL=https://example.invalid/updater
UPDATER_PIN_ASSET=dirextalk-updater-linux-amd64
UPDATER_PIN_SHA256=$TEST_TARGET_SHA
UPDATER_PIN_OS=linux
UPDATER_PIN_ARCH=amd64
UPDATER_PIN_UBUNTU_VERSION=24.04
EOF
  printf '{"schema_version":1}\n' >"$TEST_SOURCE/config.json"
  printf '[Unit]\nDescription=fixture\n' >"$TEST_SOURCE/dirextalk-updater.service"
  chmod 0755 "$TEST_SOURCE/"*.sh

cat >"$TEST_BIN/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
format=${2:-}
path=${!#}
mode=$(/usr/bin/stat -c '%a' "$path")
case "$format" in
  %u:%g:%a) printf '0:0:%s\n' "$mode" ;;
  %u:%a) printf '0:%s\n' "$mode" ;;
  *) exec /usr/bin/stat -c "$format" -- "$path" ;;
esac
EOF
  cat >"$TEST_BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$TEST_BIN/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
  cat >"$TEST_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command=${1:-}
printf 'systemctl:%s\n' "$*" >>"$TEST_CALLS"
start_socket() {
  rm -f "$TEST_ROOT/run/dirextalk-updater/http.sock"
  python3 - "$TEST_ROOT/run/dirextalk-updater/http.sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
time.sleep(300)
PY
  printf '%s\n' "$!" >"$TEST_SOCKET_PID"
  for _ in 1 2 3 4 5; do [ -S "$TEST_ROOT/run/dirextalk-updater/http.sock" ] && return 0; sleep 0.1; done
  return 1
}
stop_socket() {
  if [ "$(cat "$TEST_SCENARIO")" = stop-failure-once ]; then
    printf 'idle\n' >"$TEST_SCENARIO"
    exit 17
  fi
  if [ -f "$TEST_SOCKET_PID" ]; then kill "$(cat "$TEST_SOCKET_PID")" >/dev/null 2>&1 || true; rm -f "$TEST_SOCKET_PID"; fi
  rm -f "$TEST_ROOT/run/dirextalk-updater/http.sock"
}
case "$command" in
  cat) [ -f "$TEST_ROOT/etc/systemd/system/dirextalk-updater.service" ] ;;
  is-active) [ "$(cat "$TEST_SERVICE_STATE")" = active ] ;;
  stop) stop_socket; printf 'inactive\n' >"$TEST_SERVICE_STATE" ;;
  start)
    [ "$(cat "$TEST_SCENARIO")" != startup-failure ] || exit 17
    start_socket; printf 'active\n' >"$TEST_SERVICE_STATE"
    ;;
  enable|daemon-reload) ;;
  *) exit 91 ;;
esac
EOF
  cat >"$TEST_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
data= output= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data) data=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    http://*) url=$1; shift ;;
    --unix-socket|--header|--write-out|--config) shift 2 ;;
    --silent|--show-error) shift ;;
    *) shift ;;
  esac
done
[ "$(cat "$TEST_SCENARIO")" != status-infra ] || exit 7
runtime="$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
scenario=$(cat "$TEST_SCENARIO")
mutate_transition_identity() {
  [ ! -e "$TEST_ROOT/identity-mutated" ] || return 0
  directory=$(dirname "$output")
  basename=$(basename "$output")
  mv "$directory" "$directory.old"
  mkdir -m 0700 "$directory"
  cp "$directory.old/$basename" "$output"
  : >"$TEST_ROOT/identity-mutated"
}
case "$url" in
  */control/status)
    desired=$(sed -n 's/.*"desired_state":"\([^"]*\)".*/\1/p' "$runtime")
    if { [ "$scenario" = active-job ] || [ "$scenario" = identity-active ]; } && [ "$desired" = running ]; then
      printf '%s\n' '{"available":true,"updater_ready":false,"desired_state":"upgrading","active_job":{"job_id":"job-1","component":"server","status":"pulling"}}' >"$output"
    elif [ "$scenario" = post-running-failure ] && [ -e "$TEST_ROOT/handoff-running" ] && [ "$desired" = running ]; then
      exit 7
    elif [ "$scenario" = identity-infra ]; then
      printf '{}\n' >"$output"
      mutate_transition_identity
      exit 7
    elif [ "$desired" = running ]; then
      printf '%s\n' '{"available":true,"updater_ready":true,"desired_state":"running"}' >"$output"
    else
      printf '%s\n' '{"available":true,"updater_ready":false,"desired_state":"maintenance"}' >"$output"
    fi
    case "$scenario" in identity-success|identity-active) mutate_transition_identity ;; esac
    printf '200'
    ;;
  */control/desired-state)
    if [ "$scenario" = active-job ]; then
      printf '%s\n' '{"error":"operation_in_progress"}' >"$output"
      printf '409'
      exit 0
    fi
    desired=$(sed -n 's/.*"desired_state":"\([^"]*\)".*/\1/p' <<<"$data")
    if [ "$scenario" = post-running-failure ] && [ "$desired" = running ]; then
      : >"$TEST_ROOT/handoff-running"
    fi
    schema=$(sed -n 's/.*"schema_version":\([0-9]*\).*/\1/p' "$runtime")
    printf '{"schema_version":%s,"desired_state":"%s","watchdog":{"status":"unknown"},"jobs":{},"idempotency":{}}\n' "$schema" "$desired" >"$runtime"
    chmod 0600 "$runtime"
    printf '{"desired_state":"%s"}\n' "$desired" >"$output"
    printf '200'
    ;;
  *) exit 92 ;;
esac
EOF
  chmod 0755 "$TEST_BIN/"*
  PATH="$TEST_BIN:$PATH" "$TEST_BIN/systemctl" start >/dev/null
}

run_reconcile() {
  PATH="$TEST_BIN:$PATH" DIREXTALK_BOOTSTRAP_ROOT="$TEST_ROOT" \
    DIREXTALK_UPDATER_READY_ATTEMPTS=2 \
    bash "$ROOT/scripts/updater/reconcile-host.sh" "$TEST_SOURCE" "$TEST_BASE" 203.0.113.44
}

make_fixture success
run_reconcile >/dev/null
grep -Fqx 'bootstrap' "$TEST_CALLS"
grep -Fq 'systemctl:stop dirextalk-updater.service' "$TEST_CALLS"
grep -Fq 'systemctl:start dirextalk-updater.service' "$TEST_CALLS"
python3 - "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json" <<'PY'
import json, pathlib, sys
x=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert x["schema_version"] == 8 and x["desired_state"] == "running"
PY
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]
[ "$(sha256sum "$TEST_ROOT/usr/local/bin/dirextalk-updater" | awk '{print $1}')" = "$TEST_TARGET_SHA" ]

make_fixture active
printf 'active-job\n' >"$TEST_SCENARIO"
if run_reconcile >/dev/null 2>&1; then echo 'active updater job was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 3 ]
grep -Fq '"schema_version":7' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]
! grep -Fqx 'bootstrap' "$TEST_CALLS"

make_fixture infra
printf 'status-infra\n' >"$TEST_SCENARIO"
if run_reconcile >/dev/null 2>&1; then echo 'updater status infrastructure failure was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 1 ]
grep -Fq '"schema_version":7' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]

make_fixture retry
printf 'startup-failure\n' >"$TEST_SCENARIO"
if run_reconcile >/dev/null 2>&1; then echo 'new updater startup failure was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 1 ]
[ -f "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]
grep -Fq '"schema_version":8' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
printf 'idle\n' >"$TEST_SCENARIO"
run_reconcile >/dev/null
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]
grep -Fq '"desired_state":"running"' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"

make_fixture maintenance_retry
printf 'stop-failure-once\n' >"$TEST_SCENARIO"
if run_reconcile >/dev/null 2>&1; then echo 'old updater stop failure was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 1 ]
grep -Fq '"schema_version":7' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
grep -Fq '"desired_state":"maintenance"' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]
run_reconcile >/dev/null
grep -Fq '"schema_version":8' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
grep -Fq '"desired_state":"running"' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]

make_fixture same_sha_schema7
cp "$TEST_TARGET" "$TEST_ROOT/usr/local/bin/dirextalk-updater"
run_reconcile >/dev/null
grep -Fqx 'fresh-reset' "$TEST_CALLS"
grep -Fq '"schema_version":8' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"

make_fixture post_running_retry
printf 'post-running-failure\n' >"$TEST_SCENARIO"
if run_reconcile >/dev/null 2>&1; then echo 'post-running status failure was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 1 ]
[ -f "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]
grep -Fq '"desired_state":"running"' "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json"
bootstrap_count=$(grep -Fxc 'bootstrap' "$TEST_CALLS")
stop_count=$(grep -Fc 'systemctl:stop dirextalk-updater.service' "$TEST_CALLS")
printf 'active-job\n' >"$TEST_SCENARIO"
if run_reconcile >/dev/null 2>&1; then echo 'active post-running updater job was accepted' >&2; exit 1; else status=$?; fi
[ "$status" -eq 3 ]
[ "$(grep -Fxc 'bootstrap' "$TEST_CALLS")" -eq "$bootstrap_count" ]
[ "$(grep -Fc 'systemctl:stop dirextalk-updater.service' "$TEST_CALLS")" -eq "$stop_count" ]
printf 'idle\n' >"$TEST_SCENARIO"
run_reconcile >/dev/null
[ "$(grep -Fxc 'bootstrap' "$TEST_CALLS")" -eq "$bootstrap_count" ]
[ "$(grep -Fc 'systemctl:stop dirextalk-updater.service' "$TEST_CALLS")" -eq "$stop_count" ]
[ ! -e "$TEST_ROOT/var/lib/dirextalk-updater/runtime.json.quarantine-$TEST_TARGET_SHA" ]

for identity_scenario in identity-success identity-active identity-infra; do
  make_fixture "$identity_scenario"
  printf '%s\n' "$identity_scenario" >"$TEST_SCENARIO"
  if run_reconcile >"$tmp/$identity_scenario.out" 2>"$tmp/$identity_scenario.err"; then
    echo "cleanup identity mutation was accepted for $identity_scenario" >&2
    exit 1
  else
    status=$?
  fi
  [ "$status" -eq 1 ]
  grep -Fq 'transition workspace identity changed; refusing cleanup' "$tmp/$identity_scenario.err"
done

echo 'updater existing state transition ok'
