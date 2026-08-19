#!/usr/bin/env bash
# lib/ops.sh - existing-node update/reset helpers.

OPS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$OPS_LIB_DIR/paths.sh"
# shellcheck disable=SC1090
source "$OPS_LIB_DIR/json.sh"

OPS_SPLIT_DIR=$OPS_LIB_DIR/../cloud-init/split

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
  local bootstrap_payload common_payload migrate_payload recover_payload reconcile_payload reset_payload service_payload template
  bootstrap_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/bootstrap-production.sh" | tr -d '\r\n')
  common_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/production-ops-common.sh" | tr -d '\r\n')
  migrate_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/migrate-message-mcp-token-binding.sh" | tr -d '\r\n')
  recover_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/recover-production.sh" | tr -d '\r\n')
  reconcile_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/reconcile-production.sh" | tr -d '\r\n')
  reset_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/reset-production.sh" | tr -d '\r\n')
  service_payload=$(base64 < "$OPS_LIB_DIR/../cloud-init/split/dirextalk-split-recovery.service" | tr -d '\r\n')
  template=''
  IFS= read -r -d '' template <<'EOF' || [ -n "$template" ]
set -eu
sudo install -d -o root -g root -m 0700 /var/dirextalk-message-server/production-ops
helper_tmp=''
cleanup_production_helper() { [ -z "$helper_tmp" ] || rm -f "$helper_tmp"; }
trap cleanup_production_helper EXIT
for helper in bootstrap-production.sh migrate-message-mcp-token-binding.sh production-ops-common.sh recover-production.sh reconcile-production.sh reset-production.sh; do
  helper_tmp=$(mktemp /tmp/dirextalk-production-helper.XXXXXX)
  case "$helper" in
    bootstrap-production.sh) payload='__DIREXTALK_PRODUCTION_BOOTSTRAP__' ;;
    migrate-message-mcp-token-binding.sh) payload='__DIREXTALK_PRODUCTION_MIGRATE_MESSAGE_MCP__' ;;
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
  template=${template/__DIREXTALK_PRODUCTION_BOOTSTRAP__/$bootstrap_payload}
  template=${template/__DIREXTALK_PRODUCTION_MIGRATE_MESSAGE_MCP__/$migrate_payload}
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

ops_require_existing_node_identity() {
  local state=$1 field value
  for field in \
    aws_account_id region cloud_provider provider_instance_id \
    provider_instance_arn public_ip machine_id docker_engine_id; do
    value=$(ops_state_get "$state" ".node_identity.$field")
    [ -n "$value" ] || {
      echo "state is missing immutable node_identity.$field; refusing existing-node update" >&2
      return 1
    }
  done
  [ "$(ops_state_get "$state" .region)" = "$(ops_state_get "$state" .node_identity.region)" ] \
    && [ "$(ops_state_get "$state" .cloud_provider)" = "$(ops_state_get "$state" .node_identity.cloud_provider)" ] \
    && [ "$(ops_state_get "$state" .resources.public_ip)" = "$(ops_state_get "$state" .node_identity.public_ip)" ] \
    || {
      echo "mutable deployment coordinates differ from the immutable node identity receipt" >&2
      return 1
    }
  case "$(ops_state_get "$state" .node_identity.cloud_provider)" in
    lightsail)
      [ -n "$(ops_state_get "$state" .node_identity.provider_support_code)" ] || {
        echo "state is missing immutable node_identity.provider_support_code" >&2
        return 1
      }
      ;;
    ec2) ;;
    *) echo "unsupported existing-node cloud provider" >&2; return 1 ;;
  esac
  if ! printf '%s\n' "$(ops_state_get "$state" .node_identity.aws_account_id)" | grep -Eq '^[0-9]{12}$' \
    || ! printf '%s\n' "$(ops_state_get "$state" .node_identity.region)" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' \
    || ! printf '%s\n' "$(ops_state_get "$state" .node_identity.machine_id)" | grep -Eq '^[0-9a-f]{32}$' \
    || ! printf '%s\n' "$(ops_state_get "$state" .node_identity.docker_engine_id)" | grep -Eq '^[A-Za-z0-9:+._-]{8,128}$' \
    || ! printf '%s\n' "$(ops_state_get "$state" .node_identity.public_ip)" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "immutable node identity receipt contains malformed values" >&2
    return 1
  fi
}

