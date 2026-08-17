#!/usr/bin/env bash
# Restore reboot-volatile runner cgroup delegation and restart the receipt-bound runtime.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck disable=SC1091
source "$script_dir/production-ops-common.sh"

production_bind_completed_runtime
production_verify_message_server
recovery_message_id=$production_message_id
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

recovery_verify_message_unchanged() {
  recovery_verify_receipt_unchanged
  production_verify_message_server
  [ "$production_message_id" = "$recovery_message_id" ] \
    || production_die 'message-server receipt identity changed during recovery'
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
      agent-secret-init|agent-migrate|agent|extension-runner|core-runner)
        [ -z "${recovery_container_ids[$service]:-}" ] \
          || production_die "cleanup receipt contains duplicate $service containers"
        recovery_container_ids[$service]=$id
        ;;
    esac
  done
  for service in agent-secret-init agent-migrate agent extension-runner core-runner; do
    [ -n "${recovery_container_ids[$service]:-}" ] \
      || production_die "cleanup receipt lacks the $service container"
  done
}

recovery_inspect_agent_job() {
  local service=$1 id=${recovery_container_ids[$1]} inspection actual_id actual_project actual_service
  if inspection=$(docker inspect --format '{{.Id}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.StartedAt}}|{{.State.FinishedAt}}' "$id" 2>/dev/null); then
    :
  else
    production_die "recorded $service container inspection failed"
  fi
  IFS='|' read -r actual_id actual_project actual_service recovery_job_state recovery_job_exit_code recovery_job_started_at recovery_job_finished_at <<<"$inspection"
  [ "$actual_id" = "$id" ] || production_die "$service container ID changed"
  [ "$actual_project" = "$production_stack" ] || production_die "$service container project changed"
  [ "$actual_service" = "$service" ] || production_die "$service container service changed"
  printf '%s\n' "$recovery_job_exit_code" | grep -Eq '^-?[0-9]+$' || production_die "$service exit code is invalid"
  [ -n "$recovery_job_started_at" ] && [ -n "$recovery_job_finished_at" ] \
    || production_die "$service execution timestamps are invalid"
}

recovery_run_agent_job() {
  local service=$1 id=${recovery_container_ids[$1]} status prior_started_at prior_finished_at
  recovery_verify_message_unchanged
  recovery_inspect_agent_job "$service"
  if [ "$recovery_job_state" = exited ] && [ "$recovery_job_exit_code" -eq 0 ]; then
    return 0
  fi
  case "$recovery_job_state" in
    created|exited)
      prior_started_at=$recovery_job_started_at
      prior_finished_at=$recovery_job_finished_at
      recovery_verify_message_unchanged
      if docker start -a "$id" >/dev/null; then
        :
      else
        status=$?
        recovery_verify_message_unchanged
        recovery_inspect_agent_job "$service"
        if [ "$recovery_job_state" = exited ] && [ "$recovery_job_exit_code" -ne 0 ] \
            && { [ "$recovery_job_started_at" != "$prior_started_at" ] \
              || [ "$recovery_job_finished_at" != "$prior_finished_at" ]; }; then
          production_negative "$service needs attention after exit $recovery_job_exit_code"
        fi
        production_die "$service exact-container restart failed (status $status)"
      fi
      ;;
    *) production_die "$service has an unsafe resume state: $recovery_job_state" ;;
  esac
  recovery_verify_message_unchanged
  recovery_inspect_agent_job "$service"
  [ "$recovery_job_state" = exited ] && [ "$recovery_job_exit_code" -eq 0 ] \
    || production_negative "$service did not complete successfully during protected resume"
}

recovery_settle_agent_containers() {
  local attempts_remaining=30 service id inspection actual_id actual_project actual_service state restarting
  while :; do
    recovery_verify_message_unchanged
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

recovery_run_agent_job agent-secret-init
recovery_run_agent_job agent-migrate
recovery_settle_agent_containers
production_bind_completed_runtime
recovery_verify_message_unchanged
if "$production_split/scripts/restart-agent-local.sh" "$production_run"; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'existing runtime restart reported an expected negative state' ;;
    *) production_die 'existing runtime restart failed' ;;
  esac
fi
recovery_verify_message_unchanged
printf 'production split recovery passed: stack=%s\n' "$production_stack"
