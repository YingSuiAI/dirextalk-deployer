#!/usr/bin/env bash

production_die() { printf 'split production operation: %s\n' "$*" >&2; exit 1; }
production_negative() { printf 'split production operation: %s\n' "$*" >&2; exit 3; }

production_read_pair() {
  local file=$1 key=$2 count value
  count=$(awk -F= -v wanted="$key" '$1 == wanted {n++} END {print n+0}' "$file")
  [ "$count" -eq 1 ] || production_die "$file must contain exactly one $key"
  value=$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0,length(wanted)+2); exit}' "$file")
  [ -n "$value" ] || production_die "$file contains an empty $key"
  printf '%s' "$value"
}

production_require_control_file() {
  local file=$1 mode=$2
  [ -f "$file" ] && [ ! -L "$file" ] || production_die "missing regular control file: $file"
  [ "$(stat -c '%u:%a' "$file")" = "$(id -u):$mode" ] || production_die "control file owner or mode differs: $file"
}

production_migrate_message_mcp_token_binding() (
  set -euo pipefail

  local expected_uid expected_gid run_identity env_identity manifest_identity receipt_identity
  local env_sha256 manifest_sha256 receipt_sha256 stack env_stack env_count manifest_count
  local token_file transaction transaction_identity candidate_env candidate_manifest candidate_receipt candidate_token
  local backup_env backup_manifest backup_receipt candidate_env_identity candidate_manifest_identity candidate_receipt_identity
  local candidate_env_sha256 candidate_manifest_sha256 candidate_receipt_sha256 candidate_token_identity
  local env_swapped=false manifest_swapped=false receipt_swapped=false token_swapped=false committed=false

  production_base=${DIREXTALK_PRODUCTION_BASE:-/var/dirextalk-message-server}
  production_run=$production_base/split
  production_env=$production_run/.env
  production_manifest=$production_run/.manifest
  production_receipt=$production_run/.cleanup-receipt
  token_file=$production_run/message-mcp-token
  expected_uid=$(id -u)
  expected_gid=$(id -g)

  [ -d "$production_run" ] && [ ! -L "$production_run" ] \
    || production_die 'split runtime directory is unavailable for Message MCP token migration'
  [ "$(stat -c '%u:%g:%a' -- "$production_run")" = "$expected_uid:$expected_gid:700" ] \
    || production_die 'split runtime directory owner or mode differs for Message MCP token migration'
  run_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$production_run") \
    || production_die 'cannot record split runtime directory identity for Message MCP token migration'
  production_require_control_file "$production_env" 400
  production_require_control_file "$production_manifest" 400
  production_require_control_file "$production_receipt" 400
  [ "$(stat -c '%g' -- "$production_env")" = "$expected_gid" ] \
    && [ "$(stat -c '%g' -- "$production_manifest")" = "$expected_gid" ] \
    && [ "$(stat -c '%g' -- "$production_receipt")" = "$expected_gid" ] \
    || production_die 'runtime control file group differs for Message MCP token migration'
  grep -Fqx '# dirextalk-split-cleanup-receipt-v1' "$production_receipt" \
    || production_die 'cleanup receipt version is unsupported for Message MCP token migration'
  [ "$(production_read_pair "$production_receipt" state)" = complete ] \
    || production_negative 'split runtime cleanup receipt is not complete for Message MCP token migration'
  [ "$(production_read_pair "$production_manifest" compose_mode)" = production ] \
    || production_negative 'Message MCP token migration requires a production stack'

  env_identity=$(stat -c '%d:%i:%u' -- "$production_env")
  manifest_identity=$(stat -c '%d:%i:%u' -- "$production_manifest")
  receipt_identity=$(stat -c '%d:%i:%u' -- "$production_receipt")
  env_sha256=$(sha256sum -- "$production_env" | awk '{print $1}')
  manifest_sha256=$(sha256sum -- "$production_manifest" | awk '{print $1}')
  receipt_sha256=$(sha256sum -- "$production_receipt" | awk '{print $1}')
  [ "$(production_read_pair "$production_receipt" control.env_identity)" = "$env_identity" ] \
    || production_die 'runtime environment identity differs from receipt before Message MCP token migration'
  [ "$(production_read_pair "$production_receipt" control.manifest_identity)" = "$manifest_identity" ] \
    || production_die 'runtime manifest identity differs from receipt before Message MCP token migration'
  [ "$(production_read_pair "$production_receipt" control.env_sha256)" = "$env_sha256" ] \
    || production_die 'runtime environment digest differs from receipt before Message MCP token migration'
  [ "$(production_read_pair "$production_receipt" control.manifest_sha256)" = "$manifest_sha256" ] \
    || production_die 'runtime manifest digest differs from receipt before Message MCP token migration'
  stack=$(production_read_pair "$production_manifest" stack_name)
  printf '%s\n' "$stack" | grep -Eq '^d-[a-z2-7]{26}$' \
    || production_die 'split stack identity is invalid for Message MCP token migration'
  [ "$(production_read_pair "$production_receipt" stack_name)" = "$stack" ] \
    || production_die 'runtime receipt stack differs from manifest before Message MCP token migration'
  env_stack=$(production_read_pair "$production_env" DIREXTALK_SPLIT_STACK_NAME)
  [ "$env_stack" = "$stack" ] \
    || production_die 'runtime environment stack differs from manifest before Message MCP token migration'

  env_count=$(awk -F= '$1 == "DIREXTALK_MESSAGE_MCP_TOKEN_FILE" {n++} END {print n+0}' "$production_env")
  manifest_count=$(awk -F= '$1 == "message_mcp_token_path" {n++} END {print n+0}' "$production_manifest")
  if [ "$env_count" -eq 1 ] && [ "$manifest_count" -eq 1 ]; then
    [ "$(production_read_pair "$production_env" DIREXTALK_MESSAGE_MCP_TOKEN_FILE)" = "$token_file" ] \
      && [ "$(production_read_pair "$production_manifest" message_mcp_token_path)" = "$token_file" ] \
      || production_negative 'existing Message MCP token binding is not canonical'
    [ -f "$token_file" ] && [ ! -L "$token_file" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$token_file")" = "$expected_uid:$expected_gid:400" ] \
      || production_negative 'existing Message MCP token source is not a protected regular file'
    return 0
  fi
  [ "$env_count" -eq 0 ] && [ "$manifest_count" -eq 0 ] \
    || production_negative 'legacy Message MCP token binding is partial or duplicated'
  [ ! -e "$token_file" ] && [ ! -L "$token_file" ] \
    || production_negative 'legacy Message MCP token source appeared before its binding migration'

  verify_original_controls() {
    [ "$(stat -c '%d:%i:%u:%g:%a' -- "$production_run" 2>/dev/null || true)" = "$run_identity" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$production_env" 2>/dev/null || true)" = "$env_identity" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$production_manifest" 2>/dev/null || true)" = "$manifest_identity" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$production_receipt" 2>/dev/null || true)" = "$receipt_identity" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$production_env" 2>/dev/null || true)" = "$expected_uid:$expected_gid:400" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$production_manifest" 2>/dev/null || true)" = "$expected_uid:$expected_gid:400" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$production_receipt" 2>/dev/null || true)" = "$expected_uid:$expected_gid:400" ] \
      && [ "$(sha256sum -- "$production_env" 2>/dev/null | awk '{print $1}')" = "$env_sha256" ] \
      && [ "$(sha256sum -- "$production_manifest" 2>/dev/null | awk '{print $1}')" = "$manifest_sha256" ] \
      && [ "$(sha256sum -- "$production_receipt" 2>/dev/null | awk '{print $1}')" = "$receipt_sha256" ] \
      && [ ! -e "$token_file" ] && [ ! -L "$token_file" ]
  }

  verify_backup() {
    local file=$1 identity=$2 digest=$3
    [ -f "$file" ] && [ ! -L "$file" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$file")" = "$identity" ] \
      && [ "$(stat -c '%u:%g:%a' -- "$file")" = "$expected_uid:$expected_gid:400" ] \
      && [ "$(sha256sum -- "$file" | awk '{print $1}')" = "$digest" ]
  }

  transaction=$(mktemp -d "$production_run/.message-mcp-binding.XXXXXX") \
    || production_die 'cannot create Message MCP token migration transaction'
  chmod 0700 -- "$transaction"
  chown "$expected_uid:$expected_gid" -- "$transaction"
  transaction_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$transaction")
  candidate_env=$transaction/env.new
  candidate_manifest=$transaction/manifest.new
  candidate_receipt=$transaction/receipt.new
  candidate_token=$transaction/token.new
  backup_env=$transaction/env.old
  backup_manifest=$transaction/manifest.old
  backup_receipt=$transaction/receipt.old

  migration_finish() {
    local status=$? rollback_status=0
    trap - EXIT
    if [ "$committed" != true ]; then
      if [ "$receipt_swapped" = true ]; then
        [ "$(stat -c '%d:%i:%u' -- "$production_receipt" 2>/dev/null || true)" = "$candidate_receipt_identity" ] \
          && verify_backup "$backup_receipt" "$receipt_identity" "$receipt_sha256" \
          && mv -f -- "$backup_receipt" "$production_receipt" || rollback_status=1
      fi
      if [ "$manifest_swapped" = true ]; then
        [ "$(stat -c '%d:%i:%u' -- "$production_manifest" 2>/dev/null || true)" = "$candidate_manifest_identity" ] \
          && verify_backup "$backup_manifest" "$manifest_identity" "$manifest_sha256" \
          && mv -f -- "$backup_manifest" "$production_manifest" || rollback_status=1
      fi
      if [ "$env_swapped" = true ]; then
        [ "$(stat -c '%d:%i:%u' -- "$production_env" 2>/dev/null || true)" = "$candidate_env_identity" ] \
          && verify_backup "$backup_env" "$env_identity" "$env_sha256" \
          && mv -f -- "$backup_env" "$production_env" || rollback_status=1
      fi
      if [ "$token_swapped" = true ]; then
        [ "$(stat -c '%d:%i:%u:%g:%a' -- "$token_file" 2>/dev/null || true)" = "$candidate_token_identity" ] \
          && rm -f -- "$token_file" || rollback_status=1
      fi
    fi
    if [ -d "$transaction" ] && [ ! -L "$transaction" ] \
        && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$transaction")" = "$transaction_identity" ]; then
      rm -f -- "$candidate_env" "$candidate_manifest" "$candidate_receipt" "$candidate_token" \
        "$backup_env" "$backup_manifest" "$backup_receipt" || rollback_status=1
      rmdir -- "$transaction" || rollback_status=1
    else
      rollback_status=1
    fi
    [ "$rollback_status" -eq 0 ] || status=1
    case "$status" in 0|3) ;; *) status=1 ;; esac
    exit "$status"
  }
  trap migration_finish EXIT

  awk -v path="$token_file" '{print} END {print "DIREXTALK_MESSAGE_MCP_TOKEN_FILE=" path}' \
    "$production_env" >"$candidate_env" \
    || production_die 'cannot render migrated runtime environment'
  chmod 0400 -- "$candidate_env"
  chown "$expected_uid:$expected_gid" -- "$candidate_env"
  awk -v path="$token_file" '{print} END {print "message_mcp_token_path=" path}' \
    "$production_manifest" >"$candidate_manifest" \
    || production_die 'cannot render migrated runtime manifest'
  chmod 0400 -- "$candidate_manifest"
  chown "$expected_uid:$expected_gid" -- "$candidate_manifest"
  : >"$candidate_token"
  chmod 0400 -- "$candidate_token"
  chown "$expected_uid:$expected_gid" -- "$candidate_token"
  candidate_env_identity=$(stat -c '%d:%i:%u' -- "$candidate_env")
  candidate_manifest_identity=$(stat -c '%d:%i:%u' -- "$candidate_manifest")
  candidate_env_sha256=$(sha256sum -- "$candidate_env" | awk '{print $1}')
  candidate_manifest_sha256=$(sha256sum -- "$candidate_manifest" | awk '{print $1}')
  awk -F= -v env_identity="$candidate_env_identity" -v manifest_identity="$candidate_manifest_identity" \
      -v env_sha256="$candidate_env_sha256" -v manifest_sha256="$candidate_manifest_sha256" '
    $1 == "control.env_identity" {$0=$1 "=" env_identity; env_seen++}
    $1 == "control.manifest_identity" {$0=$1 "=" manifest_identity; manifest_seen++}
    $1 == "control.env_sha256" {$0=$1 "=" env_sha256; env_sha_seen++}
    $1 == "control.manifest_sha256" {$0=$1 "=" manifest_sha256; manifest_sha_seen++}
    {print}
    END {if (env_seen != 1 || manifest_seen != 1 || env_sha_seen != 1 || manifest_sha_seen != 1) exit 1}
  ' "$production_receipt" >"$candidate_receipt" \
    || production_die 'cannot render migrated cleanup receipt'
  chmod 0400 -- "$candidate_receipt"
  chown "$expected_uid:$expected_gid" -- "$candidate_receipt"
  candidate_receipt_identity=$(stat -c '%d:%i:%u' -- "$candidate_receipt")
  candidate_receipt_sha256=$(sha256sum -- "$candidate_receipt" | awk '{print $1}')
  candidate_token_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$candidate_token")

  verify_original_controls || production_die 'receipt-bound runtime controls changed before Message MCP token migration backup'
  ln -- "$production_env" "$backup_env" || production_die 'cannot retain the original runtime environment for migration rollback'
  verify_original_controls || production_die 'receipt-bound runtime controls changed before Message MCP token manifest backup'
  verify_backup "$backup_env" "$env_identity" "$env_sha256" \
    || production_die 'runtime environment migration backup differs from the receipt-bound original'
  ln -- "$production_manifest" "$backup_manifest" || production_die 'cannot retain the original runtime manifest for migration rollback'
  verify_original_controls || production_die 'receipt-bound runtime controls changed before Message MCP token receipt backup'
  verify_backup "$backup_env" "$env_identity" "$env_sha256" \
    && verify_backup "$backup_manifest" "$manifest_identity" "$manifest_sha256" \
    || production_die 'runtime migration backups differ from the receipt-bound originals'
  ln -- "$production_receipt" "$backup_receipt" || production_die 'cannot retain the original cleanup receipt for migration rollback'

  verify_original_controls \
    && verify_backup "$backup_env" "$env_identity" "$env_sha256" \
    && verify_backup "$backup_manifest" "$manifest_identity" "$manifest_sha256" \
    && verify_backup "$backup_receipt" "$receipt_identity" "$receipt_sha256" \
    && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$candidate_token")" = "$candidate_token_identity" ] \
    || production_die 'Message MCP token migration authorization changed before token source commit'
  mv -- "$candidate_token" "$token_file" || production_die 'Message MCP token source atomic commit failed'
  token_swapped=true

  verify_original_controls_without_token() {
    [ "$(stat -c '%d:%i:%u:%g:%a' -- "$production_run" 2>/dev/null || true)" = "$run_identity" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$production_env" 2>/dev/null || true)" = "$env_identity" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$production_manifest" 2>/dev/null || true)" = "$manifest_identity" ] \
      && [ "$(stat -c '%d:%i:%u' -- "$production_receipt" 2>/dev/null || true)" = "$receipt_identity" ] \
      && [ "$(sha256sum -- "$production_env" 2>/dev/null | awk '{print $1}')" = "$env_sha256" ] \
      && [ "$(sha256sum -- "$production_manifest" 2>/dev/null | awk '{print $1}')" = "$manifest_sha256" ] \
      && [ "$(sha256sum -- "$production_receipt" 2>/dev/null | awk '{print $1}')" = "$receipt_sha256" ] \
      && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$token_file" 2>/dev/null || true)" = "$candidate_token_identity" ]
  }
  verify_original_controls_without_token \
    && verify_backup "$backup_env" "$env_identity" "$env_sha256" \
    && verify_backup "$backup_manifest" "$manifest_identity" "$manifest_sha256" \
    && verify_backup "$backup_receipt" "$receipt_identity" "$receipt_sha256" \
    && [ "$(stat -c '%d:%i:%u' -- "$candidate_env")" = "$candidate_env_identity" ] \
    && [ "$(sha256sum -- "$candidate_env" | awk '{print $1}')" = "$candidate_env_sha256" ] \
    || production_die 'receipt-bound controls changed before runtime environment migration commit'
  mv -f -- "$candidate_env" "$production_env" || production_die 'runtime environment atomic migration failed'
  env_swapped=true

  [ "$(stat -c '%d:%i:%u:%g:%a' -- "$production_run")" = "$run_identity" ] \
    && [ "$(stat -c '%d:%i:%u' -- "$production_env")" = "$candidate_env_identity" ] \
    && [ "$(sha256sum -- "$production_env" | awk '{print $1}')" = "$candidate_env_sha256" ] \
    && verify_backup "$backup_env" "$env_identity" "$env_sha256" \
    && verify_backup "$backup_manifest" "$manifest_identity" "$manifest_sha256" \
    && verify_backup "$backup_receipt" "$receipt_identity" "$receipt_sha256" \
    && [ "$(stat -c '%d:%i:%u' -- "$production_manifest")" = "$manifest_identity" ] \
    && [ "$(sha256sum -- "$production_manifest" | awk '{print $1}')" = "$manifest_sha256" ] \
    && [ "$(stat -c '%d:%i:%u' -- "$production_receipt")" = "$receipt_identity" ] \
    && [ "$(sha256sum -- "$production_receipt" | awk '{print $1}')" = "$receipt_sha256" ] \
    && [ "$(stat -c '%d:%i:%u' -- "$candidate_manifest")" = "$candidate_manifest_identity" ] \
    && [ "$(sha256sum -- "$candidate_manifest" | awk '{print $1}')" = "$candidate_manifest_sha256" ] \
    || production_die 'receipt-bound controls changed before runtime manifest migration commit'
  mv -f -- "$candidate_manifest" "$production_manifest" || production_die 'runtime manifest atomic migration failed'
  manifest_swapped=true

  [ "$(stat -c '%d:%i:%u:%g:%a' -- "$production_run")" = "$run_identity" ] \
    && [ "$(stat -c '%d:%i:%u' -- "$production_env")" = "$candidate_env_identity" ] \
    && [ "$(sha256sum -- "$production_env" | awk '{print $1}')" = "$candidate_env_sha256" ] \
    && [ "$(stat -c '%d:%i:%u' -- "$production_manifest")" = "$candidate_manifest_identity" ] \
    && [ "$(sha256sum -- "$production_manifest" | awk '{print $1}')" = "$candidate_manifest_sha256" ] \
    && verify_backup "$backup_env" "$env_identity" "$env_sha256" \
    && verify_backup "$backup_manifest" "$manifest_identity" "$manifest_sha256" \
    && verify_backup "$backup_receipt" "$receipt_identity" "$receipt_sha256" \
    && [ "$(stat -c '%d:%i:%u' -- "$production_receipt")" = "$receipt_identity" ] \
    && [ "$(sha256sum -- "$production_receipt" | awk '{print $1}')" = "$receipt_sha256" ] \
    && [ "$(stat -c '%d:%i:%u' -- "$candidate_receipt")" = "$candidate_receipt_identity" ] \
    && [ "$(sha256sum -- "$candidate_receipt" | awk '{print $1}')" = "$candidate_receipt_sha256" ] \
    || production_die 'receipt-bound controls changed before cleanup receipt migration commit'
  mv -f -- "$candidate_receipt" "$production_receipt" || production_die 'cleanup receipt atomic migration failed'
  receipt_swapped=true

  [ "$(stat -c '%d:%i:%u' -- "$production_receipt")" = "$candidate_receipt_identity" ] \
    && [ "$(sha256sum -- "$production_receipt" | awk '{print $1}')" = "$candidate_receipt_sha256" ] \
    && [ "$(production_read_pair "$production_receipt" control.env_identity)" = "$candidate_env_identity" ] \
    && [ "$(production_read_pair "$production_receipt" control.manifest_identity)" = "$candidate_manifest_identity" ] \
    && [ "$(production_read_pair "$production_receipt" control.env_sha256)" = "$candidate_env_sha256" ] \
    && [ "$(production_read_pair "$production_receipt" control.manifest_sha256)" = "$candidate_manifest_sha256" ] \
    && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$token_file")" = "$candidate_token_identity" ] \
    || production_die 'Message MCP token migration postcondition failed'
  committed=true
)

