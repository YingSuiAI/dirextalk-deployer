#!/usr/bin/env bash
# Install the pinned updater on an existing host without carrying private state
# across an incompatible updater binary. The old daemon first proves that no
# release job is active and atomically enters maintenance.
set -euo pipefail

die() { printf 'updater host reconcile: %s\n' "$*" >&2; exit 1; }
negative() { printf 'updater host reconcile: %s\n' "$*" >&2; exit 3; }

source_dir=${1:-}
base=${2:-/var/dirextalk-message-server}
stable_ip=${3:-}
[ -d "$source_dir" ] && [ -n "$stable_ip" ] || {
  echo "usage: reconcile-host.sh <integration-dir> <deployment-dir> <stable-public-ip>" >&2
  exit 1
}
for file in bootstrap-host.sh install.sh reconcile-host.sh set-desired-state.sh \
  release.env config.json dirextalk-updater.service; do
  [ -f "$source_dir/$file" ] && [ ! -L "$source_dir/$file" ] || \
    die "staged updater integration file is unavailable: $file"
done
if bash "$source_dir/bootstrap-host.sh" --preflight "$stable_ip"; then
  :
else
  preflight_status=$?
  case "$preflight_status" in
    3) negative "existing host preflight reported an expected negative state" ;;
    *) die "existing host preflight failed" ;;
  esac
fi

# shellcheck disable=SC1091
source "$source_dir/release.env"
printf '%s\n' "$UPDATER_PIN_SHA256" | grep -Eq '^[0-9a-f]{64}$' \
  || die 'staged updater SHA-256 pin is invalid'

host_root=${DIREXTALK_BOOTSTRAP_ROOT:-}
binary_path=$host_root/usr/local/bin/dirextalk-updater
unit_path=$host_root/etc/systemd/system/dirextalk-updater.service
token_file=$host_root/etc/dirextalk-updater/control-token
state_dir=$host_root/var/lib/dirextalk-updater
runtime_file=$state_dir/runtime.json
socket_path=$host_root/run/dirextalk-updater/http.sock
quarantine=$state_dir/runtime.json.quarantine-$UPDATER_PIN_SHA256
transition_dir=
transition_identity=
quarantine_identity=

path_identity() {
  local path=$1 expected_type=$2
  [ ! -L "$path" ] || return 1
  case "$expected_type" in
    directory) [ -d "$path" ] || return 1 ;;
    file) [ -f "$path" ] || return 1 ;;
    *) return 1 ;;
  esac
  stat -c '%d:%i:%u:%g:%a' -- "$path"
}

cleanup_transition() {
  [ -n "$transition_dir" ] || return 0
  [ -n "$transition_identity" ] \
    && [ "$(path_identity "$transition_dir" directory 2>/dev/null || true)" = "$transition_identity" ] \
    || {
      printf 'updater host reconcile: transition workspace identity changed; refusing cleanup\n' >&2
      return 1
    }
  rm -rf -- "$transition_dir"
  transition_dir=
  transition_identity=
}
transaction_exit() {
  local status=$?
  trap - EXIT
  if cleanup_transition; then
    exit "$status"
  fi
  exit 1
}
trap transaction_exit EXIT
install -d -m 0755 "$host_root/run"
transition_dir=$(mktemp -d "$host_root/run/dirextalk-updater-transition.XXXXXX") \
  || die 'could not create updater transition workspace'
chmod 0700 "$transition_dir"
transition_identity=$(path_identity "$transition_dir" directory) \
  || die 'could not record updater transition workspace identity'

