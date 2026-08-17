#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fixture="$TEST_TMP/deployer"
split="$fixture/runtime"
mkdir -p "$split/scripts" "$split/apparmor.d" "$split/systemd" "$split/sysusers.d"
git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name Test

files=(
  compose.yaml compose.production.yaml edge-compose.yaml
  apparmor.d/dirextalk-runner-userns
  systemd/dirextalk-extension-runner@.service
  systemd/dirextalk-core-runner@.service
  sysusers.d/dirextalk-split-agent.conf
  scripts/provision-local.sh
  scripts/prepare-host-dependencies.sh
  scripts/initialize-capability-ca.sh
  scripts/initialize-message-server.sh
  scripts/materialize-agent-secrets.sh
  scripts/message-server-entrypoint.sh
  scripts/prepare-runner-cgroups.sh
  scripts/prepare-agent-start-local.sh
  scripts/manage-runner-apparmor.sh
  scripts/start-local.sh
  scripts/cleanup-local.sh
  scripts/cleanup-provision-failure.sh
  scripts/verify-production-images.sh
  scripts/agent-runtime-local-common.sh
  scripts/stop-agent-local.sh
  scripts/restart-agent-local.sh
  scripts/update-agent-local.sh
  scripts/update-message-server-local.sh
)
for file in "${files[@]}"; do
  mkdir -p "$split/$(dirname "$file")"
  printf '%s\n' "$file" >"$split/$file"
done
git -C "$fixture" add runtime
git -C "$fixture" commit -qm fixture
revision=$(git -C "$fixture" rev-parse HEAD:runtime)

bundle="$TEST_TMP/split-agent.tar.gz"
DIREXTALK_SPLIT_RUNTIME_ROOT="$split" \
  bash "$ROOT/scripts/render/render-split-bundle.sh" "$bundle"

[ "$(stat -c '%a' "$bundle")" = 600 ]
tar -tzf "$bundle" deploy/split-agent/compose.yaml >/dev/null
tar -tzf "$bundle" deploy/split-agent/compose.production.yaml >/dev/null
tar -tzf "$bundle" deploy/split-agent/scripts/prepare-runner-cgroups.sh >/dev/null
tar -tzf "$bundle" deploy/split-agent/scripts/prepare-host-dependencies.sh >/dev/null
tar -tzf "$bundle" deploy/split-agent/scripts/start-local.sh >/dev/null
tar -tzf "$bundle" deploy/split-agent/scripts/update-message-server-local.sh >/dev/null
[ "$(tar -xOzf "$bundle" deploy/split-agent/SOURCE_REVISION)" = "$revision" ]
tar -tzf "$bundle" deploy/split-agent/SOURCE_FILES.sha256 >/dev/null
mkdir -p "$TEST_TMP/unpacked"
tar -xzf "$bundle" -C "$TEST_TMP/unpacked"
(cd "$TEST_TMP/unpacked/deploy/split-agent" && sha256sum -c --status SOURCE_FILES.sha256)
if tar -tzf "$bundle" | grep -Eq '(^|/)(tests?|container|aws)/|compose\.local\.yaml$|\.gitignore$'; then
  echo "split bundle contains source-only or test assets" >&2
  exit 1
fi

sha_file="$bundle.sha256"
sha256sum "$bundle" >"$sha_file"
packaged="$TEST_TMP/packaged-copy.tar.gz"
DIREXTALK_SPLIT_BUNDLE_FILE="$bundle" \
DIREXTALK_SPLIT_BUNDLE_SHA256_FILE="$sha_file" \
  bash "$ROOT/scripts/render/render-split-bundle.sh" "$packaged"
cmp "$bundle" "$packaged"

repository_bundle="$ROOT/scripts/cloud-init/split/canonical-bundle.tar.gz"
repository_sha="$repository_bundle.sha256"
[ -f "$repository_bundle" ] && [ -f "$repository_sha" ]
[ "$(sha256sum "$repository_bundle" | awk '{print $1}')" = "$(awk 'NR == 1 {print $1}' "$repository_sha")" ]
repository_copy="$TEST_TMP/repository-copy.tar.gz"
DIREXTALK_SPLIT_BUNDLE_FILE="$repository_bundle" \
DIREXTALK_SPLIT_BUNDLE_SHA256_FILE="$repository_sha" \
  bash "$ROOT/scripts/render/render-split-bundle.sh" "$repository_copy"
