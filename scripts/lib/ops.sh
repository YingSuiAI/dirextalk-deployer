#!/usr/bin/env bash
# lib/ops.sh - existing-node update/reset helpers.

OPS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$OPS_LIB_DIR/paths.sh"
# shellcheck disable=SC1090
source "$OPS_LIB_DIR/json.sh"

ops_desired_state_helper_payload() {
  base64 < "$OPS_LIB_DIR/../updater/set-desired-state.sh" | tr -d '\r\n'
}

ops_desired_state_helper_prelude() {
  local payload template
  payload=$(ops_desired_state_helper_payload)
  template=$(cat <<'EOF'
set -eu
desired_helper_tmp=$(mktemp /tmp/dirextalk-updater-desired-state.XXXXXX)
cleanup_desired_helper() { rm -f "$desired_helper_tmp"; }
trap cleanup_desired_helper EXIT
printf '%s' '__DIREXTALK_DESIRED_HELPER__' | base64 --decode > "$desired_helper_tmp"
sudo install -d -m 0755 /var/dirextalk-message-server/updater
sudo install -m 0755 "$desired_helper_tmp" /var/dirextalk-message-server/updater/set-desired-state.sh
rm -f "$desired_helper_tmp"
trap - EXIT
EOF
)
  printf '%s\n' "${template/__DIREXTALK_DESIRED_HELPER__/$payload}"
}

ops_production_helpers_prelude() {
  local bootstrap_payload common_payload recover_payload reconcile_payload reset_payload service_payload template
  bootstrap_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/bootstrap-production.sh" | tr -d '\r\n')
  common_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/production-ops-common.sh" | tr -d '\r\n')
  recover_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/recover-production.sh" | tr -d '\r\n')
  reconcile_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/reconcile-production.sh" | tr -d '\r\n')
  reset_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/reset-production.sh" | tr -d '\r\n')
  service_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/dirextalk-split-recovery.service" | tr -d '\r\n')
  template=$(cat <<'EOF'
set -eu
sudo install -d -o root -g root -m 0700 /var/dirextalk-message-server/production-ops
helper_tmp=''
cleanup_production_helper() { [ -z "$helper_tmp" ] || rm -f "$helper_tmp"; }
trap cleanup_production_helper EXIT
for helper in bootstrap-production.sh production-ops-common.sh recover-production.sh reconcile-production.sh reset-production.sh; do
  helper_tmp=$(mktemp /tmp/dirextalk-production-helper.XXXXXX)
  case "$helper" in
    bootstrap-production.sh) payload='__DIREXTALK_PRODUCTION_BOOTSTRAP__' ;;
    production-ops-common.sh) payload='__DIREXTALK_PRODUCTION_COMMON__' ;;
    recover-production.sh) payload='__DIREXTALK_PRODUCTION_RECOVER__' ;;
    reconcile-production.sh) payload='__DIREXTALK_PRODUCTION_RECONCILE__' ;;
    reset-production.sh) payload='__DIREXTALK_PRODUCTION_RESET__' ;;
  esac
  printf '%s' "$payload" | base64 --decode > "$helper_tmp"
  sudo install -o root -g root -m 0755 "$helper_tmp" "/var/dirextalk-message-server/production-ops/$helper"
  rm -f "$helper_tmp"
  helper_tmp=''
done
helper_tmp=$(mktemp /tmp/dirextalk-split-recovery-service.XXXXXX)
printf '%s' '__DIREXTALK_SPLIT_RECOVERY_SERVICE__' | base64 --decode > "$helper_tmp"
sudo install -o root -g root -m 0644 "$helper_tmp" /etc/systemd/system/dirextalk-split-recovery.service
rm -f "$helper_tmp"
helper_tmp=''
sudo systemctl daemon-reload
sudo systemctl enable dirextalk-split-recovery.service >/dev/null
trap - EXIT
EOF
)
  template=${template/__DIREXTALK_PRODUCTION_BOOTSTRAP__/$bootstrap_payload}
  template=${template/__DIREXTALK_PRODUCTION_COMMON__/$common_payload}
  template=${template/__DIREXTALK_PRODUCTION_RECOVER__/$recover_payload}
  template=${template/__DIREXTALK_PRODUCTION_RECONCILE__/$reconcile_payload}
  template=${template/__DIREXTALK_PRODUCTION_RESET__/$reset_payload}
  printf '%s\n' "${template/__DIREXTALK_SPLIT_RECOVERY_SERVICE__/$service_payload}"
}

ops_state_path() {
  local explicit=${1:-}
  if [ -n "$explicit" ]; then
    dirextalk_execution_path "$explicit"
    return 0
  fi
  printf '%s/state.json\n' "$(dirextalk_default_workdir)"
}

ops_require_state() {
  local state=$1
  [ -f "$state" ] || {
    echo "state.json not found: $state" >&2
    return 1
  }
}

