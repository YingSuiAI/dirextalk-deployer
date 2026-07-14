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
  local state=$1 command=$2 keyfile pubip
  IFS=$'\t' read -r keyfile pubip < <(ops_remote_base "$state")
  ssh -i "$keyfile" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ubuntu@"$pubip" "$command"
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
  local image=${1:-} image_q remote_script
  remote_script="$(ops_desired_state_helper_prelude)"$'\n'$(cat <<'EOF'
cd /var/dirextalk-message-server
sudo /var/dirextalk-message-server/updater/set-desired-state.sh maintenance
if [ -n "${MESSAGE_SERVER_IMAGE:-}" ]; then
  IMAGE=$MESSAGE_SERVER_IMAGE
  escaped_image=$(printf '%s\n' "$IMAGE" | sed 's/[\/&]/\\&/g')
  if grep -q '^MESSAGE_SERVER_IMAGE=' .env; then
    sed -i "s#^MESSAGE_SERVER_IMAGE=.*#MESSAGE_SERVER_IMAGE=$escaped_image#" .env
  else
    printf 'MESSAGE_SERVER_IMAGE=%s\n' "$IMAGE" | tee -a .env >/dev/null
  fi
fi
docker compose --env-file .env pull
docker compose --env-file .env up -d
DOMAIN=$(grep '^DOMAIN=' .env | cut -d= -f2)
BOOTSTRAP_FILE=/var/dirextalk-message-server/p2p/bootstrap.json
bootstrap_ready() {
  test -s "$BOOTSTRAP_FILE" \
    && grep -q '"password"[[:space:]]*:' "$BOOTSTRAP_FILE" \
  && grep -q '"agent_token"[[:space:]]*:' "$BOOTSTRAP_FILE" \
  && grep -q '"access_token"[[:space:]]*:' "$BOOTSTRAP_FILE" \
    && grep -Eq '"agent_room_id"[[:space:]]*:[[:space:]]*"![^"]+"' "$BOOTSTRAP_FILE"
}
if bootstrap_ready; then
  echo "[update] existing bootstrap credentials are present; skipping portal.bootstrap."
else
  DOMAIN="$DOMAIN" bash /var/dirextalk-message-server/init-tokens.sh
fi
sudo /var/dirextalk-message-server/updater/set-desired-state.sh running
EOF
)
  if [ -n "$image" ]; then
    image_q=$(ops_sh_quote "$image")
    printf 'sudo MESSAGE_SERVER_IMAGE=%s sh -lc %s\n' "$image_q" "$(ops_sh_quote "$remote_script")"
  else
    printf 'sudo sh -lc %s\n' "$(ops_sh_quote "$remote_script")"
  fi
}

ops_reset_remote_command() {
  ops_desired_state_helper_prelude
  cat <<'EOF'
cd /var/dirextalk-message-server
sudo /var/dirextalk-message-server/updater/set-desired-state.sh maintenance
sudo docker compose --env-file .env down
project=$(basename "$PWD")
for volume in postgres-data message-config message-data; do
  ids=$(sudo docker volume ls -q --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.volume=$volume" 2>/dev/null || true)
  if [ -n "$ids" ]; then
    sudo docker volume rm $ids >/dev/null 2>&1 || true
  fi
  sudo docker volume rm "${project}_${volume}" >/dev/null 2>&1 || true
done
sudo rm -f /var/dirextalk-message-server/p2p/bootstrap.json
new_code=$(od -An -N4 -tu4 /dev/urandom | awk '{printf "%08d", $1 % 100000000}')
sudo sed -i '/^P2P_PORTAL_PASSWORD=/d' .env
printf 'P2P_PORTAL_PASSWORD=%s\n' "$new_code" | sudo tee -a .env >/dev/null
sudo docker compose --env-file .env up -d
DOMAIN=$(grep '^DOMAIN=' .env | cut -d= -f2)
sudo DOMAIN="$DOMAIN" bash /var/dirextalk-message-server/init-tokens.sh
sudo /var/dirextalk-message-server/updater/set-desired-state.sh running
EOF
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
