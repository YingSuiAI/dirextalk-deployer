#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

image='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
lightsail_message_image='dirextalk/z3-message-server-20260718:v0.1.0-alpha.20260718.1-0258d0a493ad@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
changed_image='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.2-bbbbbbbbbbbb@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
profiles="$tmp/model-profiles.json"
changed_profiles="$tmp/model-profiles-changed.json"
unsafe_profiles="$tmp/model-profiles-unsafe.json"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"test-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$profiles"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"changed-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","context_window":4096,"max_output_tokens":1024}]}' > "$changed_profiles"
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"unsafe-profile","provider":"openai_compatible","model":"test-model","base_url":"https://api.example.test/v1","secret_ref":"mounted:test-token","api_key":"not-a-real-provider-token"}]}' > "$unsafe_profiles"

test_source=
test_enabled=
test_image_ref=
test_instance_id=
test_profiles_sha256=
test_infrastructure_id=

warn() { :; }
json_build() {
  [ "$1" = object ] || return 1
  shift
  local pair key value first=1
  printf '{'
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    [ "$first" = 1 ] || printf ','
    printf '"%s":"%s"' "$key" "$value"
    first=0
  done
  printf '}'
}
state_get() {
  case "$1" in
    resources.instance_id) printf '%s' "$test_infrastructure_id" ;;
    agent_release.source) printf '%s' "$test_source" ;;
    agent_release.enabled) printf '%s' "$test_enabled" ;;
    agent_release.image_ref) printf '%s' "$test_image_ref" ;;
    agent_release.instance_id) printf '%s' "$test_instance_id" ;;
    agent_release.model_profiles_sha256) printf '%s' "$test_profiles_sha256" ;;
    *) return 1 ;;
  esac
}
state_set_raw() {
  [ "$1" = agent_release ] || return 1
  local value=$2
  test_source=$(printf '%s' "$value" | sed -nE 's/.*"source":"([^"]*)".*/\1/p')
  test_enabled=$(printf '%s' "$value" | sed -nE 's/.*"enabled":"([^"]*)".*/\1/p')
  test_image_ref=$(printf '%s' "$value" | sed -nE 's/.*"image_ref":"([^"]*)".*/\1/p')
  test_instance_id=$(printf '%s' "$value" | sed -nE 's/.*"instance_id":"([^"]*)".*/\1/p')
  test_profiles_sha256=$(printf '%s' "$value" | sed -nE 's/.*"model_profiles_sha256":"([^"]*)".*/\1/p')
}

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/agent-release.sh"

agent_image_is_immutable "$image"
! agent_image_is_immutable 'registry.example/dirextalk-agent:latest'
! agent_image_is_immutable 'registry.example/dirextalk-agent:v1.0.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
! agent_image_is_immutable $'registry.example/dirextalk-agent:v0.1.0-alpha.1-abcdef1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nINJECTED=true'
agent_instance_id_is_canonical "$instance_id"
! agent_instance_id_is_canonical 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
! agent_instance_id_is_canonical '00000000-0000-0000-0000-000000000000'
! agent_model_profiles_file_is_safe "$unsafe_profiles"

# Git Bash/coreutils uses this leading marker when escaping a Windows path.
# Persisting that marker would make the later infrastructure-bound comparison
# fail, even with exactly the same catalog file.
escaped_sha256_digest=$(printf '%064d' 0 | tr 0 a)
sha256sum() {
  printf '\\%s *C:\\model-profiles.json\n' "$escaped_sha256_digest"
}
[ "$(agent_model_profiles_sha256 "$profiles")" = "$escaped_sha256_digest" ]
AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state
[ "$test_profiles_sha256" = "$escaped_sha256_digest" ]
test_infrastructure_id=i-agent-existing
AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state
unset -f sha256sum
test_source= test_enabled= test_image_ref= test_instance_id= test_profiles_sha256= test_infrastructure_id=

AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state
[ "$test_source" = operator_image ]
[ "$test_enabled" = true ]
[ "$test_image_ref" = "$image" ]
[ "$test_instance_id" = "$instance_id" ]
[ "${#test_profiles_sha256}" = 64 ]

test_infrastructure_id=i-agent-existing
if AGENT_IMAGE="$changed_image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$profiles" agent_release_prepare_state; then
  echo "existing infrastructure must reject a replacement Agent image" >&2
  exit 1
