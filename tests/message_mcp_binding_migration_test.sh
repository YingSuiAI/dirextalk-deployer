#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stack=d-abcdefghijklmnopqrstuvwxyz

write_legacy_runtime() {
  local fixture=$1 env_identity manifest_identity env_sha256 manifest_sha256
  mkdir -p "$fixture/base/split" "$fixture/ops"
  chmod 0700 "$fixture/base/split"
  cp "$ROOT/scripts/cloud-init/split/production-ops-common.sh" \
    "$ROOT/scripts/cloud-init/split/migrate-message-mcp-token-binding.sh" "$fixture/ops/"
  cat >"$fixture/base/split/.env" <<EOF
DIREXTALK_SPLIT_STACK_NAME=$stack
DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.62
EOF
  cat >"$fixture/base/split/.manifest" <<EOF
# dirextalk-split-manifest-v1
stack_name=$stack
compose_mode=production
EOF
  chmod 0400 "$fixture/base/split/.env" "$fixture/base/split/.manifest"
  env_identity=$(stat -c '%d:%i:%u' "$fixture/base/split/.env")
  manifest_identity=$(stat -c '%d:%i:%u' "$fixture/base/split/.manifest")
  env_sha256=$(sha256sum "$fixture/base/split/.env" | awk '{print $1}')
  manifest_sha256=$(sha256sum "$fixture/base/split/.manifest" | awk '{print $1}')
  cat >"$fixture/base/split/.cleanup-receipt" <<EOF
# dirextalk-split-cleanup-receipt-v1
stack_name=$stack
state=complete
control.env_identity=$env_identity
control.manifest_identity=$manifest_identity
control.env_sha256=$env_sha256
control.manifest_sha256=$manifest_sha256
container.count=1
container.0.id=$(printf 'd%.0s' {1..64})
container.0.name=${stack}-message-server-1
container.0.service=message-server
container.0.project=$stack
EOF
  chmod 0400 "$fixture/base/split/.cleanup-receipt"
  chmod 0755 "$fixture/ops/"*.sh
  printf 'receipt-bound-message-server\n' >"$fixture/message-server.identity"
}

run_migration() {
  DIREXTALK_PRODUCTION_BASE="$1/base" \
    bash "$1/ops/migrate-message-mcp-token-binding.sh" >"$1/output" 2>&1
}

control_snapshot() {
  local fixture=$1
  for file in .env .manifest .cleanup-receipt; do
    stat -c "$file %d:%i:%u:%g:%a" "$fixture/base/split/$file"
    sha256sum "$fixture/base/split/$file"
  done
  if [ -e "$fixture/base/split/message-mcp-token" ] || [ -L "$fixture/base/split/message-mcp-token" ]; then
    stat -c 'message-mcp-token %d:%i:%u:%g:%a:%s' "$fixture/base/split/message-mcp-token"
    sha256sum "$fixture/base/split/message-mcp-token"
  else
    printf 'message-mcp-token absent\n'
  fi
  sha256sum "$fixture/message-server.identity"
}

success=$tmp/success
write_legacy_runtime "$success"
message_identity_before=$(sha256sum "$success/message-server.identity")
run_migration "$success"
token_path=$success/base/split/message-mcp-token
[ "$(grep -c '^DIREXTALK_MESSAGE_MCP_TOKEN_FILE=' "$success/base/split/.env")" -eq 1 ]
[ "$(grep -c '^message_mcp_token_path=' "$success/base/split/.manifest")" -eq 1 ]
grep -Fqx "DIREXTALK_MESSAGE_MCP_TOKEN_FILE=$token_path" "$success/base/split/.env"
grep -Fqx "message_mcp_token_path=$token_path" "$success/base/split/.manifest"
[ -f "$token_path" ] && [ ! -L "$token_path" ] && [ ! -s "$token_path" ]
[ "$(stat -c '%u:%g:%a' "$token_path")" = "$(id -u):$(id -g):400" ]
[ "$(awk -F= '$1 == "control.env_identity" {print $2}' "$success/base/split/.cleanup-receipt")" \
  = "$(stat -c '%d:%i:%u' "$success/base/split/.env")" ]
[ "$(awk -F= '$1 == "control.manifest_identity" {print $2}' "$success/base/split/.cleanup-receipt")" \
  = "$(stat -c '%d:%i:%u' "$success/base/split/.manifest")" ]
[ "$(awk -F= '$1 == "control.env_sha256" {print $2}' "$success/base/split/.cleanup-receipt")" \
  = "$(sha256sum "$success/base/split/.env" | awk '{print $1}')" ]
[ "$(awk -F= '$1 == "control.manifest_sha256" {print $2}' "$success/base/split/.cleanup-receipt")" \
  = "$(sha256sum "$success/base/split/.manifest" | awk '{print $1}')" ]
[ "$message_identity_before" = "$(sha256sum "$success/message-server.identity")" ]
if find "$success/base/split" -maxdepth 1 -name '.message-mcp-binding.*' | grep -q .; then
  echo 'successful migration retained its transaction workspace' >&2
  exit 1
fi

canonical_before=$(control_snapshot "$success")
run_migration "$success"
[ "$canonical_before" = "$(control_snapshot "$success")" ]

mismatch=$tmp/mismatch
write_legacy_runtime "$mismatch"
sed -i 's/^control.env_identity=.*/control.env_identity=1:2:3/' "$mismatch/base/split/.cleanup-receipt"
mismatch_before=$(control_snapshot "$mismatch")
if run_migration "$mismatch"; then
  echo 'migration accepted a cleanup receipt identity mismatch' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ "$mismatch_before" = "$(control_snapshot "$mismatch")" ]
if find "$mismatch/base/split" -maxdepth 1 -name '.message-mcp-binding.*' | grep -q .; then
  echo 'receipt mismatch created a migration transaction' >&2
  exit 1
fi

partial=$tmp/partial
write_legacy_runtime "$partial"
chmod 0600 "$partial/base/split/.env"
printf 'DIREXTALK_MESSAGE_MCP_TOKEN_FILE=%s\n' "$partial/base/split/message-mcp-token" \
  >>"$partial/base/split/.env"
chmod 0400 "$partial/base/split/.env"
partial_env_identity=$(stat -c '%d:%i:%u' "$partial/base/split/.env")
partial_env_sha=$(sha256sum "$partial/base/split/.env" | awk '{print $1}')
sed -i \
  -e "s/^control.env_identity=.*/control.env_identity=$partial_env_identity/" \
  -e "s/^control.env_sha256=.*/control.env_sha256=$partial_env_sha/" \
  "$partial/base/split/.cleanup-receipt"
partial_before=$(control_snapshot "$partial")
if run_migration "$partial"; then
  echo 'migration accepted a partial legacy Message MCP binding' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
[ "$partial_before" = "$(control_snapshot "$partial")" ]

echo 'message MCP binding migration ok'