control_request() {
  local body=$1 output=$2 token http_code
  [ -f "$token_file" ] && [ ! -L "$token_file" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$token_file")" = 0:0:600 ] \
    || return 1
  [ -S "$socket_path" ] || return 1
  token=$(cat -- "$token_file") || return 1
  [ -n "$token" ] || return 1
  if http_code=$(printf 'header = "X-Dirextalk-Control-Token: %s"\n' "$token" \
      | curl --silent --show-error --config - \
          --unix-socket "$socket_path" \
          --header 'Content-Type: application/json' \
          --data "$body" --output "$output" --write-out '%{http_code}' \
          http://localhost/_dirextalk/updater/v1/control/status); then
    :
  else
    unset token
    return 1
  fi
  unset token
  printf '%s' "$http_code"
}

desired_request() {
  local desired=$1 output=$2 token http_code
  [ -f "$token_file" ] && [ ! -L "$token_file" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$token_file")" = 0:0:600 ] \
    || return 1
  [ -S "$socket_path" ] || return 1
  token=$(cat -- "$token_file") || return 1
  [ -n "$token" ] || return 1
  if http_code=$(printf 'header = "X-Dirextalk-Control-Token: %s"\n' "$token" \
      | curl --silent --show-error --config - \
          --unix-socket "$socket_path" \
          --header 'Content-Type: application/json' \
          --data "{\"desired_state\":\"$desired\"}" --output "$output" --write-out '%{http_code}' \
          http://localhost/_dirextalk/updater/v1/control/desired-state); then
    :
  else
    unset token
    return 1
  fi
  unset token
  printf '%s' "$http_code"
}

validate_status() {
  local file=$1 desired=$2 ready=$3
  python3 - "$file" "$desired" "$ready" <<'PY'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, dict):
    raise SystemExit(1)
if value.get("active_job") is not None:
    raise SystemExit(3)
if value.get("desired_state") != sys.argv[2]:
    raise SystemExit(1)
expected_ready = sys.argv[3] == "true"
if value.get("updater_ready") is not expected_ready:
    raise SystemExit(1)
if value.get("available") is not True:
    raise SystemExit(1)
PY
}

validate_desired_response() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, dict) or value.get("desired_state") != sys.argv[2]:
    raise SystemExit(1)
PY
}

is_operation_in_progress() {
  python3 - "$1" <<'PY'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(value, dict) and value.get("error") == "operation_in_progress" else 1)
PY
}

validate_runtime_state() {
  local expected_desired=$1
  [ -f "$runtime_file" ] && [ ! -L "$runtime_file" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$runtime_file")" = 0:0:600 ] \
    || return 1
  python3 - "$runtime_file" "$expected_desired" <<'PY'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, dict) or value.get("schema_version") != 9 or value.get("desired_state") != sys.argv[2]:
    raise SystemExit(1)
jobs = value.get("jobs", {})
idempotency = value.get("idempotency", {})
if not isinstance(jobs, dict) or not isinstance(idempotency, dict):
    raise SystemExit(1)
terminal_statuses = {"succeeded", "failed", "rolled_back"}
if any(not isinstance(job, dict) or job.get("status") not in terminal_statuses for job in jobs.values()):
    raise SystemExit(1)
PY
}

runtime_shape() {
  [ -f "$runtime_file" ] && [ ! -L "$runtime_file" ] || return 1
  python3 - "$runtime_file" <<'PY'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
schema = value.get("schema_version") if isinstance(value, dict) else None
desired = value.get("desired_state") if isinstance(value, dict) else None
if not isinstance(schema, int) or desired not in {"running", "maintenance", "deprovisioned", "upgrading"}:
    raise SystemExit(1)
print(f"{schema}\t{desired}")
PY
}