cmp "$repository_bundle" "$repository_copy"
repository_revision=$(tar -xOzf "$repository_bundle" deploy/split-agent/SOURCE_REVISION)
printf '%s\n' "$repository_revision" | grep -Eq '^[0-9a-f]{40}$'
[ "$repository_revision" = "$(sed -n 's/^DIREXTALK_SPLIT_SOURCE_REVISION=//p' "$ROOT/scripts/cloud-init/split/release.env")" ]
tar -tzf "$repository_bundle" deploy/split-agent/compose.production.yaml >/dev/null
tar -tzf "$repository_bundle" deploy/split-agent/scripts/update-message-server-local.sh >/dev/null
tar -xOzf "$repository_bundle" deploy/split-agent/scripts/cleanup-local.sh \
  | grep -F 'manifest TLS mode must be edge-terminated' >/dev/null
mkdir -p "$TEST_TMP/repository-unpacked"
tar -xzf "$repository_bundle" -C "$TEST_TMP/repository-unpacked"
(cd "$TEST_TMP/repository-unpacked/deploy/split-agent" && sha256sum -c --status SOURCE_FILES.sha256)
repository_compose="$TEST_TMP/repository-unpacked/deploy/split-agent/compose.yaml"
[ "$(grep -Ec '^  postgres:$' "$repository_compose")" -eq 1 ]
[ "$(grep -Fc 'apparmor=dirextalk-runner-userns' "$repository_compose")" -eq 2 ]
[ "$(grep -Fc 'seccomp=unconfined' "$repository_compose")" -eq 2 ]
repository_apparmor="$TEST_TMP/repository-unpacked/deploy/split-agent/apparmor.d/dirextalk-runner-userns"
grep -Fqx 'profile dirextalk-runner-userns flags=(unconfined) {' "$repository_apparmor"
grep -Fqx '  userns,' "$repository_apparmor"
grep -Fq 'image: ${DIREXTALK_POSTGRES_IMAGE_IMMUTABLE:?set an immutable PostgreSQL image reference}' "$repository_compose"
grep -Fq 'aliases: [message-postgres]' "$repository_compose"
grep -Fq 'aliases: [agent-postgres]' "$repository_compose"
grep -Fq 'postgres_data:/var/lib/postgresql' "$repository_compose"
grep -Fq 'expose: ["9443", "8444", "8082"]' "$repository_compose"
if sed -n '/^  agent:$/,/^  extension-runner:$/p' "$repository_compose" | grep -Eq '^    ports:'; then
  echo 'canonical split bundle published the Agent HTTP data plane on a host port' >&2
  exit 1
fi
grep -Fq 'P2P_PRODUCT_CAPABILITY_LISTEN_ADDR: :50053' "$repository_compose"
grep -Fq 'expose: ["50053"]' "$repository_compose"
if grep -Fq '50052' "$repository_compose"; then
  echo 'canonical split bundle retained the retired Message Server to Agent Capability gRPC port' >&2
  exit 1
fi
grep -Fq 'networks: [agent_private, agent_database, agent_caller, agent_egress, message_public]' "$repository_compose"
if awk '
  /^  message-server:$/ { in_message = 1; next }
  in_message && /^  [a-zA-Z0-9_-]+:$/ { exit }
  in_message && /^      agent:$/ { found = 1; exit }
  END { exit(found ? 0 : 1) }
' "$repository_compose"; then
  echo 'canonical split bundle retained the Message Server to Agent health dependency' >&2
  exit 1
fi
start_source="$ROOT/scripts/cloud-init/split/runtime/scripts/start-local.sh"
message_start_line=$(grep -nF -- '--wait message-server' "$start_source" | cut -d: -f1)
agent_start_line=$(grep -nF 'agent-secret-init agent-migrate extension-runner core-runner agent; then' "$start_source" | cut -d: -f1)
[ -n "$message_start_line" ] && [ -n "$agent_start_line" ] && [ "$message_start_line" -lt "$agent_start_line" ] || {
  echo 'fresh startup does not establish Message Server before the explicit Agent path' >&2
  exit 1
}
grep -Fq 'message-server is healthy; Agent runtime needs attention' "$start_source"
if grep -Ei 'qdrant|message[_-]postgres[_-](data|volume)|agent[_-]postgres[_-](data|volume)' \
    "$repository_compose" >/dev/null; then
  echo 'canonical split bundle retained superseded Qdrant or per-application PostgreSQL resources' >&2
  exit 1