ops_state_get() {
  local state=$1 path=$2
  path=${path#\.}
  json_get "$state" "$path"
}

ops_sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ops_path_dirname() {
  local path=$1
  path=${path%/}
  case "$path" in
    */*) printf '%s\n' "${path%/*}" ;;
    *) printf '.\n' ;;
  esac
}

ops_normalize_path() {
  dirextalk_normalize_local_path "$1"
}

ops_paths_match() {
  dirextalk_paths_equal "$1" "$2"
}

ops_remote_base() {
  local state=$1 keyfile pubip
  keyfile=$(ops_state_get "$state" '.resources.key_file')
  pubip=$(ops_state_get "$state" '.resources.public_ip')
  [ -n "$keyfile" ] && [ -n "$pubip" ] || {
    echo "state is missing resources.key_file or resources.public_ip; cannot SSH to existing EC2" >&2
    return 1
  }
  printf '%s\t%s\n' "$keyfile" "$pubip"
}

ops_ssh() {
  local state=$1 command=$2 keyfile pubip known_hosts
  IFS=$'\t' read -r keyfile pubip < <(ops_remote_base "$state")
  known_hosts=$(ops_path_dirname "$state")/known_hosts
  [ -f "$known_hosts" ] && [ ! -L "$known_hosts" ] || {
    echo "recorded SSH host identity is missing: $known_hosts" >&2
    return 1
  }
  ssh -i "$keyfile" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 ubuntu@"$pubip" "$command"
}

ops_connect_service_name() {
  local state=$1 service_name service_dir
  service_name=$(ops_state_get "$state" '.agent_service_id')
  [ -n "$service_name" ] || service_name=$(ops_state_get "$state" '.domain')
  if [ -z "$service_name" ]; then
    service_dir=$(ops_state_get "$state" '.agent_service_dir')
    [ -n "$service_dir" ] && service_name=$(basename "$service_dir")
  fi
  printf '%s\n' "${service_name:-dirextalk-connect}"
}

ops_connect_target_work_dir() {
  local state=$1 config runtime_dir service_dir
  config=$(ops_state_get "$state" '.connect_config')
  runtime_dir=$(ops_state_get "$state" '.connect_runtime_dir')
  service_dir=$(ops_state_get "$state" '.agent_service_dir')
  if [ -n "$config" ]; then
    ops_path_dirname "$config"
  elif [ -n "$runtime_dir" ]; then
    printf '%s\n' "$runtime_dir"
  elif [ -n "$service_dir" ]; then
    printf '%s/dirextalk-connect\n' "${service_dir%/}"
  fi
}

ops_stop_scoped_daemon() {
  local state=$1 binary service_name target_work_dir status_out daemon_status work_dir
  binary=$(ops_state_get "$state" '.connect_binary')
  [ -n "$binary" ] || binary=dirextalk-connect
  service_name=$(ops_connect_service_name "$state")
  target_work_dir=$(ops_connect_target_work_dir "$state")
  [ -n "$target_work_dir" ] || return 1

  case "$binary" in
    */*|[A-Za-z]:/*|[A-Za-z]:\\*)
      [ -x "$binary" ] || return 1
      ;;
    *)
      command -v "$binary" >/dev/null 2>&1 || return 1
      ;;
  esac

  status_out=$("$binary" daemon status --service-name "$service_name" 2>/dev/null) || return 1
  daemon_status=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*Status:[[:space:]]*//p' | head -n 1)
  work_dir=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*WorkDir:[[:space:]]*//p' | head -n 1)
  [ "$daemon_status" = "Running" ] || return 1
  [ -n "$work_dir" ] || return 1
  ops_paths_match "$target_work_dir" "$work_dir" || return 1

  "$binary" daemon stop --service-name "$service_name" >/dev/null 2>&1
}

ops_update_remote_command() {
  local remote_script
  remote_script="$(ops_desired_state_helper_prelude)"$'\n'"$(ops_production_helpers_prelude)"$'\n'$(cat <<'EOF'
sudo /var/dirextalk-message-server/updater/set-desired-state.sh maintenance
sudo /var/dirextalk-message-server/production-ops/reconcile-production.sh
sudo /var/dirextalk-message-server/updater/set-desired-state.sh running
EOF
)
  printf 'sudo sh -lc %s\n' "$(ops_sh_quote "$remote_script")"
}

ops_reset_remote_command() {
  local remote_script
  remote_script="$(ops_desired_state_helper_prelude)"$'\n'"$(ops_production_helpers_prelude)"$'\n'$(cat <<'EOF'
sudo /var/dirextalk-message-server/updater/set-desired-state.sh maintenance
sudo /var/dirextalk-message-server/production-ops/reset-production.sh
sudo /var/dirextalk-message-server/updater/set-desired-state.sh running
EOF
)
  printf 'sudo sh -lc %s\n' "$(ops_sh_quote "$remote_script")"
}

ops_mark_refresh_pending() {
  local state=$1 start_phase=${2:-S4_BOOTSTRAP_STACK}
  json_mutate "$state" ops-refresh-pending "$start_phase" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

ops_write_report() {
  local operation=$1 status=$2 state=$3 report
  report=$(operation_report_write "$operation" "$status" "$state")
  printf '%s\n' "$report"
}
