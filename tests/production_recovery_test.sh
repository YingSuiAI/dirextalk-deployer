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

# The shared production helper resolves only the immutable Message Server ID
# recorded in the receipt and rejects its disappearance without a name lookup.
exact=$tmp/exact-message
mkdir -p "$exact/bin"
exact_id=$(printf 'd%.0s' {1..64})
cat >"$exact/.env" <<'EOF'
DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.39
EOF
cat >"$exact/.cleanup-receipt" <<EOF
container.count=1
container.0.id=$exact_id
container.0.name=d-abcdefghijklmnopqrstuvwxyz-message-server-1
container.0.service=message-server
container.0.project=d-abcdefghijklmnopqrstuvwxyz
EOF
cat >"$exact/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$EXACT_MESSAGE_LOG"
[ "${1:-} ${2:-}" = 'inspect --format' ] || exit 90
[ "${4:-}" = "$EXACT_MESSAGE_ID" ] || exit 91
[ "${EXACT_MESSAGE_MISSING:-false}" != true ] || exit 1
printf '%s|/%s|d-abcdefghijklmnopqrstuvwxyz|message-server|docker.io/dirextalk/message-server:v1.1.39|running|healthy\n' \
  "$EXACT_MESSAGE_ID" d-abcdefghijklmnopqrstuvwxyz-message-server-1
EOF
chmod 0755 "$exact/bin/docker"
EXACT_MESSAGE_LOG="$exact/docker.log" EXACT_MESSAGE_ID="$exact_id" PATH="$exact/bin:$PATH" \
  bash -c 'source "$1"; production_receipt=$2; production_env=$3; production_stack=d-abcdefghijklmnopqrstuvwxyz; production_verify_message_server; [ "$production_message_id" = "$4" ]' \
  _ "$ROOT/scripts/cloud-init/split/production-ops-common.sh" "$exact/.cleanup-receipt" "$exact/.env" "$exact_id"
if EXACT_MESSAGE_LOG="$exact/missing.log" EXACT_MESSAGE_ID="$exact_id" EXACT_MESSAGE_MISSING=true PATH="$exact/bin:$PATH" \
    bash -c 'source "$1"; production_receipt=$2; production_env=$3; production_stack=d-abcdefghijklmnopqrstuvwxyz; production_verify_message_server' \
      _ "$ROOT/scripts/cloud-init/split/production-ops-common.sh" "$exact/.cleanup-receipt" "$exact/.env" \
      >"$exact/missing.out" 2>&1; then
  echo 'production helper adopted a replacement for a missing exact Message Server' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fq 'exact receipt-bound message-server container is unavailable' "$exact/missing.out"
[ "$(wc -l <"$exact/missing.log")" -eq 1 ]
grep -Fq "$exact_id" "$exact/missing.log"

fixture="$tmp/fixture"
mkdir -p "$fixture/ops" "$fixture/split/scripts" "$fixture/split/systemd" \
  "$fixture/base" "$fixture/bin" "$fixture/units"