fi
host_integration="$ROOT/scripts/cloud-init/split/apply-host-integration.sh"
grep -Fq 'sshd_effective=$(sshd -T)' "$host_integration"
grep -Fq "grep -Fx 'passwordauthentication no' <<<\"\$sshd_effective\"" "$host_integration"
grep -Fq "grep -Fx 'pubkeyauthentication yes' <<<\"\$sshd_effective\"" "$host_integration"
consumer="$ROOT/scripts/cloud-init/split/bootstrap-production.sh"
consumer_exec="$TEST_TMP/bootstrap-production.sh"
sed "s#/usr/local/libexec/dirextalk/split-agent#$TEST_TMP/runner-libexec#g" \
  "$consumer" >"$consumer_exec"
cp "$ROOT/scripts/cloud-init/split/Caddyfile" "$ROOT/scripts/cloud-init/split/edge-compose.override.yaml" "$TEST_TMP/"
edge_source="$ROOT/scripts/cloud-init/split/Caddyfile"
edge_overlay="$ROOT/scripts/cloud-init/split/edge-compose.override.yaml"
grep -Fq 'DIREXTALK_SPLIT_COMPOSE_MODE=production' "$consumer"
grep -Fq 'DIREXTALK_MESSAGE_TLS_MODE=edge-terminated' "$consumer"
grep -Fq 'staged production Compose override is missing' "$consumer"
grep -Fq 'staged message-server update adapter is not executable' "$consumer"
grep -Fq '"$runner_libexec/scripts/prepare-runner-cgroups.sh" "$stack"' "$consumer"
grep -Fq '"$split/scripts/prepare-host-dependencies.sh"' "$consumer"
grep -Fq '"$split/scripts/provision-local.sh" "$run_dir"' "$consumer"
grep -Fq '"$split/scripts/start-local.sh" "$run_dir/.env"' "$consumer"
grep -Fq 'sed "s/__DIREXTALK_PUBLIC_DOMAIN__/$domain/g" "$script_dir/Caddyfile"' "$consumer"
grep -Fq 'mv -f "$caddy_tmp" "$caddyfile"' "$consumer"
grep -Fq 'require_pair "$edge_env" DIREXTALK_CADDYFILE "$caddyfile"' "$consumer"
grep -Fq 'cloud-init/split/Caddyfile' "$ROOT/scripts/phases/s3_provision.sh"
grep -Fq 'cloud-init/split/edge-compose.override.yaml' "$ROOT/scripts/phases/s3_provision.sh"
grep -Fq '"$candidate_ops/"' "$host_integration"
grep -Fq 'mv -- "$candidate_split" "$base/deploy/split-agent"' "$host_integration"
grep -Fq 'source: /run/dirextalk-updater' "$edge_overlay"
grep -Fq 'target: /run/dirextalk-updater' "$edge_overlay"
grep -Fq 'read_only: true' "$edge_overlay"
grep -Fq -- '-f "$script_dir/edge-compose.override.yaml"' "$consumer"
grep -Fq 'handle /.well-known/matrix/server' "$edge_source"
grep -Fq 'handle /.well-known/matrix/client' "$edge_source"
grep -Fq 'header Access-Control-Allow-Origin *' "$edge_source"
grep -Fq 'handle /.well-known/portal/*' "$edge_source"
grep -Fq 'handle /agent/v1/*' "$edge_source"
grep -Fq 'reverse_proxy agent:8082' "$edge_source"
grep -Fq 'flush_interval -1' "$edge_source"
grep -Fq 'handle /_matrix/*' "$edge_source"
grep -Fq 'handle /_dendrite/*' "$edge_source"
grep -Fq 'handle /_synapse/*' "$edge_source"
grep -Fq 'handle /_p2p/*' "$edge_source"
grep -Fq 'handle /_dirextalk/updater/v1/jobs/*' "$edge_source"
grep -Fq 'reverse_proxy unix//run/dirextalk-updater/http.sock' "$edge_source"
grep -Fq 'reverse_proxy message-server:8008' "$edge_source"
agent_route_line=$(grep -nF 'handle /agent/v1/*' "$edge_source" | cut -d: -f1)
message_fallback_line=$(grep -nF 'reverse_proxy message-server:8008' "$edge_source" | tail -n 1 | cut -d: -f1)
[ "$agent_route_line" -lt "$message_fallback_line" ]
if grep -Eq 'header_up[[:space:]]+-Authorization|log_append[[:space:]].*Authorization' "$edge_source"; then
  echo "edge source strips or logs the Agent session ticket" >&2
  exit 1
