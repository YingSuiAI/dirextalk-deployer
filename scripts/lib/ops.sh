#!/usr/bin/env bash
# lib/ops.sh - existing-node update/reset helpers.

ops_state_path() {
  local explicit=${1:-}
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  printf '%s/state.json\n' "$(direxio_default_workdir)"
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
  jq -r "$path // empty" "$state"
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
  local path=$1
  path=$(printf '%s' "$path" | sed 's#\\#/#g')
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    case "$path" in [A-Za-z]:/) break ;; esac
    path=${path%/}
  done
  printf '%s\n' "$path"
}

ops_paths_match() {
  local left right
  left=$(ops_normalize_path "$1")
  right=$(ops_normalize_path "$2")
  case "$left:$right" in
    [A-Za-z]:/*:[A-Za-z]:/*)
      [ "$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')" ]
      ;;
    *)
      [ "$left" = "$right" ]
      ;;
  esac
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

ops_cc_connect_service_name() {
  local state=$1 service_name service_dir
  service_name=$(ops_state_get "$state" '.agent_service_id')
  [ -n "$service_name" ] || service_name=$(ops_state_get "$state" '.domain')
  if [ -z "$service_name" ]; then
    service_dir=$(ops_state_get "$state" '.agent_service_dir')
    [ -n "$service_dir" ] && service_name=$(basename "$service_dir")
  fi
  printf '%s\n' "${service_name:-cc-connect}"
}

ops_cc_connect_target_work_dir() {
  local state=$1 config runtime_dir service_dir
  config=$(ops_state_get "$state" '.cc_connect_config')
  runtime_dir=$(ops_state_get "$state" '.cc_connect_runtime_dir')
  service_dir=$(ops_state_get "$state" '.agent_service_dir')
  if [ -n "$config" ]; then
    ops_path_dirname "$config"
  elif [ -n "$runtime_dir" ]; then
    printf '%s\n' "$runtime_dir"
  elif [ -n "$service_dir" ]; then
    printf '%s/cc-connect\n' "${service_dir%/}"
  fi
}

ops_stop_scoped_daemon() {
  local state=$1 binary service_name target_work_dir status_out daemon_status work_dir
  binary=$(ops_state_get "$state" '.cc_connect_binary')
  [ -n "$binary" ] || binary=direxio-connect
  service_name=$(ops_cc_connect_service_name "$state")
  target_work_dir=$(ops_cc_connect_target_work_dir "$state")
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
  image_q=$(ops_sh_quote "$image")
  remote_script=$(cat <<'EOF'
set -eu
cd /opt/p2p
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
sync_container_bootstrap() {
  tmp=$(mktemp)
  if docker compose --env-file .env exec -T message-server sh -c 'test -s /var/direxio-message-server/p2p/bootstrap.json && cat /var/direxio-message-server/p2p/bootstrap.json' > "$tmp"; then
    install -m 0600 "$tmp" /opt/p2p/bootstrap.json
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}
bootstrap_ready() {
  test -s /opt/p2p/bootstrap.json \
    && grep -q '"password"[[:space:]]*:' /opt/p2p/bootstrap.json \
  && grep -q '"agent_token"[[:space:]]*:' /opt/p2p/bootstrap.json \
  && grep -q '"access_token"[[:space:]]*:' /opt/p2p/bootstrap.json \
    && grep -Eq '"agent_room_id"[[:space:]]*:[[:space:]]*"![^"]+"' /opt/p2p/bootstrap.json
}
if sync_container_bootstrap && bootstrap_ready; then
  echo "[update] existing bootstrap credentials are present; skipping portal.bootstrap."
else
  DOMAIN="$DOMAIN" bash /opt/p2p/init-tokens.sh
fi
EOF
)
  printf 'sudo MESSAGE_SERVER_IMAGE=%s sh -lc %s\n' "$image_q" "$(ops_sh_quote "$remote_script")"
}

ops_reset_remote_command() {
  cat <<'EOF'
set -eu
cd /opt/p2p
sudo docker compose --env-file .env down
project=$(basename "$PWD")
for volume in postgres-data message-config message-data; do
  ids=$(sudo docker volume ls -q --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.volume=$volume" 2>/dev/null || true)
  if [ -n "$ids" ]; then
    sudo docker volume rm $ids >/dev/null 2>&1 || true
  fi
  sudo docker volume rm "${project}_${volume}" >/dev/null 2>&1 || true
done
sudo rm -f /opt/p2p/bootstrap.json /opt/p2p/wellknown/owner.json
new_code=$(od -An -N4 -tu4 /dev/urandom | awk '{printf "%08d", $1 % 100000000}')
sudo sed -i '/^P2P_PORTAL_PASSWORD=/d' .env
printf 'P2P_PORTAL_PASSWORD=%s\n' "$new_code" | sudo tee -a .env >/dev/null
sudo docker compose --env-file .env up -d
DOMAIN=$(grep '^DOMAIN=' .env | cut -d= -f2)
sudo DOMAIN="$DOMAIN" bash /opt/p2p/init-tokens.sh
EOF
}

ops_mark_refresh_pending() {
  local state=$1 start_phase=${2:-S4_BOOTSTRAP_STACK} tmp
  tmp="$state.tmp.$$"
  jq --arg start "$start_phase" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    del(
      .password,
      .access_token,
      .agent_token,
      .agent_room_id,
      .user_confirmations,
      .runtime_checks
    )
    | .agent_install_status = "refresh_pending"
    | .phase = $start
    | (if ($start == "S4_BOOTSTRAP_STACK") then
        .phases.S4_BOOTSTRAP_STACK = {status:"pending", ts:$ts, evidence:"existing node operation requires fresh health check"}
      else . end)
    | .phases.S5_INIT_TOKENS = {status:"pending", ts:$ts, evidence:"existing node operation requires fresh bootstrap credentials"}
    | .phases.S6_WIRE_LOCAL = {status:"pending", ts:$ts, evidence:"existing node operation requires local credentials and MCP refresh"}
    | .phases.S7_VERIFY_E2E = {status:"pending", ts:$ts, evidence:"existing node operation requires fresh verification"}
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

ops_write_report() {
  local operation=$1 status=$2 state=$3 report
  report=$(operation_report_write "$operation" "$status" "$state")
  printf '%s\n' "$report"
}
