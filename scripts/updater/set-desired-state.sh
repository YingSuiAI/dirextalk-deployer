#!/usr/bin/env bash
set -euo pipefail

desired=${1:-}
case "$desired" in
  running|maintenance|deprovisioned) ;;
  *) echo "usage: set-desired-state.sh <running|maintenance|deprovisioned>" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "updater desired-state helper requires root" >&2; exit 1; }

host_root=${DIREXTALK_BOOTSTRAP_ROOT:-}
socket_path=$host_root/run/dirextalk-updater/http.sock
token_file=$host_root/etc/dirextalk-updater/control-token
response_file=$(mktemp) || { echo "could not create updater response workspace" >&2; exit 1; }
trap 'rm -f -- "$response_file"' EXIT

# The updater is the only authority that may mutate its private state. A
# missing unit is an infrastructure failure, never a successful no-op.
systemctl cat dirextalk-updater.service >/dev/null 2>&1 || {
  echo "installed updater service is unavailable" >&2
  exit 1
}
systemctl start dirextalk-updater.service || {
  echo "installed updater could not be started" >&2
  exit 1
}
ready=0
attempts=${DIREXTALK_UPDATER_READY_ATTEMPTS:-10}
while [ "$attempts" -gt 0 ]; do
  if systemctl is-active --quiet dirextalk-updater.service && test -S "$socket_path"; then
    ready=1
    break
  fi
  attempts=$((attempts - 1))
  [ "$attempts" -gt 0 ] || break
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "installed updater did not become ready" >&2; exit 1; }

[ -f "$token_file" ] && [ ! -L "$token_file" ] \
  && [ "$(stat -c '%u:%g:%a' -- "$token_file")" = 0:0:600 ] \
  || { echo "updater control token is unavailable" >&2; exit 1; }
token=$(cat -- "$token_file") || { echo "updater control token could not be read" >&2; exit 1; }
[ -n "$token" ] || { echo "updater control token is empty" >&2; exit 1; }
if http_code=$(printf 'header = "X-Dirextalk-Control-Token: %s"\n' "$token" \
  | curl --silent --show-error --config - \
      --unix-socket "$socket_path" \
      --header 'Content-Type: application/json' \
      --data "{\"desired_state\":\"$desired\"}" \
      --output "$response_file" --write-out '%{http_code}' \
      http://localhost/_dirextalk/updater/v1/control/desired-state); then
  :
else
  unset token
  echo "updater desired-state request failed" >&2
  exit 1
fi
unset token

if [ "$http_code" = 409 ] && python3 - "$response_file" <<'PY'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(value, dict) and value.get("error") == "operation_in_progress" else 1)
PY
then
  echo "an updater operation is already in progress" >&2
  exit 3
fi
[ "$http_code" = 200 ] || { echo "updater desired-state request returned HTTP $http_code" >&2; exit 1; }
python3 - "$response_file" "$desired" <<'PY' || {
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(value, dict) and value.get("desired_state") == sys.argv[2] else 1)
PY
  echo "updater desired-state response is invalid" >&2
  exit 1
}