ops_verify_existing_node_identity() {
  local state=$1 account region provider provider_id provider_arn support_code public_ip
  local actual_account actual_provider machine_id docker_engine_id actual_host
  ops_require_existing_node_identity "$state" || return 1
  account=$(ops_state_get "$state" .node_identity.aws_account_id)
  region=$(ops_state_get "$state" .node_identity.region)
  provider=$(ops_state_get "$state" .node_identity.cloud_provider)
  provider_id=$(ops_state_get "$state" .node_identity.provider_instance_id)
  provider_arn=$(ops_state_get "$state" .node_identity.provider_instance_arn)
  support_code=$(ops_state_get "$state" .node_identity.provider_support_code)
  public_ip=$(ops_state_get "$state" .node_identity.public_ip)

  actual_account=$(aws sts get-caller-identity --query Account --output text) || return 1
  [ "$actual_account" = "$account" ] || {
    echo "AWS account identity differs from the existing-node receipt" >&2
    return 1
  }
  case "$provider" in
    lightsail)
      # AWS CLI JMESPath backticks below are literals.
      # shellcheck disable=SC2016
      actual_provider=$(aws --region "$region" lightsail get-instance \
        --instance-name "$(ops_state_get "$state" .resources.lightsail_instance_name)" \
        --query 'join(`\t`,[instance.arn,instance.supportCode,instance.publicIpAddress])' --output text) || return 1
      [ "$actual_provider" = "$provider_arn"$'\t'"$support_code"$'\t'"$public_ip" ] || {
        echo "Lightsail instance identity differs from the existing-node receipt" >&2
        return 1
      }
      case "$provider_arn" in */"$provider_id") ;; *) echo "Lightsail provider identifier is not bound to its ARN" >&2; return 1 ;; esac
      ;;
    ec2)
      # AWS CLI JMESPath backticks below are literals.
      # shellcheck disable=SC2016
      actual_provider=$(aws --region "$region" ec2 describe-instances --instance-ids "$provider_id" \
        --query 'join(`\t`,[Reservations[0].OwnerId,Reservations[0].Instances[0].InstanceId,Reservations[0].Instances[0].PublicIpAddress])' --output text) || return 1
      [ "$actual_provider" = "$account"$'\t'"$provider_id"$'\t'"$public_ip" ] \
        && [ "$provider_arn" = "arn:aws:ec2:$region:$account:instance/$provider_id" ] || {
        echo "EC2 instance identity differs from the existing-node receipt" >&2
        return 1
      }
      ;;
  esac

  actual_host=$(ops_ssh "$state" "set -eu; printf '%s\\t' \"\$(cat /etc/machine-id)\"; sudo docker info --format '{{.ID}}'") || return 1
  IFS=$'\t' read -r machine_id docker_engine_id <<<"$actual_host"
  [ "$machine_id" = "$(ops_state_get "$state" .node_identity.machine_id)" ] \
    && [ "$docker_engine_id" = "$(ops_state_get "$state" .node_identity.docker_engine_id)" ] || {
      echo "SSH host identity differs from the existing-node receipt" >&2
      return 1
  }
}