fi
if grep -Fq 'handle /healthz' "$edge_source" || grep -Fq 'rewrite * /_p2p/health' "$edge_source"; then
  echo "edge source restored the retired health alias" >&2
  exit 1
fi
grep -Fq '"$script_dir/bootstrap-production.sh"' "$ROOT/scripts/cloud-init/split/reconcile-production.sh"
grep -Fq "cmp \"\$portal_bootstrap\" \"\$refresh_dir/bootstrap.json\"" "$consumer"
grep -Fq 'existing portal bootstrap differs from the running stack' "$consumer"
grep -Fq 'runner_libexec=/usr/local/libexec/dirextalk/split-agent' "$consumer"
grep -Fq '"$split/scripts/manage-runner-apparmor.sh"' "$consumer"

# Exercise the actual first-fresh bootstrap consumer up to the canonical
# provision boundary. The provision probe deliberately stops the bootstrap
# after recording the release inputs, before Docker or host mutation begins.
fresh="$TEST_TMP/first-fresh"
fresh_split="$fresh/deploy/split-agent"
mkdir -p "$fresh_split/scripts" "$fresh_split/systemd" "$fresh_split/sysusers.d" "$fresh_split/apparmor.d" "$TEST_TMP/fakebin"
cat >"$fresh_split/scripts/prepare-runner-cgroups.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'DIREXTALK_RUNNER_PREPARED=true' \
  "DIREXTALK_RUNNER_APPARMOR_MANAGER_PATH=$(cd "$(dirname "$0")" && pwd -P)/manage-runner-apparmor.sh" \
  "DIREXTALK_RUNNER_PREP_HELPER_PATH=$(cd "$(dirname "$0")" && pwd -P)/prepare-runner-cgroups.sh"
EOF
cat >"$fresh_split/scripts/manage-runner-apparmor.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fresh_split/scripts/provision-local.sh" <<'EOF'
#!/usr/bin/env bash
printf 'message_image=%s\nmessage_version=%s\nmessage_revision=%s\nagent_image=%s\nagent_version=%s\nagent_revision=%s\ncoturn=%s\nturn_external_ip=%s\ncloud_worker_host_region=%s\ncatalog_origin=%s\noutput=%s\n' \
  "$DIREXTALK_MESSAGE_SERVER_IMAGE" "$DIREXTALK_MESSAGE_SERVER_VERSION" "$DIREXTALK_MESSAGE_SOURCE_REVISION" \
  "$DIREXTALK_AGENT_IMAGE" "$DIREXTALK_AGENT_VERSION" "$DIREXTALK_AGENT_SOURCE_REVISION" \
  "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" "$DIREXTALK_TURN_EXTERNAL_IP" \
  "$DIREXTALK_CLOUD_WORKER_HOST_REGION" "$DIREXTALK_RELEASE_CATALOG_ORIGIN" "$1" >"$DIREXTALK_TEST_PROVISION_CAPTURE"