production_bind_runtime() {
  production_base=${DIREXTALK_PRODUCTION_BASE:-/var/dirextalk-message-server}
  production_split=$production_base/deploy/split-agent
  production_run=$production_base/split
  production_env=$production_run/.env
  production_manifest=$production_run/.manifest
  production_receipt=$production_run/.cleanup-receipt
  production_edge_env=$production_base/edge.env
  production_edge_receipt=$production_base/edge-bootstrap-receipt
  [ -d "$production_base" ] && [ ! -L "$production_base" ] || production_die 'production base is unavailable'
  [ -d "$production_run" ] && [ ! -L "$production_run" ] || production_die 'split runtime directory is unavailable'
  production_require_control_file "$production_env" 400
  production_require_control_file "$production_manifest" 400
  production_require_control_file "$production_receipt" 400
  production_require_control_file "$production_edge_env" 400
  production_require_control_file "$production_edge_receipt" 400
  [ -x "$production_split/scripts/restart-agent-local.sh" ] || production_die 'canonical existing-runtime restart wrapper is unavailable'
  [ -x "$production_split/scripts/cleanup-local.sh" ] || production_die 'canonical split cleanup is unavailable'
  grep -Fqx '# dirextalk-split-cleanup-receipt-v1' "$production_receipt" || production_die 'cleanup receipt version is unsupported'
  [ "$(production_read_pair "$production_receipt" state)" = complete ] || production_negative 'split runtime cleanup receipt is not complete'
  [ "$(production_read_pair "$production_manifest" compose_mode)" = production ] || production_negative 'existing-runtime operations require a production stack'
  [ "$(production_read_pair "$production_receipt" control.env_identity)" = "$(stat -c '%d:%i:%u' "$production_env")" ] || production_die 'runtime environment identity differs from receipt'
  [ "$(production_read_pair "$production_receipt" control.manifest_identity)" = "$(stat -c '%d:%i:%u' "$production_manifest")" ] || production_die 'runtime manifest identity differs from receipt'
  [ "$(production_read_pair "$production_receipt" control.env_sha256)" = "$(sha256sum "$production_env" | awk '{print $1}')" ] || production_die 'runtime environment digest differs from receipt'
  [ "$(production_read_pair "$production_receipt" control.manifest_sha256)" = "$(sha256sum "$production_manifest" | awk '{print $1}')" ] || production_die 'runtime manifest digest differs from receipt'
  production_stack=$(production_read_pair "$production_manifest" stack_name)
  printf '%s\n' "$production_stack" | grep -Eq '^d-[a-z2-7]{26}$' || production_die 'split stack identity is invalid'
  [ "$(production_read_pair "$production_receipt" stack_name)" = "$production_stack" ] || production_die 'runtime receipt stack differs from manifest'
}