target_identity() {
  local identity parsed version commit sha256
  identity=$($binary_path version) || return 1
  parsed=$(python3 - "$identity" <<'PY'
import json, sys
try:
    value = json.loads(sys.argv[1])
except json.JSONDecodeError:
    raise SystemExit(1)
version = value.get("version")
commit = value.get("commit")
if not isinstance(version, str) or not isinstance(commit, str):
    raise SystemExit(1)
print(f"{version}\t{commit}")
PY
) || return 1
  version=${parsed%%$'\t'*}
  commit=${parsed#*$'\t'}
  sha256=$(sha256sum "$binary_path" | awk '{print $1}') || return 1
  [ "$version" = "$UPDATER_PIN_VERSION" ] \
    && [ "$commit" = "$UPDATER_PIN_COMMIT" ] \
    && [ "$sha256" = "$UPDATER_PIN_SHA256" ] \
    || return 1
  printf '%s\t%s\t%s\n' "$version" "$commit" "$sha256"
}

remove_quarantine() {
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  [ -n "$quarantine_identity" ] \
    && [ "$(path_identity "$quarantine" file 2>/dev/null || true)" = "$quarantine_identity" ] \
    || die 'updater runtime quarantine identity changed; refusing cleanup'
  rm -f -- "$quarantine" || die 'could not remove obsolete updater state quarantine'
  sync -f "$state_dir"
  quarantine_identity=
}

wait_for_status() {
  local desired=$1 ready=$2 attempts=${DIREXTALK_UPDATER_READY_ATTEMPTS:-30}
  local body="$transition_dir/status.json" code status
  while [ "$attempts" -gt 0 ]; do
    if code=$(control_request '{}' "$body") && [ "$code" = 200 ]; then
      if validate_status "$body" "$desired" "$ready"; then
        return 0
      else
        status=$?
        [ "$status" -ne 3 ] || return 3
      fi
    fi
    attempts=$((attempts - 1))
    [ "$attempts" -gt 0 ] && sleep 1
  done
  return 1
}

quiesce_current_updater() {
  local body="$transition_dir/status-before.json" desired_body="$transition_dir/maintenance.json"
  local code status needs_maintenance=0 runtime_desired
  systemctl cat dirextalk-updater.service >/dev/null 2>&1 \
    || die 'installed updater service is unavailable'
  systemctl is-active --quiet dirextalk-updater.service \
    || die 'installed updater is not active before state transition'
  if code=$(control_request '{}' "$body"); then :; else die 'installed updater status request failed'; fi
  if [ "$code" = 503 ]; then
    runtime_desired=$(runtime_shape) \
      || die 'installed updater runtime state is invalid while status is unavailable'
    runtime_desired=${runtime_desired#*$'\t'}
    case "$runtime_desired" in
      running|maintenance) ;;
      *) die 'installed updater runtime is not idle while status is unavailable' ;;
    esac
    validate_runtime_state "$runtime_desired" \
      || die 'installed updater runtime is not idle while status is unavailable'
    systemctl stop dirextalk-updater.service \
      || die 'could not stop unavailable updater before replacement'
    if systemctl is-active --quiet dirextalk-updater.service; then
      die 'unavailable updater remained active after stop'
    fi
    return 0
  fi
  [ "$code" = 200 ] || die "installed updater status returned HTTP $code"
  if validate_status "$body" running true; then
    needs_maintenance=1
  else
    status=$?
    [ "$status" -ne 3 ] || negative 'an updater release job is active'
    if validate_status "$body" maintenance false; then
      needs_maintenance=0
    else
      status=$?
      [ "$status" -ne 3 ] || negative 'an updater release job is active'
      die 'installed updater is not idle in running or maintenance state'
    fi
  fi
  if [ "$needs_maintenance" -eq 1 ]; then
    if code=$(desired_request maintenance "$desired_body"); then :; else die 'updater maintenance request failed'; fi
    if [ "$code" = 409 ] && is_operation_in_progress "$desired_body"; then
      negative 'an updater release job started before maintenance'
    fi
    [ "$code" = 200 ] || die "updater maintenance request returned HTTP $code"
    validate_desired_response "$desired_body" maintenance \
      || die 'updater maintenance response is invalid'
  fi
  if wait_for_status maintenance false; then
    :
  else
    status=$?
    [ "$status" -ne 3 ] || negative 'an updater release job remained active in maintenance'
    die 'updater did not settle in maintenance'
  fi
  systemctl stop dirextalk-updater.service || die 'could not stop updater after maintenance'
  if systemctl is-active --quiet dirextalk-updater.service; then
    die 'updater remained active after stop'
  fi
}

[ -f "$unit_path" ] && [ ! -L "$unit_path" ] \
  || die 'installed updater unit is unavailable'
install -d -m 0700 "$state_dir"
current_sha=
if [ -f "$binary_path" ] && [ ! -L "$binary_path" ]; then
  current_sha=$(sha256sum "$binary_path" | awk '{print $1}')
fi

if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
  [ -f "$quarantine" ] && [ ! -L "$quarantine" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$quarantine")" = 0:0:600 ] \
    || die 'updater runtime quarantine is invalid'
  quarantine_identity=$(path_identity "$quarantine" file) \
    || die 'could not record updater runtime quarantine identity'
  shape=$(runtime_shape) || die 'quarantined updater transition runtime is invalid'
  schema=${shape%%$'\t'*}
  desired=${shape#*$'\t'}
  [ "$schema" = 9 ] || die 'quarantined updater transition did not create fresh schema 9 state'
  systemctl start dirextalk-updater.service \
    || die 'could not start updater to inspect quarantined transition state'
  case "$desired" in
    running)
      if wait_for_status running true; then
        :
      else
        status=$?
        [ "$status" -ne 3 ] || negative 'a release job is active after updater handoff'
        die 'running updater transition status is unavailable'
      fi
      parsed_identity=$(target_identity) \
        || die 'running updater transition identity does not match the deployer pin'
      validate_runtime_state running \
        || die 'running updater transition did not retain fresh idle schema 9 state'
      remove_quarantine
      printf '%s\n' "$parsed_identity"
      exit 0
      ;;
    maintenance)
      if wait_for_status maintenance false; then
        :
      else
        status=$?
        [ "$status" -ne 3 ] || negative 'a release job is active in updater maintenance'
        die 'maintenance updater transition status is unavailable'
      fi
      systemctl stop dirextalk-updater.service \
        || die 'could not stop updater maintenance transition'
      if systemctl is-active --quiet dirextalk-updater.service; then
        die 'updater remained active after stopping maintenance transition'
      fi
      ;;
    *) die 'quarantined updater transition has an invalid desired state' ;;
  esac
