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
json_test_check "$STATE_JSON" 'data.server_release.source === "production_split" && data.server_release.version === "v1.1.2" && data.server_release.image === "docker.io/dirextalk/message-server:v1.1.2" && data.server_release.image_ref === "docker.io/dirextalk/message-server@sha256:dc7c02c41eeb731be87d37d35e511c34c8c739ed6367c65a174b00347d020775" && data.server_release.digest === "sha256:dc7c02c41eeb731be87d37d35e511c34c8c739ed6367c65a174b00347d020775" && data.server_release.manifest_digest === data.server_release.digest'
json_test_check "$STATE_JSON" 'data.split_release.message_source_revision === "efa72eb0975ce33c60db0faa003eb5e07bdb9d07" && data.split_release.split_source_revision === "f36099ef925a020f00432ab8b97f76fa902b066e" && data.split_release.agent_version === "v1.0.2" && data.split_release.agent_image === "docker.io/dirextalk/agent@sha256:a522e78882a15c33f45e9bafbd770ad7c76e2c9d222b0e66410621c888b0c528" && data.split_release.agent_source_revision === "bd0fd34f9e7812f2c2c0d26f3d332a7befacdc24" && data.split_release.caddy_image === "docker.io/library/caddy@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9" && data.split_release.coturn_image === "docker.io/coturn/coturn:4.6.3-alpine@sha256:e2bca2f79a4269d7240de5872ab60a9305013ad37296d2acf14f9510874346be"'

[ "$DIREXTALK_AGENT_VERSION" = v1.0.2 ]
[ "$DIREXTALK_AGENT_IMAGE_IMMUTABLE" = docker.io/dirextalk/agent@sha256:a522e78882a15c33f45e9bafbd770ad7c76e2c9d222b0e66410621c888b0c528 ]
[ "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" = docker.io/library/caddy@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9 ]
[ "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" = docker.io/coturn/coturn:4.6.3-alpine@sha256:e2bca2f79a4269d7240de5872ab60a9305013ad37296d2acf14f9510874346be ]
[ "$DIREXTALK_MESSAGE_SOURCE_REVISION" = efa72eb0975ce33c60db0faa003eb5e07bdb9d07 ]
[ "$DIREXTALK_SPLIT_SOURCE_REVISION" = f36099ef925a020f00432ab8b97f76fa902b066e ]
[ "$DIREXTALK_AGENT_SOURCE_REVISION" = bd0fd34f9e7812f2c2c0d26f3d332a7befacdc24 ]

res_set instance_id i-existing
server_release_prepare_state
state_set split_release.agent_version v9.9.9
if server_release_prepare_state 2>"$tmp/split-mismatch.err"; then
  echo "existing infrastructure accepted a different Agent release" >&2
  exit 1
fi
grep -q 'different Agent/Caddy/coturn/source pins' "$tmp/split-mismatch.err"
state_set split_release.agent_version v1.0.2
state_set server_release.version v9.9.9
if server_release_prepare_state 2>"$tmp/mismatch.err"; then
  echo "existing infrastructure accepted a different production release" >&2
  exit 1
fi
grep -q 'refusing replacement or compatibility fallback' "$tmp/mismatch.err"

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