exit 42
EOF
cat >"$fresh_split/scripts/start-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
cat >"$fresh_split/scripts/cleanup-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
cat >"$fresh_split/scripts/cleanup-provision-failure.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
: >"$fresh_split/compose.production.yaml"
cat >"$fresh_split/scripts/update-message-server-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fresh_split/scripts/prepare-host-dependencies.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$fresh_split/scripts/"*.sh
printf '%s\n' extension >"$fresh_split/systemd/dirextalk-extension-runner@.service"
printf '%s\n' core >"$fresh_split/systemd/dirextalk-core-runner@.service"
printf '%s\n' users >"$fresh_split/sysusers.d/dirextalk-split-agent.conf"
printf '%s\n' apparmor >"$fresh_split/apparmor.d/dirextalk-runner-userns"
printf '%s\n' cccccccccccccccccccccccccccccccccccccccc >"$fresh_split/SOURCE_REVISION"
(cd "$fresh_split" && find . -type f ! -name SOURCE_FILES.sha256 -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum >SOURCE_FILES.sha256)
cat >"$fresh/.env" <<'EOF'
DOMAIN=turn.example.test
MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.32
AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.69
POSTGRES_IMAGE=docker.io/pgvector/pgvector:pg18@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
CADDY_IMAGE=docker.io/library/caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
COTURN_IMAGE=docker.io/coturn/coturn:4.6.3-alpine@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
MESSAGE_VERSION=v1.1.32
AGENT_VERSION=v1.0.69
MESSAGE_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SPLIT_SOURCE_REVISION=cccccccccccccccccccccccccccccccccccccccc
AGENT_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DIREXTALK_CLOUD_WORKER_HOST_REGION=ap-east-1
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
EOF
chmod 0600 "$fresh/.env"
printf '%s\n' 203.0.113.91 >"$fresh/stable-public-ip"
chmod 0600 "$fresh/stable-public-ip"
cat >"$TEST_TMP/fakebin/stat" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"%u:%a"*) printf '%s\n' '0:600' ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$TEST_TMP/fakebin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF
chmod 0755 "$TEST_TMP/fakebin/stat" "$TEST_TMP/fakebin/install"
cat >"$TEST_TMP/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pull) exit 0 ;;
  image)
    case "$3" in
      docker.io/dirextalk/message-server:v1.1.32) printf '%s\n' 'v1.1.32|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
      docker.io/dirextalk/agent:v1.0.69) printf '%s\n' 'v1.0.69|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
      *) exit 2 ;;
    esac
    ;;
  run)
    case "$4" in
      /usr/bin/dirextalk-message-server) printf '%s\n' v1.1.32 ;;
      /usr/local/bin/dirextalk-agent|/usr/local/bin/dirextalk-extension-runner|/usr/local/bin/dirextalk-core-runner) printf '%s\n' v1.0.69 ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$TEST_TMP/fakebin/docker"
capture="$TEST_TMP/provision.capture"
if PATH="$TEST_TMP/fakebin:$PATH" \
  DIREXTALK_BOOTSTRAP_BASE="$fresh" \
  DIREXTALK_TEST_PROVISION_CAPTURE="$capture" \
  bash "$consumer_exec" >"$TEST_TMP/first-fresh.out" 2>"$TEST_TMP/first-fresh.err"; then
  echo "first-fresh bootstrap unexpectedly passed the stopping provision probe" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 42 ] || { cat "$TEST_TMP/first-fresh.err" >&2; exit 1; }
grep -Fqx 'message_image=docker.io/dirextalk/message-server:v1.1.32' "$capture"
grep -Fqx 'message_version=v1.1.32' "$capture"
grep -Fqx 'message_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$capture"
grep -Fqx 'agent_image=docker.io/dirextalk/agent:v1.0.69' "$capture"
grep -Fqx 'agent_version=v1.0.69' "$capture"
grep -Fqx 'agent_revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$capture"
grep -Fqx 'coturn=docker.io/coturn/coturn:4.6.3-alpine@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' "$capture"
grep -Fqx 'turn_external_ip=203.0.113.91' "$capture"
grep -Fqx 'cloud_worker_host_region=ap-east-1' "$capture"
grep -Fqx 'catalog_origin=https://imadmin.dirextalk.ai' "$capture"
[ ! -e "$fresh/image-attestation" ]

# Required production update inputs fail closed before runner preparation or
# any Docker/host mutation. Rebuild the source manifest after each fixture
# change so this exercises the bootstrap readiness gate itself.
mv "$fresh_split/compose.production.yaml" "$fresh_split/compose.production.yaml.absent"
(cd "$fresh_split" && find . -type f ! -name SOURCE_FILES.sha256 -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum >SOURCE_FILES.sha256)
rm -f "$capture" "$fresh/runner-preparation.env" "$fresh/split-stack-name" "$fresh/.split-bootstrap-stage"
if PATH="$TEST_TMP/fakebin:$PATH" DIREXTALK_BOOTSTRAP_BASE="$fresh" \
    DIREXTALK_TEST_PROVISION_CAPTURE="$capture" \
    bash "$consumer_exec" >/dev/null 2>"$TEST_TMP/missing-production-compose.err"; then
  echo "first-fresh bootstrap accepted a missing production Compose override" >&2
  exit 1