sed "s#local runner_unit_dir=/etc/systemd/system#local runner_unit_dir=$fixture/units#" \
  "$recovery" >"$fixture/ops/recover-production.sh"
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
production_verify_message_server() {
  printf 'verify-message\n' >>"$RECOVERY_CALLS"
  [ "${RECOVERY_MESSAGE_STATUS:-0}" -eq 0 ] \
    || production_die 'exact receipt-bound message-server container is unavailable'
  production_message_id=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
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
printf 'prepare:%s\n' d-abcdefghijklmnopqrstuvwxyz >>"$RECOVERY_CALLS"
printf 'DIREXTALK_RUNNER_PREPARED=true\n' >"$RECOVERY_BASE/runner-preparation.env"
chmod 0400 "$RECOVERY_BASE/runner-preparation.env"
printf 'restart:%s\n' "$1" >>"$RECOVERY_CALLS"
exit "${RECOVERY_RESTART_STATUS:-0}"
EOF
printf 'extension unit v2\n' >"$fixture/split/systemd/dirextalk-extension-runner@.service"
printf 'core unit v2\n' >"$fixture/split/systemd/dirextalk-core-runner@.service"
chmod 0755 "$fixture/ops/"*.sh "$fixture/split/scripts/"*.sh
agent_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
extension_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
core_id=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
secret_id=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
migrate_id=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
cat >"$fixture/base/.cleanup-receipt" <<EOF
# dirextalk-split-cleanup-receipt-v1
container.count=5
container.0.id=$secret_id
container.0.service=agent-secret-init
container.0.project=d-abcdefghijklmnopqrstuvwxyz
container.1.id=$migrate_id
container.1.service=agent-migrate
container.1.project=d-abcdefghijklmnopqrstuvwxyz
container.2.id=$agent_id
container.2.service=agent
container.2.project=d-abcdefghijklmnopqrstuvwxyz
container.3.id=$extension_id
container.3.service=extension-runner
container.3.project=d-abcdefghijklmnopqrstuvwxyz
container.4.id=$core_id
container.4.service=core-runner
container.4.project=d-abcdefghijklmnopqrstuvwxyz
EOF
chmod 0400 "$fixture/base/.cleanup-receipt"
cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-} ${2:-}" = 'inspect --format' ]; then
  id=${4:-}
  case "$id" in
    eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee) service=agent-secret-init ;;
    ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) service=agent-migrate ;;
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) service=agent ;;
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) service=extension-runner ;;
    cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc) service=core-runner ;;
    *) exit 91 ;;
  esac
  if [[ "${3:-}" == *ExitCode* ]]; then
    marker="$RECOVERY_DOCKER_COUNT_DIR/job-$service"
    case "${RECOVERY_JOB_MODE:-complete}" in
      complete) job_state=exited; job_exit=0; job_started=complete-start; job_finished=complete-finish ;;
      retry)
        if [ -f "$marker" ]; then
          job_state=exited; job_exit=0; job_started=new-start; job_finished=new-finish
        elif [ "$service" = agent-secret-init ]; then
          job_state=created; job_exit=0; job_started=never-started; job_finished=never-finished
        else
          job_state=exited; job_exit=17; job_started=old-start; job_finished=old-finish
        fi
        ;;
      fail)
        job_state=exited; job_exit=17
        if [ -f "$marker" ]; then job_started=new-start; job_finished=new-finish; else job_started=old-start; job_finished=old-finish; fi
        ;;
      infra)
        job_state=exited; job_exit=17; job_started=old-start; job_finished=old-finish
        ;;
      *) exit 93 ;;
    esac
    printf 'inspect-job:%s:%s:%s\n' "$service" "$job_state" "$job_exit" >>"$RECOVERY_CALLS"
    printf '%s|d-abcdefghijklmnopqrstuvwxyz|%s|%s|%s|%s|%s\n' \
      "$id" "$service" "$job_state" "$job_exit" "$job_started" "$job_finished"
    exit 0
  fi
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
elif [ "${1:-} ${2:-}" = 'start -a' ]; then
  id=${3:-}
  case "$id" in
    eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee) service=agent-secret-init ;;
    ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) service=agent-migrate ;;
    *) exit 94 ;;
  esac
  printf 'start-job:%s\n' "$service" >>"$RECOVERY_CALLS"
  [ "${RECOVERY_JOB_MODE:-complete}" != infra ] || exit 125
  : >"$RECOVERY_DOCKER_COUNT_DIR/job-$service"
  [ "${RECOVERY_JOB_MODE:-complete}" != fail ] || exit 17
else
  exit 90
fi
EOF
  bash -n "$fixture/bin/docker"
cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep:%s\n' "$1" >>"$RECOVERY_CALLS"
EOF
cat >"$fixture/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF
cat >"$fixture/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl:%s\n' "$*" >>"$RECOVERY_CALLS"
exit "${RECOVERY_SYSTEMCTL_STATUS:-0}"
EOF
chmod 0755 "$fixture/bin/"*

run_recovery() {
  rm -rf "$1.counts"
  mkdir -p "$1.counts"
  RECOVERY_CALLS=$1 RECOVERY_BASE="$fixture/base" RECOVERY_SPLIT="$fixture/split" \
    RECOVERY_RUN="$fixture/run" RECOVERY_BIND_STATUS=${2:-0} \
    RECOVERY_PREPARE_STATUS=${3:-0} RECOVERY_RESTART_STATUS=${4:-0} \
    RECOVERY_DOCKER_MODE=${5:-running} RECOVERY_DOCKER_COUNT_DIR="$1.counts" \
    RECOVERY_MESSAGE_STATUS=${6:-0} \
    RECOVERY_JOB_MODE=${7:-complete} \
    PATH="$fixture/bin:$PATH" \
    bash "$fixture/ops/recover-production.sh" >/dev/null 2>&1
}

success_calls="$tmp/success.calls"
run_recovery "$success_calls" 0 0 0 settle
[ "$(grep -c '^bind$' "$success_calls")" -eq 2 ]
grep -Fqx 'prepare:d-abcdefghijklmnopqrstuvwxyz' "$success_calls"
grep -Fqx 'sleep:1' "$success_calls"
grep -Fqx "restart:$fixture/run" "$success_calls"
prepare_line=$(grep -n '^prepare:' "$success_calls" | cut -d: -f1)
agent_restart_line=$(grep -n '^restart:' "$success_calls" | cut -d: -f1)
[ "$prepare_line" -lt "$agent_restart_line" ]
[ "$(grep -c '^verify-message$' "$success_calls")" -ge 6 ]
first_message_line=$(grep -n '^verify-message$' "$success_calls" | head -n 1 | cut -d: -f1)
[ "$first_message_line" -lt "$prepare_line" ]
grep -Fqx 'inspect-job:agent-secret-init:exited:0' "$success_calls"
grep -Fqx 'inspect-job:agent-migrate:exited:0' "$success_calls"
if grep -q '^start-job:' "$success_calls"; then
  echo 'recovery reran an already successful Agent initialization job' >&2
  exit 1
