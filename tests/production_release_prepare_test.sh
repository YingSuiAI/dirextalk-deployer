#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

runtime_repo=$tmp/deployer
runtime_root=$runtime_repo/runtime
mkdir -p "$runtime_root/scripts"
git -C "$runtime_repo" init -q
git -C "$runtime_repo" config user.email test@example.invalid
git -C "$runtime_repo" config user.name Test
for file in README.md compose.yaml compose.production.yaml edge-compose.yaml \
  apparmor.d/dirextalk-runner-userns systemd/dirextalk-extension-runner@.service \
  systemd/dirextalk-core-runner@.service sysusers.d/dirextalk-split-agent.conf \
  scripts/provision-local.sh scripts/prepare-host-dependencies.sh scripts/prepare-runner-cgroups.sh \
  scripts/prepare-agent-start-local.sh scripts/refresh-message-mcp-token.sh scripts/start-local.sh \
  scripts/cleanup-local.sh scripts/cleanup-provision-failure.sh \
  scripts/update-agent-local.sh scripts/update-message-server-local.sh \
  scripts/runtime-01.sh scripts/runtime-02.sh scripts/runtime-03.sh scripts/runtime-04.sh \
  scripts/runtime-05.sh scripts/runtime-06.sh; do
  mkdir -p "$runtime_root/$(dirname "$file")"
  printf 'fixture %s\n' "$file" >"$runtime_root/$file"
done
git -C "$runtime_repo" add .
git -C "$runtime_repo" commit -qm fixture
split_revision=$(git -C "$runtime_repo" rev-parse HEAD:runtime)

pin=$tmp/release.env
bundle=$tmp/canonical-bundle.tar.gz
bundle_sha=$bundle.sha256
cat >"$pin" <<EOF
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
DIREXTALK_MESSAGE_SERVER_VERSION=v0.0.1
DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v0.0.1
DIREXTALK_MESSAGE_SOURCE_REVISION=1111111111111111111111111111111111111111
DIREXTALK_SPLIT_SOURCE_REVISION=1111111111111111111111111111111111111111
DIREXTALK_AGENT_VERSION=v0.0.1
DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent:v0.0.1
DIREXTALK_AGENT_SOURCE_REVISION=2222222222222222222222222222222222222222
DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=docker.io/pgvector/pgvector:pg18@sha256:$(printf 'e%.0s' {1..64})
DIREXTALK_CADDY_IMAGE_IMMUTABLE=docker.io/library/caddy@sha256:$(printf 'c%.0s' {1..64})
DIREXTALK_COTURN_IMAGE_IMMUTABLE=docker.io/coturn/coturn:4.6.3-alpine@sha256:$(printf 'd%.0s' {1..64})
EOF

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  pull) exit 0 ;;
  image)
    case "$3" in
      docker.io/dirextalk/message-server:latest|docker.io/dirextalk/message-server:v1.1.32)
        [ "${TEST_BAD_LABEL:-}" != message ] || { printf 'bad|bad\n'; exit 0; }
        if [ "${TEST_MOVE_LATEST:-false}" = true ] && [ "$3" = docker.io/dirextalk/message-server:latest ]; then
          count=0
          [ ! -f "$TEST_INSPECT_COUNT" ] || count=$(cat "$TEST_INSPECT_COUNT")
          count=$((count + 1))
          printf '%s\n' "$count" >"$TEST_INSPECT_COUNT"
          [ "$count" -lt 2 ] || { printf 'v1.1.33|cccccccccccccccccccccccccccccccccccccccc\n'; exit 0; }
        fi
        printf 'v1.1.32|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
        ;;
      docker.io/dirextalk/agent:latest|docker.io/dirextalk/agent:v1.0.69) printf 'v1.0.69|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      *) exit 2 ;;
    esac
    ;;
  run)
    case "$4" in
      /usr/bin/dirextalk-message-server) printf '%s\n' "${TEST_MESSAGE_PROBE:-v1.1.32}" ;;
      /usr/local/bin/dirextalk-agent|/usr/local/bin/dirextalk-extension-runner|/usr/local/bin/dirextalk-core-runner) printf 'v1.0.69\n' ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker"

run_prepare() {
  PATH="$tmp/bin:$PATH" \
  DIREXTALK_SPLIT_RUNTIME_ROOT="$runtime_root" \
  DIREXTALK_RELEASE_PIN_FILE="$pin" \
  DIREXTALK_RELEASE_BUNDLE_FILE="$bundle" \
  DIREXTALK_RELEASE_BUNDLE_SHA256_FILE="$bundle_sha" \
  TEST_INSPECT_COUNT="$tmp/message-inspects" \
    bash "$ROOT/scripts/render/prepare-production-release.sh"
}

run_prepare >"$tmp/success.out"
grep -Fqx 'DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.32' "$pin"
grep -Fqx 'DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.69' "$pin"
grep -Fqx 'DIREXTALK_MESSAGE_SERVER_VERSION=v1.1.32' "$pin"
grep -Fqx 'DIREXTALK_AGENT_VERSION=v1.0.69' "$pin"
grep -Fqx 'DIREXTALK_MESSAGE_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$pin"
grep -Fqx 'DIREXTALK_AGENT_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$pin"
grep -Fqx "DIREXTALK_SPLIT_SOURCE_REVISION=$split_revision" "$pin"
[ "$(tar -xOzf "$bundle" deploy/split-agent/SOURCE_REVISION)" = "$split_revision" ]
grep -Fqx "$(sha256sum "$bundle" | awk '{print $1}')  canonical-bundle.tar.gz" "$bundle_sha"

cp "$pin" "$tmp/preserved.env"
if TEST_MESSAGE_PROBE=v9.9.9 run_prepare >/dev/null 2>"$tmp/probe.err"; then
  echo 'release preparation accepted a binary version mismatch' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"

if TEST_MOVE_LATEST=true run_prepare >/dev/null 2>"$tmp/moved.err"; then
  echo 'release preparation accepted latest moving before artifact replacement' >&2
  exit 1
fi
grep -Fq 'changed while the production release was being prepared' "$tmp/moved.err"
cmp "$tmp/preserved.env" "$pin"

echo 'production release preparation ok'