ops_read_remote_split_release() {
  local state=$1 expected_machine expected_docker remote_command remote_release
  expected_machine=$(ops_state_get "$state" .node_identity.machine_id)
  expected_docker=$(ops_state_get "$state" .node_identity.docker_engine_id)
  remote_command=$(cat <<EOF
set -eu
expected_machine=$(ops_sh_quote "$expected_machine")
expected_docker=$(ops_sh_quote "$expected_docker")
[ "\$(cat /etc/machine-id)" = "\$expected_machine" ]
[ "\$(sudo docker info --format '{{.ID}}')" = "\$expected_docker" ]
file=/var/dirextalk-message-server/split/.env
[ -f "\$file" ] && [ ! -L "\$file" ]
[ "\$(sudo stat -c '%u:%g:%a' "\$file")" = 0:0:400 ]
receipt_identity=\$(sudo stat -c '%d:%i:%u:%g:%a' "\$file")
receipt_sha=\$(sudo sha256sum "\$file" | awk '{print \$1}')
read_unique() {
  count=\$(sudo awk -F= -v wanted="\$1" '\$1 == wanted {n++} END {print n+0}' "\$file")
  [ "\$count" -eq 1 ]
  sudo awk -F= -v wanted="\$1" '\$1 == wanted {print substr(\$0,length(wanted)+2); exit}' "\$file"
}
message_version=\$(read_unique DIREXTALK_MESSAGE_SERVER_VERSION)
message_image=\$(read_unique DIREXTALK_MESSAGE_SERVER_IMAGE)
message_revision=\$(read_unique DIREXTALK_MESSAGE_SOURCE_REVISION)
agent_version=\$(read_unique DIREXTALK_AGENT_VERSION)
agent_image=\$(read_unique DIREXTALK_AGENT_IMAGE)
agent_revision=\$(read_unique DIREXTALK_AGENT_SOURCE_REVISION)
printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
  "\$message_version" "\$message_image" "\$message_revision" "\$agent_version" "\$agent_image" "\$agent_revision" \\
  "\$receipt_identity" "\$receipt_sha"
EOF
  )
  remote_release=$(ops_ssh "$state" "$remote_command") || return 1
  IFS=$'\t' read -r \
    DIREXTALK_REMOTE_MESSAGE_VERSION DIREXTALK_REMOTE_MESSAGE_IMAGE DIREXTALK_REMOTE_MESSAGE_REVISION \
    DIREXTALK_REMOTE_AGENT_VERSION DIREXTALK_REMOTE_AGENT_IMAGE DIREXTALK_REMOTE_AGENT_REVISION \
    DIREXTALK_REMOTE_SPLIT_RECEIPT_IDENTITY DIREXTALK_REMOTE_SPLIT_RECEIPT_SHA \
    <<<"$remote_release"
  [ -n "$DIREXTALK_REMOTE_MESSAGE_VERSION" ] \
    && [ -n "$DIREXTALK_REMOTE_MESSAGE_IMAGE" ] \
    && [ -n "$DIREXTALK_REMOTE_MESSAGE_REVISION" ] \
    && [ -n "$DIREXTALK_REMOTE_AGENT_VERSION" ] \
    && [ -n "$DIREXTALK_REMOTE_AGENT_IMAGE" ] \
    && [ -n "$DIREXTALK_REMOTE_AGENT_REVISION" ] \
    && printf '%s\n' "$DIREXTALK_REMOTE_SPLIT_RECEIPT_IDENTITY" | grep -Eq '^[0-9]+:[0-9]+:0:0:400$' \
    && printf '%s\n' "$DIREXTALK_REMOTE_SPLIT_RECEIPT_SHA" | grep -Eq '^[0-9a-f]{64}$' || {
      echo "remote split release receipt is incomplete" >&2
      return 1
    }
  export DIREXTALK_REMOTE_MESSAGE_VERSION DIREXTALK_REMOTE_MESSAGE_IMAGE DIREXTALK_REMOTE_MESSAGE_REVISION
  export DIREXTALK_REMOTE_AGENT_VERSION DIREXTALK_REMOTE_AGENT_IMAGE DIREXTALK_REMOTE_AGENT_REVISION
  export DIREXTALK_REMOTE_SPLIT_RECEIPT_IDENTITY DIREXTALK_REMOTE_SPLIT_RECEIPT_SHA
}