fi
grep -Fqx 'staged production Compose override is missing' "$TEST_TMP/missing-production-compose.err"
[ ! -e "$fresh/runner-preparation.env" ]
mv "$fresh_split/compose.production.yaml.absent" "$fresh_split/compose.production.yaml"

chmod 0644 "$fresh_split/scripts/update-message-server-local.sh"
(cd "$fresh_split" && find . -type f ! -name SOURCE_FILES.sha256 -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum >SOURCE_FILES.sha256)
if PATH="$TEST_TMP/fakebin:$PATH" DIREXTALK_BOOTSTRAP_BASE="$fresh" \
    DIREXTALK_TEST_PROVISION_CAPTURE="$capture" \
    bash "$consumer_exec" >/dev/null 2>"$TEST_TMP/nonexecutable-message-update.err"; then
  echo "first-fresh bootstrap accepted a non-executable message-server update adapter" >&2
  exit 1
fi
grep -Fqx 'staged message-server update adapter is not executable' "$TEST_TMP/nonexecutable-message-update.err"
[ ! -e "$fresh/runner-preparation.env" ]

# The real edge-only bootstrap consumer must converge Caddy without reading,
# comparing, exporting, or replacing a rotated portal bootstrap credential.
edge="$TEST_TMP/edge-only"
edge_split="$edge/deploy/split-agent"
edge_fakebin="$TEST_TMP/edge-fakebin"
edge_stack=d-aaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$edge_split/scripts" "$edge/p2p" "$edge_fakebin"
: >"$edge_split/compose.production.yaml"
cat >"$edge_split/edge-compose.yaml" <<'EOF'
services:
  caddy: {}
EOF
cat >"$edge_split/scripts/export-portal-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'export-called\n' >>"$EDGE_CALLS"
exit 99
EOF
chmod 0755 "$edge_split/scripts/export-portal-bootstrap.sh"
cat >"$edge_split/scripts/update-message-server-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$edge_split/scripts/prepare-host-dependencies.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$edge_split/scripts/cleanup-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
cat >"$edge_split/scripts/cleanup-provision-failure.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod 0755 "$edge_split/scripts/"*.sh
printf '%s\n' cccccccccccccccccccccccccccccccccccccccc >"$edge_split/SOURCE_REVISION"
(cd "$edge_split" && find . -type f ! -name SOURCE_FILES.sha256 -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum >SOURCE_FILES.sha256)
cat >"$edge/.env" <<'EOF'
DOMAIN=edge.example.test
MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.32
AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.69
POSTGRES_IMAGE=docker.io/pgvector/pgvector:pg18@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
CADDY_IMAGE=docker.io/library/caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
COTURN_IMAGE=docker.io/coturn/coturn:4.6.3-alpine@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
MESSAGE_VERSION=v1.1.32
AGENT_VERSION=v1.0.69
MESSAGE_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SPLIT_SOURCE_REVISION=cccccccccccccccccccccccccccccccccccccccc
AGENT_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
EOF
chmod 0600 "$edge/.env"
printf '%s\n' 203.0.113.92 >"$edge/stable-public-ip"
chmod 0600 "$edge/stable-public-ip"
printf '%s\n' "$edge_stack" >"$edge/split-stack-name"
touch "$edge/.split-deploy-done"
cat >"$edge/edge.env" <<EOF
DIREXTALK_EDGE_STACK_NAME=${edge_stack}-edge
DIREXTALK_PUBLIC_DOMAIN=edge.example.test
DIREXTALK_MESSAGE_TLS_MODE=edge-terminated
DIREXTALK_MESSAGE_PUBLIC_NETWORK=${edge_stack}-message-public
DIREXTALK_CADDY_IMAGE_IMMUTABLE=docker.io/library/caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
DIREXTALK_CADDY_DATA_VOLUME=${edge_stack}-caddy-data
DIREXTALK_CADDY_CONFIG_VOLUME=${edge_stack}-caddy-config
DIREXTALK_CADDYFILE=$edge/Caddyfile
DIREXTALK_STATIC_SITES_ROOT=$edge/static-sites
EOF
chmod 0400 "$edge/edge.env"
mkdir -p "$edge/split" "$edge/static-sites/public"
cat >"$edge/split/.env" <<EOF
DIREXTALK_STATIC_SITES_ROOT=$edge/static-sites
DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.32
DIREXTALK_MESSAGE_SERVER_VERSION=v1.1.32
DIREXTALK_MESSAGE_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.69
DIREXTALK_AGENT_VERSION=v1.0.69
DIREXTALK_AGENT_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
chmod 0400 "$edge/split/.env"
printf '%s\n' '{"access_token":"rotated","agent_token":"rotated-agent","password":"rotated-password","owner_user_id":"@owner:edge.example.test"}' >"$edge/p2p/bootstrap.json"
chmod 0400 "$edge/p2p/bootstrap.json"
edge_bootstrap_sha=$(sha256sum "$edge/p2p/bootstrap.json" | awk '{print $1}')
cat >"$edge_fakebin/stat" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"%u:%a"*"$edge/.env"|*"%u:%a"*"$edge/stable-public-ip") printf '%s\n' '0:600' ;;
  *"%u:%a"*"$edge/edge.env"|*"%u:%a"*"$edge/split/.env") printf '%s\n' '0:400' ;;
  *) exec /usr/bin/stat "\$@" ;;
