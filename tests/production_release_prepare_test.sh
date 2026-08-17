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
DIREXTALK_SPLIT_SOURCE_REVISION=1111111111111111111111111111111111111111
DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=docker.io/pgvector/pgvector:pg18@sha256:$(printf 'e%.0s' {1..64})
DIREXTALK_CADDY_IMAGE_IMMUTABLE=docker.io/library/caddy@sha256:$(printf 'c%.0s' {1..64})
DIREXTALK_COTURN_IMAGE_IMMUTABLE=docker.io/coturn/coturn:4.6.3-alpine@sha256:$(printf 'd%.0s' {1..64})
EOF

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo 'release preparation must not inspect application images' >&2
exit 99
EOF
chmod 0755 "$tmp/bin/docker"

run_prepare() {
  PATH="$tmp/bin:$PATH" \
  DIREXTALK_SPLIT_RUNTIME_ROOT="$runtime_root" \
  DIREXTALK_RELEASE_PIN_FILE="$pin" \
  DIREXTALK_RELEASE_BUNDLE_FILE="$bundle" \
  DIREXTALK_RELEASE_BUNDLE_SHA256_FILE="$bundle_sha" \
    bash "$ROOT/scripts/render/prepare-production-release.sh"
}

run_prepare >"$tmp/success.out"
grep -Fqx "DIREXTALK_SPLIT_SOURCE_REVISION=$split_revision" "$pin"
grep -Fqx 'DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai' "$pin"
if grep -Eq '^DIREXTALK_(MESSAGE_SERVER|MESSAGE_SOURCE|AGENT_)' "$pin"; then
  echo 'release preparation wrote static application pins' >&2
  exit 1
fi
[ "$(tar -xOzf "$bundle" deploy/split-agent/SOURCE_REVISION)" = "$split_revision" ]
grep -Fqx "$(sha256sum "$bundle" | awk '{print $1}')  canonical-bundle.tar.gz" "$bundle_sha"
grep -Fqx "Prepared Deployer production split release $split_revision" "$tmp/success.out"

# Invalid static metadata fails before replacing the existing artifacts.
cp "$pin" "$tmp/preserved.env"
sed -i 's#https://imadmin.dirextalk.ai#https://invalid.test#' "$pin"
cp "$pin" "$tmp/invalid.env"
if run_prepare >/dev/null 2>"$tmp/invalid.err"; then
  echo 'release preparation accepted an invalid catalog origin' >&2
  exit 1
fi
cmp "$tmp/invalid.env" "$pin"

echo 'production Deployer release preparation ok'
