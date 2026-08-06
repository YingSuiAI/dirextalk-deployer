#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
recovery="$ROOT/scripts/cloud-init/split/recover-production.sh"
service="$ROOT/scripts/cloud-init/split/dirextalk-split-recovery.service"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

grep -Fqx 'Requires=docker.service' "$service"
grep -Fqx 'After=docker.service' "$service"
grep -Fqx 'ConditionPathExists=/var/dirextalk-message-server/.split-deploy-done' "$service"
grep -Fqx 'User=root' "$service"
grep -Fqx 'ExecStart=/var/dirextalk-message-server/production-ops/recover-production.sh' "$service"
if grep -Eq 'Environment=|EnvironmentFile=|/bin/(ba)?sh -c' "$service"; then
  echo 'split recovery service must use only its fixed production entrypoint' >&2
  exit 1
fi

actual="$tmp/actual-consumer"
mkdir -p "$actual"
cp "$recovery" "$ROOT/scripts/cloud-init/split/production-ops-common.sh" "$actual/"
if DIREXTALK_PRODUCTION_BASE="$tmp/missing-runtime" bash "$actual/recover-production.sh" \
    >"$tmp/actual-negative.out" 2>&1; then
  echo 'actual recovery consumer accepted a missing completed runtime' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fq 'completed split runtime is unavailable' "$tmp/actual-negative.out"

fixture="$tmp/fixture"
mkdir -p "$fixture/ops" "$fixture/split/scripts" "$fixture/base" "$fixture/bin"
cp "$recovery" "$fixture/ops/recover-production.sh"
cat >"$fixture/ops/production-ops-common.sh" <<'EOF'
production_die() { printf 'die:%s\n' "$*" >>"$RECOVERY_CALLS"; exit 1; }
production_negative() { printf 'negative:%s\n' "$*" >>"$RECOVERY_CALLS"; exit 3; }
production_read_pair() {
  local file=$1 key=$2
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0,length(wanted)+2); exit}' "$file"
}
production_require_control_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a' "$1")" = "$(id -u):$2" ] \
    || production_die 'invalid fixture control file'
}
production_bind_completed_runtime() {
  printf 'bind\n' >>"$RECOVERY_CALLS"
  case "${RECOVERY_BIND_STATUS:-0}" in
    0) ;;
    3) production_negative 'completed split runtime is unavailable' ;;
    *) production_die 'completed split runtime is invalid' ;;
  esac
  production_base=$RECOVERY_BASE
  production_split=$RECOVERY_SPLIT
  production_run=$RECOVERY_RUN
  production_receipt=$RECOVERY_BASE/.cleanup-receipt
  production_stack=d-abcdefghijklmnopqrstuvwxyz
}
EOF
cat >"$fixture/split/scripts/prepare-runner-cgroups.sh" <<'EOF'
#!/usr/bin/env bash
printf 'prepare:%s\n' "$1" >>"$RECOVERY_CALLS"
printf 'DIREXTALK_RUNNER_PREPARED=true\n'
exit "${RECOVERY_PREPARE_STATUS:-0}"
EOF
cat >"$fixture/split/scripts/restart-agent-local.sh" <<'EOF'
#!/usr/bin/env bash
printf 'restart:%s\n' "$1" >>"$RECOVERY_CALLS"
exit "${RECOVERY_RESTART_STATUS:-0}"
EOF
chmod 0755 "$fixture/ops/"*.sh "$fixture/split/scripts/"*.sh
agent_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
extension_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
core_id=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
cat >"$fixture/base/.cleanup-receipt" <<EOF
# dirextalk-split-cleanup-receipt-v1
container.count=3
container.0.id=$agent_id
container.0.service=agent
container.0.project=d-abcdefghijklmnopqrstuvwxyz
container.1.id=$extension_id
container.1.service=extension-runner
container.1.project=d-abcdefghijklmnopqrstuvwxyz
container.2.id=$core_id
container.2.service=core-runner
container.2.project=d-abcdefghijklmnopqrstuvwxyz
EOF
chmod 0400 "$fixture/base/.cleanup-receipt"
cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-} ${2:-}" = 'inspect --format' ] || exit 90
id=${4:-}
case "$id" in
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) service=agent ;;
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) service=extension-runner ;;
  cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc) service=core-runner ;;
  *) exit 91 ;;
esac
printf 'inspect:%s\n' "$service" >>"$RECOVERY_CALLS"
case "${RECOVERY_DOCKER_MODE:-running}" in
  inspect-fail) exit 17 ;;
  unknown) state=paused ;;
  restarting) state=restarting ;;
  settle)
    count_file="$RECOVERY_DOCKER_COUNT_DIR/$service"
    count=0
    [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$service" = agent ] && [ "$count" -eq 1 ]; then state=restarting; else state=running; fi
    ;;
  running) state=running ;;
  *) exit 92 ;;
esac
printf '%s|d-abcdefghijklmnopqrstuvwxyz|%s|%s\n' "$id" "$service" "$state"
EOF
cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep:%s\n' "$1" >>"$RECOVERY_CALLS"
EOF
chmod 0755 "$fixture/bin/"*

run_recovery() {
  rm -rf "$1.counts"
  mkdir -p "$1.counts"
  RECOVERY_CALLS=$1 RECOVERY_BASE="$fixture/base" RECOVERY_SPLIT="$fixture/split" \
    RECOVERY_RUN="$fixture/run" RECOVERY_BIND_STATUS=${2:-0} \
    RECOVERY_PREPARE_STATUS=${3:-0} RECOVERY_RESTART_STATUS=${4:-0} \
    RECOVERY_DOCKER_MODE=${5:-running} RECOVERY_DOCKER_COUNT_DIR="$1.counts" \
    PATH="$fixture/bin:$PATH" \
    bash "$fixture/ops/recover-production.sh" >/dev/null 2>&1
}