esac
EOF
cat >"$edge_fakebin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker' >>"$EDGE_CALLS"; printf ' %q' "$@" >>"$EDGE_CALLS"; printf '\n' >>"$EDGE_CALLS"
if [ "${1:-}" = pull ]; then exit 0; fi
if [ "${1:-}" = image ]; then
  case "$3" in
    docker.io/dirextalk/message-server:v1.1.32) printf '%s\n' 'v1.1.32|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    docker.io/dirextalk/agent:v1.0.69) printf '%s\n' 'v1.0.69|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
  esac
  exit 0
fi
if [ "${1:-}" = run ]; then
  case "$4" in
    /usr/bin/dirextalk-message-server) printf '%s\n' v1.1.32 ;;
    *) printf '%s\n' v1.0.69 ;;
  esac
  exit 0
fi
if [ "${1:-}" = compose ]; then
  for arg in "$@"; do
    [ "$arg" = ps ] && { printf '%064d\n' 1; exit 0; }
  done
fi
exit 0
EOF
chmod 0755 "$edge_fakebin/stat" "$edge_fakebin/docker"
edge_calls="$TEST_TMP/edge-only.calls"
: >"$edge_calls"
PATH="$edge_fakebin:$PATH" EDGE_CALLS="$edge_calls" DIREXTALK_BOOTSTRAP_BASE="$edge" \
  bash "$consumer_exec" --reconcile-edge
[ "$(sha256sum "$edge/p2p/bootstrap.json" | awk '{print $1}')" = "$edge_bootstrap_sha" ]
if grep -Fq 'export-called' "$edge_calls"; then
  echo "edge-only reconcile touched portal bootstrap export" >&2
  exit 1
fi
grep -Fq 'compose' "$edge_calls"
grep -Fq 'up -d --wait --force-recreate caddy' "$edge_calls"

for relative in compose.production.yaml scripts/update-message-server-local.sh scripts/prepare-runner-cgroups.sh; do
  missing="$split/$relative"
  mv "$missing" "$missing.absent"
  if DIREXTALK_SPLIT_RUNTIME_ROOT="$split" \
    bash "$ROOT/scripts/render/render-split-bundle.sh" "$TEST_TMP/invalid.tar.gz" \
      >/dev/null 2>"$TEST_TMP/missing-input.err"; then
    echo "split bundle renderer accepted a missing required input: $relative" >&2
    exit 1
  fi
  grep -Fq "missing canonical split deployment asset: $split/$relative" "$TEST_TMP/missing-input.err"
  mv "$missing.absent" "$missing"
done

echo "split agent bundle test passed"