ops_stage_current_host_integration() (
  local state=$1 expected_old=$2 integration_bundle split_bundle split_sha_file expected_sha actual_sha result status
  local remote_command remote_release_command remote_receipt_check public_ip host_region identity
  local -a integration_files
  split_bundle=$OPS_SPLIT_DIR/canonical-bundle.tar.gz
  split_sha_file=$split_bundle.sha256
  [ -f "$split_bundle" ] && [ ! -L "$split_bundle" ] \
    && [ -f "$split_sha_file" ] && [ ! -L "$split_sha_file" ] || {
      echo "packaged canonical split bundle or checksum is missing" >&2
      return 1
    }
  expected_sha=$(awk 'NF == 2 && $2 == "canonical-bundle.tar.gz" {print $1}' "$split_sha_file")
  actual_sha=$(sha256sum "$split_bundle" | awk '{print $1}')
  printf '%s\n' "$expected_sha" | grep -Eq '^[0-9a-f]{64}$' && [ "$actual_sha" = "$expected_sha" ] || {
    echo "packaged canonical split bundle checksum differs" >&2
    return 1
  }
  integration_bundle=$(mktemp "${state%/*}/.existing-update.XXXXXX.tar.gz") || return 1
  trap 'rm -f "$integration_bundle"' EXIT
  integration_files=( -C "$OPS_LIB_DIR/.." -cf - \
    cloud-init/split/Caddyfile \
    cloud-init/split/edge-compose.override.yaml \
    cloud-init/split/bootstrap-production.sh \
    cloud-init/split/apply-host-integration.sh \
    cloud-init/split/authorize-split-source-revision.sh \
    cloud-init/split/advance-split-source-revision.sh \
    cloud-init/split/release.env \
    cloud-init/split/migrate-message-mcp-token-binding.sh \
    cloud-init/split/production-ops-common.sh \
    cloud-init/split/recover-production.sh \
    cloud-init/split/reconcile-production.sh \
    cloud-init/split/reset-production.sh \
    cloud-init/split/dirextalk-split-recovery.service \
    updater/bootstrap-host.sh updater/install.sh updater/reconcile-host.sh \
    updater/set-desired-state.sh updater/release.env updater/config.json \
    updater/dirextalk-updater.service )
  integration_files+=( -C "${split_bundle%/*}" "${split_bundle##*/}" )
  tar "${integration_files[@]}" | gzip -n >"$integration_bundle" || return 1
  public_ip=$(ops_state_get "$state" .node_identity.public_ip)
  host_region=$(ops_state_get "$state" .node_identity.region)
  printf '%s\n' "$host_region" | grep -Eq '^[a-z]{2}(-[a-z0-9]+)+-[1-9][0-9]*$' || {
    echo "immutable node identity receipt contains a malformed region" >&2
    return 1
  }
  expected_machine_id=$(ops_state_get "$state" .node_identity.machine_id)
  expected_docker_engine_id=$(ops_state_get "$state" .node_identity.docker_engine_id)
  remote_receipt_check="receipt=/var/dirextalk-message-server/split/.env; [ -f \"\$receipt\" ] && [ ! -L \"\$receipt\" ] && [ \"\$(sudo stat -c '%u:%g:%a' \"\$receipt\")\" = 0:0:400 ]; [ \"\$(sudo stat -c '%d:%i:%u:%g:%a' \"\$receipt\")\" = $(ops_sh_quote "$DIREXTALK_REMOTE_SPLIT_RECEIPT_IDENTITY") ]; [ \"\$(sudo sha256sum \"\$receipt\" | awk '{print \$1}')\" = $(ops_sh_quote "$DIREXTALK_REMOTE_SPLIT_RECEIPT_SHA") ]; [ \"\$(sudo grep -Fxc -- $(ops_sh_quote "DIREXTALK_MESSAGE_SERVER_VERSION=$DIREXTALK_REMOTE_MESSAGE_VERSION") \"\$receipt\")\" = 1 ]; [ \"\$(sudo grep -Fxc -- $(ops_sh_quote "DIREXTALK_MESSAGE_SERVER_IMAGE=$DIREXTALK_REMOTE_MESSAGE_IMAGE") \"\$receipt\")\" = 1 ]; [ \"\$(sudo grep -Fxc -- $(ops_sh_quote "DIREXTALK_MESSAGE_SOURCE_REVISION=$DIREXTALK_REMOTE_MESSAGE_REVISION") \"\$receipt\")\" = 1 ]; [ \"\$(sudo grep -Fxc -- $(ops_sh_quote "DIREXTALK_AGENT_VERSION=$DIREXTALK_REMOTE_AGENT_VERSION") \"\$receipt\")\" = 1 ]; [ \"\$(sudo grep -Fxc -- $(ops_sh_quote "DIREXTALK_AGENT_IMAGE=$DIREXTALK_REMOTE_AGENT_IMAGE") \"\$receipt\")\" = 1 ]; [ \"\$(sudo grep -Fxc -- $(ops_sh_quote "DIREXTALK_AGENT_SOURCE_REVISION=$DIREXTALK_REMOTE_AGENT_REVISION") \"\$receipt\")\" = 1 ];"
  remote_release_command=''
  if [ "${DIREXTALK_UPDATE_MESSAGE_APPLY:-false}" = true ]; then
    remote_release_command+="sudo docker pull $(ops_sh_quote "$DIREXTALK_UPDATE_MESSAGE_IMAGE_REF") >/dev/null; message_identity=\$(sudo docker image inspect $(ops_sh_quote "$DIREXTALK_UPDATE_MESSAGE_IMAGE_REF") --format '{{index .Config.Labels \"org.opencontainers.image.version\"}}|{{index .Config.Labels \"org.opencontainers.image.revision\"}}'); [ \"\$message_identity\" = $(ops_sh_quote "$DIREXTALK_UPDATE_MESSAGE_VERSION|$DIREXTALK_UPDATE_MESSAGE_REVISION") ]; sudo env DIREXTALK_MESSAGE_SERVER_LOCAL_IMAGE_REF=$(ops_sh_quote "$DIREXTALK_UPDATE_MESSAGE_IMAGE_REF") /var/dirextalk-message-server/deploy/split-agent/scripts/update-message-server-local.sh /var/dirextalk-message-server/split $(ops_sh_quote "$DIREXTALK_UPDATE_MESSAGE_VERSION"); "
  fi
  if [ "${DIREXTALK_UPDATE_AGENT_APPLY:-false}" = true ]; then
    remote_release_command+="sudo docker pull $(ops_sh_quote "$DIREXTALK_UPDATE_AGENT_IMAGE_REF") >/dev/null; agent_identity=\$(sudo docker image inspect $(ops_sh_quote "$DIREXTALK_UPDATE_AGENT_IMAGE_REF") --format '{{index .Config.Labels \"org.opencontainers.image.version\"}}|{{index .Config.Labels \"org.opencontainers.image.revision\"}}'); [ \"\$agent_identity\" = $(ops_sh_quote "$DIREXTALK_UPDATE_AGENT_VERSION|$DIREXTALK_UPDATE_AGENT_REVISION") ]; sudo env DIREXTALK_AGENT_LOCAL_IMAGE_REF=$(ops_sh_quote "$DIREXTALK_UPDATE_AGENT_IMAGE_REF") /var/dirextalk-message-server/deploy/split-agent/scripts/update-agent-local.sh /var/dirextalk-message-server/split $(ops_sh_quote "$DIREXTALK_UPDATE_AGENT_VERSION") $(ops_sh_quote "$DIREXTALK_UPDATE_AGENT_MINIMUM_SERVER_VERSION"); "
  fi
  if [ -n "$remote_release_command" ]; then
    remote_release_command="release_lock=/var/dirextalk-message-server/.direct-release-update.lock; sudo install -o root -g root -m 0600 /dev/null \"\$release_lock\"; exec 7>\"\$release_lock\"; flock -n 7; $remote_release_command sudo /var/dirextalk-message-server/production-ops/reconcile-production.sh; "
  fi
  remote_command="set -eu; expected_machine_id=$(ops_sh_quote "$expected_machine_id"); expected_docker_engine_id=$(ops_sh_quote "$expected_docker_engine_id"); [ \"\$(cat /etc/machine-id)\" = \"\$expected_machine_id\" ] && [ \"\$(sudo docker info --format '{{.ID}}')\" = \"\$expected_docker_engine_id\" ]; $remote_receipt_check stage=\$(sudo mktemp -d /tmp/dirextalk-updater-integration.XXXXXX); trap 'sudo rm -rf \"\$stage\"' EXIT; sudo chmod 0700 \"\$stage\"; sudo tar --no-same-owner -xzf - -C \"\$stage\"; sudo bash \"\$stage/cloud-init/split/apply-host-integration.sh\" \"\$stage\" \"\$stage/${split_bundle##*/}\" /var/dirextalk-message-server $(ops_sh_quote "$expected_old") $(ops_sh_quote "$public_ip") $(ops_sh_quote "$host_region"); $remote_release_command [ \"\$(cat /etc/machine-id)\" = \"\$expected_machine_id\" ] && [ \"\$(sudo docker info --format '{{.ID}}')\" = \"\$expected_docker_engine_id\" ]; printf '%s\\t%s\\t%s\\n' \"\$expected_machine_id\" \"\$expected_docker_engine_id\" $(ops_sh_quote "$actual_sha")"
  if result=$(ops_ssh "$state" "$remote_command" <"$integration_bundle"); then
    :
  else
    status=$?
    case "$status" in 3) return 3 ;; *) return 1 ;; esac
  fi
  identity=$(printf '%s\n' "$result" | tail -n 1)
  [ "$identity" = "$(ops_state_get "$state" .node_identity.machine_id)"$'\t'"$(ops_state_get "$state" .node_identity.docker_engine_id)"$'\t'"$actual_sha" ] || {
    echo "remote host integration completion receipt differs" >&2
    return 1
  }
)