fi
grep -Fqx 'DIREXTALK_RUNNER_PREPARED=true' "$fixture/base/runner-preparation.env"
[ "$(stat -c '%a' "$fixture/base/runner-preparation.env")" = 400 ]

retry_calls="$tmp/job-retry.calls"
run_recovery "$retry_calls" 0 0 0 running 0 retry
[ "$(grep -c '^start-job:agent-secret-init$' "$retry_calls")" -eq 1 ]
[ "$(grep -c '^start-job:agent-migrate$' "$retry_calls")" -eq 1 ]
secret_start_line=$(grep -n '^start-job:agent-secret-init$' "$retry_calls" | cut -d: -f1)
migrate_start_line=$(grep -n '^start-job:agent-migrate$' "$retry_calls" | cut -d: -f1)
retry_restart_line=$(grep -n '^restart:' "$retry_calls" | cut -d: -f1)
[ "$secret_start_line" -lt "$migrate_start_line" ]
[ "$migrate_start_line" -lt "$retry_restart_line" ]

job_failure_calls="$tmp/job-failure.calls"
if run_recovery "$job_failure_calls" 0 0 0 running 0 fail; then
  echo 'recovery accepted a repeatedly failing Agent initialization job' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fqx 'start-job:agent-secret-init' "$job_failure_calls"
grep -Fqx 'negative:agent-secret-init needs attention after exit 17' "$job_failure_calls"
if grep -Eq '^start-job:agent-migrate$|^restart:' "$job_failure_calls"; then
  echo 'failed Agent initialization continued into later runtime mutations' >&2
  exit 1
fi

job_infra_calls="$tmp/job-infra.calls"
if run_recovery "$job_infra_calls" 0 0 0 running 0 infra; then
  echo 'recovery accepted an Agent job infrastructure restart failure' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'start-job:agent-secret-init' "$job_infra_calls"
grep -Fqx 'die:agent-secret-init exact-container restart failed (status 125)' "$job_infra_calls"
if grep -Eq '^start-job:agent-migrate$|^restart:' "$job_infra_calls"; then
  echo 'Agent job infrastructure failure continued into later runtime mutations' >&2
  exit 1
fi

unchanged_calls="$tmp/unchanged.calls"
run_recovery "$unchanged_calls"
grep -Fqx 'prepare:d-abcdefghijklmnopqrstuvwxyz' "$unchanged_calls"
grep -Fqx "restart:$fixture/run" "$unchanged_calls"

negative_calls="$tmp/negative.calls"
if run_recovery "$negative_calls" 3; then
  echo 'recovery accepted a missing completed runtime' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fqx 'negative:completed split runtime is unavailable' "$negative_calls"
if grep -q '^prepare:' "$negative_calls"; then
  echo 'missing completed runtime reached runner preparation' >&2
  exit 1
fi

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
if grep -q '^restart:' "$timeout_calls"; then
  echo 'unsettled Agent containers reached Agent restart' >&2
  exit 1
fi

inspect_failure_calls="$tmp/inspect-failure.calls"
if run_recovery "$inspect_failure_calls" 0 0 0 inspect-fail; then
  echo 'recovery accepted a container inspection failure' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:recorded agent container inspection failed during recovery settle' "$inspect_failure_calls"
if grep -Eq '^sleep:|^restart:' "$inspect_failure_calls"; then
  echo 'container inspection failure continued recovery' >&2
  exit 1
fi

unknown_calls="$tmp/unknown.calls"
if run_recovery "$unknown_calls" 0 0 0 unknown; then
  echo 'recovery accepted an unknown container state' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:agent container entered an unknown recovery-settle state: paused' "$unknown_calls"
if grep -Eq '^sleep:|^restart:' "$unknown_calls"; then
  echo 'unknown Agent container state continued recovery' >&2
  exit 1
fi

message_missing_calls="$tmp/message-missing.calls"
if run_recovery "$message_missing_calls" 0 0 0 running 1; then
  echo 'recovery accepted a missing receipt-bound Message Server' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
grep -Fqx 'die:exact receipt-bound message-server container is unavailable' "$message_missing_calls"
if grep -Eq '^systemctl:|^prepare:|^restart:' "$message_missing_calls"; then
  echo 'missing receipt-bound Message Server allowed recovery mutations' >&2
  exit 1
fi

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
