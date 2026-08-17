#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s OUTPUT_DIR MESSAGE_SERVER_CONTAINER_ID\n' "${0##*/}" >&2
  exit 2
}

die() {
  printf 'message MCP token refresh: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 2 ] || usage
out_input=$1
message_container_id=$2
case "$out_input" in
  /*) out=$(readlink -m -- "$out_input") ;;
  *) out=$(readlink -m -- "$(pwd -P)/$out_input") ;;
esac
[ "$out" != / ] || die 'refusing to use the filesystem root'
[ -d "$out" ] && [ ! -L "$out" ] || die 'output directory must be a regular non-symlink directory'
[ "$(stat -c '%a' -- "$out")" = 700 ] || die 'output directory must be mode 0700'
current_uid=$(id -u) || die 'cannot determine current UID'
current_gid=$(id -g) || die 'cannot determine current GID'
[ "$(stat -c '%u' -- "$out")" = "$current_uid" ] || die 'output directory must be owned by the refresh user'
printf '%s\n' "$message_container_id" | grep -Eq '^[0-9a-f]{64}$' \
  || die 'message-server container ID must be a full immutable ID'

env_file=$out/.env
manifest=$out/.manifest
command -v docker >/dev/null 2>&1 || die 'docker is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'

read_pair() {
  local file=$1 key=$2 value count
  count=$(awk -F= -v wanted="$key" \
    '$0 !~ /^[[:space:]]*#/ && index($0, wanted "=") == 1 { count++ } END { print count + 0 }' \
    "$file")
  [ "$count" -eq 1 ] || die "$file must contain exactly one $key entry"
  value=$(awk -F= -v wanted="$key" \
    '$0 !~ /^[[:space:]]*#/ && index($0, wanted "=") == 1 { print substr($0, length(wanted) + 2); exit }' \
    "$file")
  [ -n "$value" ] || die "$file has an empty $key entry"
  printf '%s' "$value"
}

for control_file in "$env_file" "$manifest"; do
  [ -f "$control_file" ] && [ ! -L "$control_file" ] || die "missing protected control file: $control_file"
  [ "$(stat -c '%a:%u' -- "$control_file")" = "400:$current_uid" ] \
    || die "control file must be current-user-owned mode 0400: $control_file"
done
env_identity=$(stat -c '%d:%i:%u' -- "$env_file")
manifest_identity=$(stat -c '%d:%i:%u' -- "$manifest")
env_digest=$(sha256sum -- "$env_file" | awk '{print $1}')
manifest_digest=$(sha256sum -- "$manifest" | awk '{print $1}')

verify_controls() {
  [ -f "$env_file" ] && [ ! -L "$env_file" ] || die '.env was replaced during token refresh'
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die '.manifest was replaced during token refresh'
  [ "$(stat -c '%d:%i:%u:%a' -- "$env_file")" = "$env_identity:400" ] \
    || die '.env identity or mode changed during token refresh'
  [ "$(stat -c '%d:%i:%u:%a' -- "$manifest")" = "$manifest_identity:400" ] \
    || die '.manifest identity or mode changed during token refresh'
  [ "$(sha256sum -- "$env_file" | awk '{print $1}')" = "$env_digest" ] \
    || die '.env contents changed during token refresh'
  [ "$(sha256sum -- "$manifest" | awk '{print $1}')" = "$manifest_digest" ] \
    || die '.manifest contents changed during token refresh'
}

stack_name=$(read_pair "$manifest" stack_name)
[ "$stack_name" = "$(read_pair "$env_file" DIREXTALK_SPLIT_STACK_NAME)" ] \
  || die '.env stack identity differs from manifest'
printf '%s\n' "$stack_name" | grep -Eq '^d-[a-z2-7]{26}$' || die 'stack identity is invalid'
expected_image=$(read_pair "$env_file" DIREXTALK_MESSAGE_SERVER_IMAGE)
token_file=$(read_pair "$env_file" DIREXTALK_MESSAGE_MCP_TOKEN_FILE)
[ "$token_file" = "$(read_pair "$manifest" message_mcp_token_path)" ] \
  || die 'message MCP token path differs from manifest'
[ "$token_file" = "$out/message-mcp-token" ] \
  || die 'message MCP token path is outside the protected output directory'
[ -f "$token_file" ] && [ ! -L "$token_file" ] || die 'message MCP token source is missing or symlinked'
[ "$(stat -c '%a:%u:%g' -- "$token_file")" = "400:$current_uid:$current_gid" ] \
  || die 'message MCP token source must be refresh-user-owned mode 0400'
token_file_identity=$(stat -c '%d:%i:%u:%g' -- "$token_file")
token_file_digest=$(sha256sum -- "$token_file" | awk '{print $1}')

verify_message_server() {
  local data actual_id project service image status health
  if data=$(docker inspect "$message_container_id" 2>/dev/null); then
    :
  else
    die 'exact message-server container is unavailable'
  fi
  jq -e 'type == "array" and length == 1' <<<"$data" >/dev/null \
    || die 'message-server inspection returned malformed JSON'
  actual_id=$(jq -r '.[0].Id // empty' <<<"$data")
  project=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$data")
  service=$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty' <<<"$data")
  image=$(jq -r '.[0].Config.Image // empty' <<<"$data")
  status=$(jq -r '.[0].State.Status // empty' <<<"$data")
  health=$(jq -r '.[0].State.Health.Status // empty' <<<"$data")
  [ "$actual_id" = "$message_container_id" ] || die 'message-server container ID changed'
  [ "$project" = "$stack_name" ] || die 'message-server project identity changed'
  [ "$service" = message-server ] || die 'message-server service identity changed'
  [ "$image" = "$expected_image" ] || die 'message-server image identity changed'
  [ "$status" = running ] && [ "$health" = healthy ] || die 'exact message-server is not healthy'
}

umask 077
bootstrap_tmp=$(mktemp "$out/.message-mcp-bootstrap.XXXXXX") || die 'cannot create bootstrap staging file'
token_tmp=$(mktemp "$out/.message-mcp-token.XXXXXX") || {
  rm -f -- "$bootstrap_tmp"
  die 'cannot create token staging file'
}
cleanup() {
  [ -z "${bootstrap_tmp:-}" ] || rm -f -- "$bootstrap_tmp"
  [ -z "${token_tmp:-}" ] || rm -f -- "$token_tmp"
}
trap cleanup EXIT

verify_controls
verify_message_server
if ! docker cp \
    "$message_container_id:/var/dirextalk-message-server/p2p/bootstrap.json" \
    "$bootstrap_tmp" >/dev/null 2>&1; then
  die 'message-server bootstrap is unavailable'
fi
[ -f "$bootstrap_tmp" ] && [ ! -L "$bootstrap_tmp" ] \
  || die 'message-server bootstrap export is not a regular file'
chmod 0400 -- "$bootstrap_tmp" || die 'cannot protect bootstrap staging file'
verify_controls
verify_message_server
if ! jq -j -e '
  if type == "object" and
     (.agent_token | type == "string" and length > 0 and length <= 4096 and
       (contains("\u0000") | not) and (contains("\r") | not) and (contains("\n") | not))
  then .agent_token
  else error("invalid agent token")
  end
' "$bootstrap_tmp" >"$token_tmp" 2>/dev/null; then
  die 'message-server bootstrap has no valid agent token'
fi
[ -s "$token_tmp" ] || die 'materialized message MCP token is empty'
chmod 0400 -- "$token_tmp" || die 'cannot protect token staging file'
[ "$(stat -c '%u:%g' -- "$token_tmp")" = "$current_uid:$current_gid" ] \
  || die 'token staging file owner changed'

# The source path is mutable by design, but only through this atomic rotation.
# Revalidate its original inode and the exact Message Server immediately before
# replacement so a same-name object can never cross the authorization boundary.
verify_controls
verify_message_server
[ -f "$token_file" ] && [ ! -L "$token_file" ] \
  || die 'message MCP token source was replaced before rotation'
[ "$(stat -c '%d:%i:%u:%g:%a' -- "$token_file")" = "$token_file_identity:400" ] \
  || die 'message MCP token source identity changed before rotation'
[ "$(sha256sum -- "$token_file" | awk '{print $1}')" = "$token_file_digest" ] \
  || die 'message MCP token source contents changed before rotation'
mv -f -- "$token_tmp" "$token_file" || die 'cannot atomically publish message MCP token'
token_tmp=
[ -f "$token_file" ] && [ ! -L "$token_file" ] || die 'published message MCP token is not a regular file'
[ "$(stat -c '%a:%u:%g' -- "$token_file")" = "400:$current_uid:$current_gid" ] \
  || die 'published message MCP token protection changed'
[ -s "$token_file" ] || die 'published message MCP token is empty'
verify_controls
verify_message_server