production_bind_completed_runtime() {
  production_base=${DIREXTALK_PRODUCTION_BASE:-/var/dirextalk-message-server}
  if [ ! -e "$production_base/.split-deploy-done" ] && [ ! -L "$production_base/.split-deploy-done" ]; then
    production_negative 'completed split runtime is unavailable'
  fi
  [ -f "$production_base/.split-deploy-done" ] && [ ! -L "$production_base/.split-deploy-done" ] \
    || production_die 'completed split runtime marker is invalid'
  production_bind_runtime
}

production_verify_message_server() {
  local container_count index id name service project found=false expected_image inspection
  local actual_id raw_name actual_name actual_project actual_service actual_image state health
  container_count=$(production_read_pair "$production_receipt" container.count)
  printf '%s\n' "$container_count" | grep -Eq '^[1-9][0-9]{0,3}$' \
    || production_die 'cleanup receipt container count is invalid'
  for ((index = 0; index < container_count; index++)); do
    service=$(production_read_pair "$production_receipt" "container.$index.service")
    [ "$service" = message-server ] || continue
    [ "$found" = false ] || production_die 'cleanup receipt contains duplicate message-server containers'
    found=true
    id=$(production_read_pair "$production_receipt" "container.$index.id")
    name=$(production_read_pair "$production_receipt" "container.$index.name")
    project=$(production_read_pair "$production_receipt" "container.$index.project")
  done
  [ "$found" = true ] || production_die 'cleanup receipt lacks the message-server container'
  printf '%s\n' "$id" | grep -Eq '^[0-9a-f]{64}$' || production_die 'message-server receipt identity is invalid'
  printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || production_die 'message-server receipt name is invalid'
  [ "$project" = "$production_stack" ] || production_die 'message-server receipt project differs from stack'
  expected_image=$(production_read_pair "$production_env" DIREXTALK_MESSAGE_SERVER_IMAGE)
  if inspection=$(docker inspect --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null); then
    :
  else
    production_die 'exact receipt-bound message-server container is unavailable'
  fi
  IFS='|' read -r actual_id raw_name actual_project actual_service actual_image state health <<<"$inspection"
  actual_name=${raw_name#/}
  [ "$actual_id" = "$id" ] || production_die 'message-server container ID changed'
  [ "$actual_name" = "$name" ] || production_die 'message-server container name changed'
  [ "$actual_project" = "$production_stack" ] && [ "$actual_service" = message-server ] \
    || production_die 'message-server Compose identity changed'
  [ "$actual_image" = "$expected_image" ] || production_die 'message-server image differs from the protected runtime'
  [ "$state" = running ] && [ "$health" = healthy ] || production_die 'message-server is not healthy'
  production_message_id=$id
}

production_verify_edge() {
  local identity actual_id project service image network state health
  grep -Fqx '# dirextalk-edge-bootstrap-receipt-v1' "$production_edge_receipt" || production_die 'edge receipt version is unsupported'
  [ "$(production_read_pair "$production_edge_receipt" stack)" = "$production_stack" ] || production_die 'edge receipt stack differs'
  production_edge_id=$(production_read_pair "$production_edge_receipt" container_id)
  printf '%s\n' "$production_edge_id" | grep -Eq '^[0-9a-f]{64}$' || production_die 'edge container identity is invalid'
  production_edge_image=$(production_read_pair "$production_edge_receipt" image)
  production_edge_network=$(production_read_pair "$production_edge_receipt" network)
  [ "$production_edge_image" = "$(production_read_pair "$production_edge_env" DIREXTALK_CADDY_IMAGE_IMMUTABLE)" ] || production_die 'edge image differs from protected environment'
  [ "$production_edge_network" = "${production_stack}-message-public" ] || production_die 'edge network is outside the split stack'
  identity=$(docker inspect --format '{{.Id}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$production_edge_id" 2>/dev/null) || production_die 'recorded edge container is unavailable'
  IFS='|' read -r actual_id project service image state health <<<"$identity"
  network=$(docker inspect --format "{{if index .NetworkSettings.Networks \"$production_edge_network\"}}true{{end}}" "$production_edge_id" 2>/dev/null) || production_die 'recorded edge network inspection failed'
  [ "$actual_id" = "$production_edge_id" ] || production_die 'edge container identity changed'
  [ "$project" = "${production_stack}-edge" ] && [ "$service" = caddy ] || production_die 'edge Compose identity changed'
  [ "$image" = "$production_edge_image" ] || production_die 'edge container image differs from receipt'
  [ "$network" = true ] || production_die 'edge container network differs from receipt'
  [ "$state" = running ] && [ "$health" = healthy ] || production_die 'edge container is not healthy'
}