fi
if AGENT_IMAGE="$image" AGENT_INSTANCE_ID="$instance_id" AGENT_MODEL_PROFILES_FILE="$changed_profiles" agent_release_prepare_state; then
  echo "existing infrastructure must reject a changed model-profile catalog" >&2
  exit 1
fi

test_source= test_enabled= test_image_ref= test_instance_id= test_profiles_sha256=
unset AGENT_IMAGE AGENT_INSTANCE_ID AGENT_MODEL_PROFILES_FILE
agent_release_prepare_state
[ "$test_source" = disabled ]
[ "$test_enabled" = false ]

agent_bundle="$tmp/agent-user-data.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  > "$agent_bundle"
awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$agent_bundle" | base64 -d > "$tmp/agent-bundle.tar.gz"
mkdir "$tmp/agent-bundle"
tar -xzf "$tmp/agent-bundle.tar.gz" -C "$tmp/agent-bundle"
printf '%s\n' \
  'DOMAIN=service.example.test' \
  'ACME_EMAIL=ops@example.test' \
  'MESSAGE_SERVER_IMAGE=dirextalk/message-server:test' \
  "AGENT_IMAGE=$image" \
  "AGENT_INSTANCE_ID=$instance_id" \
  'TURN_SECRET=render-test-turn-secret' \
  'P2P_PORTAL_PASSWORD=12345678' \
  'PUBLIC_IP=203.0.113.10' \
  > "$tmp/agent-bundle/.env"
if command -v docker >/dev/null 2>&1; then
  docker compose --env-file "$tmp/agent-bundle/.env" -f "$tmp/agent-bundle/docker-compose.yml" config --quiet
fi

tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-db-init.sh
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-runtime-init.sh
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx agent-model-profiles.json
tar -tzf "$tmp/agent-bundle.tar.gz" | grep -qx p2p-http-request.sh
grep -F -q "AGENT_IMAGE=$image" "$agent_bundle"
grep -F -q "AGENT_INSTANCE_ID=$instance_id" "$agent_bundle"

# Lightsail rejected a 15,912-byte raw script because the CreateInstances
# request itself crossed its 16,000-byte ceiling. Reserve payload headroom for
# AWS CLI JSON escaping and the request envelope.
lightsail_user_data="$tmp/agent-user-data.sh"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --format shell \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image "$lightsail_message_image" \
  --agent-image "$image" \
  --agent-instance-id "$instance_id" \
  --agent-model-profiles-file "$profiles" \
  > "$lightsail_user_data"
lightsail_user_data_bytes=$(wc -c < "$lightsail_user_data")
[ "$lightsail_user_data_bytes" -le 15700 ] || {
  echo "enabled Agent Lightsail shell user-data exceeds the 15700-byte safe ceiling ($lightsail_user_data_bytes bytes)" >&2
  exit 1
}

grep -q '^  agent-runtime-init:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent-db-init:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent-migrate:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent-bootstrap:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q '^  agent:$' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_ENABLED: "true"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_TARGET: dns:///agent:9443' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_CA_FILE: /run/dirextalk-agent/agent-ca.crt' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_SERVER_NAME: agent' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'P2P_AGENT_GRPC_SERVICE_KEY_FILE: /run/dirextalk-agent/message-server.service-key' "$tmp/agent-bundle/docker-compose.yml"
grep -q "P2P_AGENT_GRPC_INSTANCE_ID: \${AGENT_INSTANCE_ID}" "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_BOOTSTRAP_CLIENT_ID: "dirextalk-project:${DOMAIN}"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'AGENT_ENABLE_AWS_CONTROL: "false"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'user: "65532:65532"' "$tmp/agent-bundle/docker-compose.yml"
grep -q 'condition: service_healthy' "$tmp/agent-bundle/docker-compose.yml"
grep -q -- '--server agent' "$ROOT/scripts/cloud-init/agent-runtime-init.sh"
grep -q 'cmp -s "$ca_cert" "$tls_cert"' "$ROOT/scripts/cloud-init/agent-runtime-init.sh"
if grep -Eq -- '--tls-authority-cert|--tls-authority-key' "$ROOT/scripts/cloud-init/agent-runtime-init.sh"; then
  echo "Agent TLS trust must use the exact self-signed leaf, never a pseudo-CA signer" >&2
  exit 1
