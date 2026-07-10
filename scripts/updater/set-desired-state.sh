#!/usr/bin/env bash
set -euo pipefail

desired=${1:-}
case "$desired" in
  running|maintenance|deprovisioned) ;;
  *) echo "usage: set-desired-state.sh <running|maintenance|deprovisioned>" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "updater desired-state helper requires root" >&2; exit 1; }

# A host without the unit is a legacy installation and has no watchdog to
# suppress. Once the unit exists, failure to start it or reach its socket must
# fail closed before an intentional topology change begins.
if ! systemctl cat dirextalk-updater.service >/dev/null 2>&1; then
  exit 0
fi
systemctl start dirextalk-updater.service
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet dirextalk-updater.service && test -S /run/dirextalk-updater/http.sock; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "installed updater did not become ready" >&2; exit 1; }

token=$(cat /etc/dirextalk-updater/control-token)
printf 'header = "X-Dirextalk-Control-Token: %s"\n' "$token" \
  | curl --fail --silent --show-error --config - \
      --unix-socket /run/dirextalk-updater/http.sock \
      --header 'Content-Type: application/json' \
      --data "{\"desired_state\":\"$desired\"}" \
      http://localhost/_dirextalk/updater/v1/control/desired-state >/dev/null
unset token
