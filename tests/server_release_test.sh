#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export DIREXTALK_WORKDIR="$tmp/work"
export RUN_ID=production-split-release-test
export AWS_DEFAULT_REGION=ap-east-1
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null
warn() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/server-release.sh"

server_release_validate_pin
server_release_prepare_state
message_digest=${DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE##*@}
json_test_check "$STATE_JSON" "data.server_release.source === 'production_split' && data.server_release.version === '$DIREXTALK_MESSAGE_SERVER_VERSION' && data.server_release.image === 'docker.io/dirextalk/message-server:$DIREXTALK_MESSAGE_SERVER_VERSION' && data.server_release.image_ref === '$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE' && data.server_release.digest === '$message_digest' && data.server_release.manifest_digest === data.server_release.digest"
json_test_check "$STATE_JSON" "data.split_release.message_source_revision === '$DIREXTALK_MESSAGE_SOURCE_REVISION' && data.split_release.split_source_revision === '$DIREXTALK_SPLIT_SOURCE_REVISION' && data.split_release.agent_version === '$DIREXTALK_AGENT_VERSION' && data.split_release.agent_image === '$DIREXTALK_AGENT_IMAGE_IMMUTABLE' && data.split_release.agent_source_revision === '$DIREXTALK_AGENT_SOURCE_REVISION' && data.split_release.postgres_image === '$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE' && data.split_release.caddy_image === '$DIREXTALK_CADDY_IMAGE_IMMUTABLE' && data.split_release.coturn_image === '$DIREXTALK_COTURN_IMAGE_IMMUTABLE'"
[ "$(state_get split_release.release_catalog_origin)" = https://imadmin.dirextalk.ai ]

[ "$DIREXTALK_AGENT_VERSION" = "$(state_get split_release.agent_version)" ]
[ "$DIREXTALK_AGENT_IMAGE_IMMUTABLE" = "$(state_get split_release.agent_image)" ]
[ "$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" = docker.io/pgvector/pgvector:pg18@sha256:691673308c99d2161ba298736f3147f1f22d79de2fb7ec93ae9b4afcab870b62 ]
[ "$DIREXTALK_POSTGRES_IMAGE_IMMUTABLE" = "$(state_get split_release.postgres_image)" ]
[ "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" = docker.io/library/caddy@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9 ]
[ "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" = docker.io/coturn/coturn:4.6.3-alpine@sha256:e2bca2f79a4269d7240de5872ab60a9305013ad37296d2acf14f9510874346be ]
[ "$DIREXTALK_MESSAGE_SOURCE_REVISION" = "$(state_get split_release.message_source_revision)" ]
[ "$DIREXTALK_SPLIT_SOURCE_REVISION" = "$(state_get split_release.split_source_revision)" ]
[ "$DIREXTALK_AGENT_SOURCE_REVISION" = "$(state_get split_release.agent_source_revision)" ]
[ "$DIREXTALK_RELEASE_CATALOG_ORIGIN" = https://imadmin.dirextalk.ai ]

res_set instance_id i-existing
server_release_prepare_state
old_split_revision=1111111111111111111111111111111111111111
state_set split_release.split_source_revision "$old_split_revision"
server_release_prepare_state
[ "$(state_get split_release.split_source_revision)" = "$old_split_revision" ]
server_release_advance_split_state "$old_split_revision"
[ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ]
state_set split_release.split_source_revision "$old_split_revision"
state_set split_release.agent_version v9.9.9
server_release_prepare_state
[ "$(state_get split_release.agent_version)" = v9.9.9 ] || {
  echo "existing infrastructure lost its recorded Agent release" >&2
  exit 1
}
state_set split_release.agent_version "$DIREXTALK_AGENT_VERSION"
if server_release_advance_split_state "$old_split_revision"; then
  :
else
  echo 'strict local split source advance rejected unchanged business pins' >&2
  exit 1
fi
state_set split_release.split_source_revision "$old_split_revision"
state_set split_release.message_version v8.8.8
state_set split_release.agent_version v9.9.9
recorded_message_image=$(state_get split_release.message_image)
recorded_agent_image=$(state_get split_release.agent_image)
DIREXTALK_MESSAGE_SERVER_VERSION=v7.7.7
DIREXTALK_AGENT_VERSION=v6.6.6
DIREXTALK_SPLIT_SOURCE_REVISION=2222222222222222222222222222222222222222
server_release_advance_split_state "$old_split_revision"
[ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ]
[ "$(state_get split_release.message_version)" = v8.8.8 ]
[ "$(state_get split_release.agent_version)" = v9.9.9 ]
[ "$(state_get split_release.message_image)" = "$recorded_message_image" ]
[ "$(state_get split_release.agent_image)" = "$recorded_agent_image" ]
different_digest=sha256:$(printf '9%.0s' {1..64})
state_set server_release.version v9.9.9
state_set server_release.image docker.io/dirextalk/message-server:v9.9.9
state_set server_release.digest "$different_digest"
state_set server_release.image_ref "docker.io/dirextalk/message-server@$different_digest"
state_set server_release.manifest_digest "$different_digest"
server_release_prepare_state
[ "$(state_get server_release.version)" = v9.9.9 ] || {
  echo "existing infrastructure lost its recorded message-server release" >&2
  exit 1
}

for variable in MESSAGE_SERVER_IMAGE DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE; do
  state_set_raw server_release '{}'
  res_set instance_id ''
  if env "$variable=forbidden" bash -c '
    set -euo pipefail
    warn() { printf "%s\n" "$*" >&2; }
    source "$1/scripts/lib/json.sh"
    source "$1/scripts/lib/state.sh"
    source "$1/scripts/lib/server-release.sh"
    server_release_validate_override
  ' bash "$ROOT" 2>"$tmp/override.err"; then
    echo "$variable override was accepted" >&2
    exit 1
  fi
done

echo "production split release pin ok"