fi

# The original experimental layout copied a non-CA self-signed certificate as
# a signer and placed its separately signed leaf in the runtime volume. Strict
# TLS clients reject that chain, so a resume must fail closed rather than
# preserving it. This exits before the image-provided generate-keys binary is
# needed, keeping the regression check portable.
legacy_runtime="$tmp/legacy-agent-runtime"
mkdir "$legacy_runtime"
printf '%s\n' 'retired-pseudo-ca' > "$legacy_runtime/agent-ca.crt"
printf '%s\n' 'retired-signed-leaf' > "$legacy_runtime/agent-tls.crt"
printf '%s\n' 'retired-private-key' > "$legacy_runtime/agent-tls.key"
if AGENT_RUNTIME_DIR="$legacy_runtime" AGENT_MODEL_PROFILES_SOURCE="$profiles" sh "$ROOT/scripts/cloud-init/agent-runtime-init.sh" > "$tmp/legacy-agent-runtime.out" 2>&1; then
  echo "retired Agent pseudo-CA runtime layout must be rejected" >&2
  exit 1
fi
grep -q 'retired signer layout' "$tmp/legacy-agent-runtime.out"

if grep -q 'P2P_AGENT_GRPC_SERVICE_KEY:' "$tmp/agent-bundle/docker-compose.yml"; then
  echo "Agent service key must be mounted, never inline" >&2
  exit 1
fi
awk '
  /^  agent:$/ { in_agent=1; next }
  /^  [A-Za-z0-9_-]+:$/ { in_agent=0 }
  in_agent && /^[[:space:]]+ports:/ { bad=1 }
  END { exit bad }
' "$tmp/agent-bundle/docker-compose.yml"

disabled_bundle="$tmp/disabled-user-data.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --acme ops@example.test \
  --message-server-image dirextalk/message-server:test \
  > "$disabled_bundle"
awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$disabled_bundle" | base64 -d > "$tmp/disabled-bundle.tar.gz"
if tar -tzf "$tmp/disabled-bundle.tar.gz" | grep -q 'agent-\|agent-runtime'; then
  echo "disabled render must omit Agent scripts and catalog" >&2
  exit 1
fi
mkdir "$tmp/disabled-bundle"
tar -xzf "$tmp/disabled-bundle.tar.gz" -C "$tmp/disabled-bundle"
if grep -q 'P2P_AGENT_GRPC_' "$tmp/disabled-bundle/docker-compose.yml"; then
  echo "disabled render must omit the remote Agent tuple" >&2
  exit 1
fi

if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image dirextalk-agent:latest --agent-instance-id "$instance_id" --agent-model-profiles-file "$profiles" > /dev/null 2>&1; then
  echo "renderer accepted a mutable Agent tag" >&2
  exit 1
fi
if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image "$image" --agent-instance-id "$instance_id" > /dev/null 2>&1; then
  echo "renderer accepted an Agent without a model-profile catalog" >&2
  exit 1
fi
if bash "$ROOT/scripts/render/render-userdata.sh" --domain service.example.test --acme ops@example.test --message-server-image dirextalk/message-server:test --agent-image "$image" --agent-instance-id "$instance_id" --agent-model-profiles-file "$unsafe_profiles" > /dev/null 2>&1; then
  echo "renderer accepted credential-shaped model-profile content" >&2
  exit 1
fi

grep -q 'cloud.deployments.list' "$ROOT/scripts/phases/s5_init_tokens.sh"
grep -q 'p2p-http-request.sh' "$ROOT/scripts/phases/s5_init_tokens.sh"
if grep -Eq -- '--config=|--header.*Authorization' \
  "$ROOT/scripts/cloud-init/init-tokens.sh" \
  "$ROOT/scripts/phases/s5_init_tokens.sh"; then
  echo "Agent acceptance must not pass the bootstrap token in command arguments" >&2
  exit 1
fi
grep -q 'fresh-z3 path is an anonymously pullable' "$ROOT/references/agent-runtime.md"
grep -q "DIREXTALK_CONNECT_AGENT_OPTIONS_TOML='mode = \"default\"'" "$ROOT/references/agent-runtime.md"

echo "optional Agent runtime contract ok"