success_calls="$tmp/success.calls"
run_recovery "$success_calls" 0 0 0 settle
[ "$(grep -c '^bind$' "$success_calls")" -eq 2 ]
grep -Fqx 'prepare:d-abcdefghijklmnopqrstuvwxyz' "$success_calls"
grep -Fqx 'sleep:1' "$success_calls"
grep -Fqx "restart:$fixture/run" "$success_calls"
grep -Fqx 'DIREXTALK_RUNNER_PREPARED=true' "$fixture/base/runner-preparation.env"
[ "$(stat -c '%a' "$fixture/base/runner-preparation.env")" = 400 ]

negative_calls="$tmp/negative.calls"
if run_recovery "$negative_calls" 3; then
  echo 'recovery accepted a missing completed runtime' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fqx 'negative:completed split runtime is unavailable' "$negative_calls"
! grep -q '^prepare:' "$negative_calls"

infra_calls="$tmp/infra.calls"
if run_recovery "$infra_calls" 0 17; then
  echo 'recovery accepted runner cgroup infrastructure failure' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:runner cgroup preparation failed' "$infra_calls"
! grep -q '^restart:' "$infra_calls"

restart_negative_calls="$tmp/restart-negative.calls"
if run_recovery "$restart_negative_calls" 0 0 3; then
  echo 'recovery accepted an expected-negative restart result' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fqx 'negative:existing runtime restart reported an expected negative state' "$restart_negative_calls"

timeout_calls="$tmp/timeout.calls"
if run_recovery "$timeout_calls" 0 0 0 restarting; then
  echo 'recovery accepted permanently restarting containers' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ "$(grep -c '^sleep:1$' "$timeout_calls")" -eq 30 ]
grep -Fqx 'die:Agent runtime containers did not settle within 30 seconds' "$timeout_calls"
! grep -q '^restart:' "$timeout_calls"

inspect_failure_calls="$tmp/inspect-failure.calls"
if run_recovery "$inspect_failure_calls" 0 0 0 inspect-fail; then
  echo 'recovery accepted a container inspection failure' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:recorded agent container inspection failed during recovery settle' "$inspect_failure_calls"
! grep -q '^sleep:' "$inspect_failure_calls"
! grep -q '^restart:' "$inspect_failure_calls"

unknown_calls="$tmp/unknown.calls"
if run_recovery "$unknown_calls" 0 0 0 unknown; then
  echo 'recovery accepted an unknown container state' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:agent container entered an unknown recovery-settle state: paused' "$unknown_calls"
! grep -q '^sleep:' "$unknown_calls"
! grep -q '^restart:' "$unknown_calls"

# The update payload must carry the exact helper and unit, install them at
# fixed root-owned paths, and enable the next-boot consumer without starting a
# second runtime path during payload installation.
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/ops.sh"
payload=$(ops_production_helpers_prelude)
recovery_payload=$(base64 <"$recovery" | tr -d '\r\n')
service_payload=$(base64 <"$service" | tr -d '\r\n')
grep -Fq "payload='$recovery_payload'" <<<"$payload"
grep -Fq "'$service_payload' | base64 --decode" <<<"$payload"
grep -Fq 'install -o root -g root -m 0755 "$helper_tmp" "/var/dirextalk-message-server/production-ops/$helper"' <<<"$payload"
grep -Fq 'install -o root -g root -m 0644 "$helper_tmp" /etc/systemd/system/dirextalk-split-recovery.service' <<<"$payload"
grep -Fq 'systemctl enable dirextalk-split-recovery.service' <<<"$payload"
if grep -Fq 'systemctl enable --now dirextalk-split-recovery.service' <<<"$payload"; then
  echo 'update payload must recover through reconcile, not a second concurrent start' >&2
  exit 1
fi

mkdir -p "$tmp/fakebin" "$tmp/installed/etc/systemd/system"
cat >"$tmp/fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command=$1
shift
case "$command" in
  install)
    args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|-g) shift 2 ;;
        /var/dirextalk-message-server/*)
          args+=("$OPS_INSTALL_ROOT${1}")
          shift
          ;;
        /etc/systemd/system/*)
          args+=("$OPS_INSTALL_ROOT${1}")
          shift
          ;;
        *) args+=("$1"); shift ;;
      esac
    done
    exec /usr/bin/install "${args[@]}"
    ;;
  systemctl)
    printf '%s\n' "$*" >>"$OPS_SYSTEMCTL_CALLS"
    ;;
  *) echo "unexpected sudo consumer command: $command" >&2; exit 90 ;;
esac
EOF
chmod 0755 "$tmp/fakebin/sudo"
OPS_INSTALL_ROOT="$tmp/installed" OPS_SYSTEMCTL_CALLS="$tmp/systemctl.calls" \
  PATH="$tmp/fakebin:$PATH" sh -c "$payload"
cmp "$recovery" "$tmp/installed/var/dirextalk-message-server/production-ops/recover-production.sh"
cmp "$service" "$tmp/installed/etc/systemd/system/dirextalk-split-recovery.service"
[ "$(stat -c '%a' "$tmp/installed/var/dirextalk-message-server/production-ops/recover-production.sh")" = 755 ]
[ "$(stat -c '%a' "$tmp/installed/etc/systemd/system/dirextalk-split-recovery.service")" = 644 ]
grep -Fqx 'daemon-reload' "$tmp/systemctl.calls"
grep -Fqx 'enable dirextalk-split-recovery.service' "$tmp/systemctl.calls"

echo 'production split recovery ok'