else
  quiesce_current_updater
  shape=$(runtime_shape) || die 'installed updater runtime state is invalid after maintenance'
  schema=${shape%%$'\t'*}
  if [ "$current_sha" != "$UPDATER_PIN_SHA256" ] || [ "$schema" != 9 ]; then
    [ -f "$runtime_file" ] && [ ! -L "$runtime_file" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$runtime_file")" = 0:0:600 ] \
      || die 'old updater runtime state is unavailable after maintenance'
    mv -- "$runtime_file" "$quarantine" \
      || die 'could not quarantine old updater runtime state'
    sync -f "$state_dir"
    quarantine_identity=$(path_identity "$quarantine" file) \
      || die 'could not record updater runtime quarantine identity'
  fi
fi

if [ -e "$quarantine" ]; then
  if [ ! -e "$runtime_file" ]; then
    state_tmp=$(mktemp "$state_dir/.runtime.json.schema9.XXXXXX") \
      || die 'could not create fresh schema 9 updater state'
    printf '%s\n' '{"schema_version":9,"desired_state":"maintenance","watchdog":{"status":"unknown"},"jobs":{},"idempotency":{}}' >"$state_tmp"
    chmod 0600 "$state_tmp"
    chown 0:0 "$state_tmp"
    sync -f "$state_tmp"
    mv -f -- "$state_tmp" "$runtime_file"
    sync -f "$state_dir"
  fi
fi
validate_runtime_state maintenance \
  || die 'current updater runtime is not idle schema 9 maintenance state'

integration_dir="$base/updater"
install -d -m 0755 "$integration_dir"
rm -f "$integration_dir/dirextalk-updater-discovery.service" \
  "$integration_dir/dirextalk-updater-discovery.timer"
for file in bootstrap-host.sh install.sh reconcile-host.sh set-desired-state.sh; do
  install -m 0755 "$source_dir/$file" "$integration_dir/$file"
done
for file in release.env config.json dirextalk-updater.service; do
  install -m 0644 "$source_dir/$file" "$integration_dir/$file"
done

# bootstrap installs the already-pinned binary and reconciles the receipt-bound
# application while the updater remains stopped. This transition owns the only
# service restart and validates the real control API before returning.
DIREXTALK_UPDATER_SKIP_SYSTEMD=1 bash "$integration_dir/bootstrap-host.sh" "$stable_ip"
systemctl daemon-reload || die 'could not reload updater unit'
systemctl enable dirextalk-updater.service >/dev/null \
  || die 'could not enable updater service'
systemctl start dirextalk-updater.service || die 'could not start updater service'
if wait_for_status maintenance false; then
  :
else
  status=$?
  [ "$status" -ne 3 ] || negative 'new updater unexpectedly reported an active job'
  die 'new updater did not expose an idle maintenance status'
fi

parsed_identity=$(target_identity) \
  || die 'active updater identity does not match the deployer pin'
validate_runtime_state maintenance \
  || die 'new updater did not retain idle schema 9 maintenance state'

running_body="$transition_dir/running.json"
if code=$(desired_request running "$running_body"); then :; else die 'updater running request failed'; fi
[ "$code" = 200 ] || die "updater running request returned HTTP $code"
validate_desired_response "$running_body" running \
  || die 'updater running response is invalid'
if wait_for_status running true; then
  :
else
  status=$?
  [ "$status" -ne 3 ] || negative 'new updater reported an active job before release handoff'
  die 'new updater did not become ready'
fi
validate_runtime_state running \
  || die 'new updater did not persist ready schema 9 state'

remove_quarantine
printf '%s\n' "$parsed_identity"