ops_commit_existing_update_release() {
  local state=$1 expected_split_json=$2 expected_updater_json=$3 split_json updater_json server_json
  split_json=$(json_build object \
    "release_catalog_origin=$(ops_state_get "$state" .split_release.release_catalog_origin)" \
    "message_version=$DIREXTALK_UPDATE_MESSAGE_VERSION" \
    "message_image=$DIREXTALK_UPDATE_MESSAGE_IMAGE" \
    "message_source_revision=$DIREXTALK_UPDATE_MESSAGE_REVISION" \
    "message_manifest_digest=$DIREXTALK_UPDATE_MESSAGE_DIGEST" \
    "split_source_revision=$DIREXTALK_SPLIT_SOURCE_REVISION" \
    "agent_version=$DIREXTALK_UPDATE_AGENT_VERSION" \
    "agent_image=$DIREXTALK_UPDATE_AGENT_IMAGE" \
    "agent_source_revision=$DIREXTALK_UPDATE_AGENT_REVISION" \
    "agent_manifest_digest=$DIREXTALK_UPDATE_AGENT_DIGEST" \
    "postgres_image=$(ops_state_get "$state" .split_release.postgres_image)" \
    "caddy_image=$(ops_state_get "$state" .split_release.caddy_image)" \
    "coturn_image=$(ops_state_get "$state" .split_release.coturn_image)") || return 1
  server_json=$(json_build object \
    'source=production_split' "version=$DIREXTALK_UPDATE_MESSAGE_VERSION" \
    "image=$DIREXTALK_UPDATE_MESSAGE_IMAGE" "digest=$DIREXTALK_UPDATE_MESSAGE_DIGEST" \
    "image_ref=$DIREXTALK_UPDATE_MESSAGE_IMAGE" "manifest_digest=$DIREXTALK_UPDATE_MESSAGE_DIGEST") || return 1
  updater_json=$(json_build object \
    "version=$UPDATER_PIN_VERSION" "commit=$UPDATER_PIN_COMMIT" "url=$UPDATER_PIN_URL" \
    "asset=$UPDATER_PIN_ASSET" "sha256=$UPDATER_PIN_SHA256" "os=$UPDATER_PIN_OS" \
    "arch=$UPDATER_PIN_ARCH" "ubuntu_version=$UPDATER_PIN_UBUNTU_VERSION") || return 1
  json_mutate "$state" existing-update-release-commit "$expected_split_json" "$expected_updater_json" "$split_json" "$updater_json" "$server_json"
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
