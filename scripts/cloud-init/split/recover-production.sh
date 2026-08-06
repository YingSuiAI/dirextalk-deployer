#!/usr/bin/env bash
# Restore reboot-volatile runner cgroup delegation and restart the receipt-bound runtime.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck disable=SC1091
source "$script_dir/production-ops-common.sh"

production_bind_completed_runtime
[ -x "$production_split/scripts/prepare-runner-cgroups.sh" ] \
  || production_die 'canonical runner cgroup preparation helper is unavailable'
recovery_receipt_identity=$(stat -c '%d:%i:%u' "$production_receipt") \
  || production_die 'cannot record cleanup receipt identity'
recovery_receipt_sha256=$(sha256sum "$production_receipt" | awk '{print $1}') \
  || production_die 'cannot record cleanup receipt digest'

recovery_verify_receipt_unchanged() {
  production_require_control_file "$production_receipt" 400
  [ "$(stat -c '%d:%i:%u' "$production_receipt")" = "$recovery_receipt_identity" ] \
    || production_die 'cleanup receipt identity changed during recovery'
  [ "$(sha256sum "$production_receipt" | awk '{print $1}')" = "$recovery_receipt_sha256" ] \
    || production_die 'cleanup receipt contents changed during recovery'
}

recovery_load_agent_containers() {
  local container_count index id service project
  container_count=$(production_read_pair "$production_receipt" container.count)
  printf '%s\n' "$container_count" | grep -Eq '^[1-9][0-9]{0,3}$' \
    || production_die 'cleanup receipt container count is invalid'
  declare -gA recovery_container_ids=()
  for ((index = 0; index < container_count; index++)); do
    id=$(production_read_pair "$production_receipt" "container.$index.id")
    service=$(production_read_pair "$production_receipt" "container.$index.service")
    project=$(production_read_pair "$production_receipt" "container.$index.project")
    printf '%s\n' "$id" | grep -Eq '^[0-9a-f]{64}$' \
      || production_die 'cleanup receipt container ID is invalid'
    printf '%s\n' "$service" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
      || production_die 'cleanup receipt container service is invalid'
    [ "$project" = "$production_stack" ] \
      || production_die 'cleanup receipt container project differs from stack'
    case "$service" in
      agent|extension-runner|core-runner)
        [ -z "${recovery_container_ids[$service]:-}" ] \
          || production_die "cleanup receipt contains duplicate $service containers"
        recovery_container_ids[$service]=$id
        ;;
    esac
  done
  for service in agent extension-runner core-runner; do
    [ -n "${recovery_container_ids[$service]:-}" ] \
      || production_die "cleanup receipt lacks the $service container"
  done
}

recovery_settle_agent_containers() {
  local attempts_remaining=30 service id inspection actual_id actual_project actual_service state restarting
  while :; do
    recovery_verify_receipt_unchanged
    restarting=false
    for service in agent extension-runner core-runner; do
      id=${recovery_container_ids[$service]}
      if inspection=$(docker inspect --format '{{.Id}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}' "$id" 2>/dev/null); then
        :
      else
        production_die "recorded $service container inspection failed during recovery settle"
      fi
      IFS='|' read -r actual_id actual_project actual_service state <<<"$inspection"
      [ "$actual_id" = "$id" ] || production_die "$service container ID changed during recovery settle"
      [ "$actual_project" = "$production_stack" ] || production_die "$service container project changed during recovery settle"
      [ "$actual_service" = "$service" ] || production_die "$service container service changed during recovery settle"
      case "$state" in
        created|exited|running) ;;
        restarting) restarting=true ;;
        *) production_die "$service container entered an unknown recovery-settle state: ${state:-empty}" ;;
      esac
    done
    [ "$restarting" = true ] || return 0
    [ "$attempts_remaining" -gt 0 ] \
      || production_die 'Agent runtime containers did not settle within 30 seconds'
    attempts_remaining=$((attempts_remaining - 1))
    sleep 1 || production_die 'recovery settle wait failed'
  done
}

recovery_load_agent_containers

preparation_tmp=$(mktemp "$production_base/.runner-preparation.XXXXXX") \
  || production_die 'cannot create runner preparation receipt'
cleanup_preparation() { rm -f "$preparation_tmp"; }
trap cleanup_preparation EXIT
if "$production_split/scripts/prepare-runner-cgroups.sh" "$production_stack" >"$preparation_tmp"; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'runner cgroup preparation reported an expected negative state' ;;
    *) production_die 'runner cgroup preparation failed' ;;
  esac
fi
[ -s "$preparation_tmp" ] || production_die 'runner cgroup preparation produced an empty receipt'
chmod 0400 "$preparation_tmp" || production_die 'cannot protect runner preparation receipt'
mv -f "$preparation_tmp" "$production_base/runner-preparation.env" \
  || production_die 'cannot commit runner preparation receipt'
trap - EXIT

recovery_settle_agent_containers
production_bind_completed_runtime
recovery_verify_receipt_unchanged
if "$production_split/scripts/restart-agent-local.sh" "$production_run"; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'existing runtime restart reported an expected negative state' ;;
    *) production_die 'existing runtime restart failed' ;;
  esac
fi
printf 'production split recovery passed: stack=%s\n' "$production_stack"
