#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_repository() {
  local repository=$1 first_file=$2 second_file=$3
  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.email test@example.invalid
  git -C "$repository" config user.name Test
  printf 'artifact input\n' >"$repository/$first_file"
  if [ "$first_file" = server.go ]; then
    printf 'deploy/\n' >"$repository/.dockerignore"
    printf 'FROM scratch\n' >"$repository/Dockerfile"
  fi
  git -C "$repository" add .
  git -C "$repository" commit -qm 'artifact revision'
  git -C "$repository" rev-parse HEAD
  mkdir -p "$repository/$(dirname "$second_file")"
  printf 'deployment-only input\n' >"$repository/$second_file"
  git -C "$repository" add "$second_file"
  git -C "$repository" commit -qm 'deployment revision'
}

populate_message_split() {
  local repository=$1 file
  local files=(
    README.md
    apparmor.d/dirextalk-runner-userns
    compose.production.yaml
    compose.direct-tls.yaml
    edge-compose.yaml
    systemd/dirextalk-extension-runner@.service
    systemd/dirextalk-core-runner@.service
    sysusers.d/dirextalk-split-agent.conf
    scripts/provision-local.sh
    scripts/prepare-runner-cgroups.sh
    scripts/start-local.sh
    scripts/cleanup-local.sh
    scripts/cleanup-provision-failure.sh
    scripts/adopt-edge.sh
    scripts/cutover-edge.sh
    scripts/update-agent-local.sh
    scripts/update-message-server-local.sh
    scripts/runtime-01.sh
    scripts/runtime-02.sh
    scripts/runtime-03.sh
    scripts/runtime-04.sh
    scripts/runtime-05.sh
    scripts/runtime-06.sh
  )
  for file in "${files[@]}"; do
    mkdir -p "$repository/deploy/split-agent/$(dirname "$file")"
    printf 'fixture %s\n' "$file" >"$repository/deploy/split-agent/$file"
  done
  git -C "$repository" add deploy/split-agent
  git -C "$repository" commit -qm 'complete canonical split deployment fixture'
}

message_root=$tmp/message-server
agent_root=$tmp/agent
message_revision=$(make_repository "$message_root" server.go deploy/split-agent/compose.yaml)
agent_revision=$(make_repository "$agent_root" agent.go deploy/container/compose.local.yaml)
populate_message_split "$message_root"
message_head=$(git -C "$message_root" rev-parse HEAD)
agent_head=$(git -C "$agent_root" rev-parse HEAD)
[ "$message_revision" != "$message_head" ]
[ "$agent_revision" != "$agent_head" ]

message_digest=sha256:$(printf 'a%.0s' {1..64})
agent_digest=sha256:$(printf 'b%.0s' {1..64})
caddy_image=docker.io/library/caddy@sha256:$(printf 'c%.0s' {1..64})
coturn_image=docker.io/coturn/coturn:4.6.3-alpine@sha256:$(printf 'd%.0s' {1..64})
postgres_image=docker.io/pgvector/pgvector:pg18@sha256:$(printf 'e%.0s' {1..64})
pin=$tmp/release.env
bundle=$tmp/canonical-bundle.tar.gz
bundle_sha=$bundle.sha256
export DIREXTALK_RELEASE_BUNDLE_FILE=$bundle
export DIREXTALK_RELEASE_BUNDLE_SHA256_FILE=$bundle_sha
cat >"$pin" <<EOF
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
DIREXTALK_MESSAGE_SERVER_VERSION=v0.0.1
DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=docker.io/dirextalk/message-server@sha256:$(printf '1%.0s' {1..64})
DIREXTALK_MESSAGE_SOURCE_REVISION=$(printf '1%.0s' {1..40})
DIREXTALK_SPLIT_SOURCE_REVISION=$(printf '1%.0s' {1..40})
DIREXTALK_AGENT_VERSION=v0.0.1
DIREXTALK_AGENT_IMAGE_IMMUTABLE=docker.io/dirextalk/agent@sha256:$(printf '2%.0s' {1..64})
DIREXTALK_AGENT_SOURCE_REVISION=$(printf '2%.0s' {1..40})
DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=$postgres_image
DIREXTALK_CADDY_IMAGE_IMMUTABLE=$caddy_image
DIREXTALK_COTURN_IMAGE_IMMUTABLE=$coturn_image
EOF

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
reference=${4:?missing image reference}
format=${6:?missing format}
case "$reference" in
  docker.io/dirextalk/message-server:*) digest=$TEST_MESSAGE_DIGEST; version=v1.1.5; revision=$TEST_MESSAGE_REVISION; source=https://github.com/YingSuiAI/dirextalk-message-server ;;
  docker.io/dirextalk/message-server@*) digest=$TEST_MESSAGE_DIGEST; version=v1.1.5; revision=$TEST_MESSAGE_REVISION; source=https://github.com/YingSuiAI/dirextalk-message-server ;;
  docker.io/dirextalk/agent:*) digest=$TEST_AGENT_DIGEST; version=v1.0.3; revision=$TEST_AGENT_REVISION; source=https://github.com/YingSuiAI/dirextalk-agent ;;
  docker.io/dirextalk/agent@*) digest=$TEST_AGENT_DIGEST; version=v1.0.3; revision=$TEST_AGENT_REVISION; source=https://github.com/YingSuiAI/dirextalk-agent ;;
  *) exit 2 ;;
esac
if [ "${TEST_MOVE_VERSION_TAG:-}" = message ] \
  && [ "$reference" = docker.io/dirextalk/message-server:v1.1.5 ]; then
  count=0
  [ ! -f "$TEST_TAG_COUNTER" ] || count=$(cat "$TEST_TAG_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" >"$TEST_TAG_COUNTER"
  if [ "$count" -gt 1 ]; then
    digest=sha256:$(printf 'e%.0s' {1..64})
  fi
fi
if [ "${TEST_BAD_SOURCE:-}" = agent ] && [[ "$reference" == docker.io/dirextalk/agent@* ]]; then
  source=https://example.invalid/wrong
fi
case "$format" in
  *Manifest*)
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%064d","platform":{"os":"linux","architecture":"amd64"}}]}\n' "$digest" 0
    ;;
  *Image*)
    case "$reference" in
      docker.io/dirextalk/message-server@*) title='Dirextalk Message Server' ;;
      docker.io/dirextalk/agent@*) title='Dirextalk Agent' ;;
      *) exit 2 ;;
    esac
    if [ "${TEST_NO_SOURCE:-}" = agent ] && [[ "$reference" == docker.io/dirextalk/agent@* ]]; then
      printf '{"os":"linux","architecture":"amd64","config":{"Labels":{"org.opencontainers.image.title":"%s","org.opencontainers.image.version":"%s","org.opencontainers.image.revision":"%s"}}}\n' "$title" "$version" "$revision"
    else
      printf '{"os":"linux","architecture":"amd64","config":{"Labels":{"org.opencontainers.image.title":"%s","org.opencontainers.image.version":"%s","org.opencontainers.image.revision":"%s","org.opencontainers.image.source":"%s"}}}\n' "$title" "$version" "$revision" "$source"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker"
real_mv=$(command -v mv)
cat >"$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=${!#}
if [ -n "${TEST_FAIL_PUBLISH_DEST:-}" ] && [ "$target" = "$TEST_FAIL_PUBLISH_DEST" ] \
    && [ ! -e "$TEST_FAIL_PUBLISH_ONCE" ]; then
  : >"$TEST_FAIL_PUBLISH_ONCE"
  exit 88
fi
exec "$TEST_REAL_MV" "$@"
EOF
chmod 0755 "$tmp/bin/mv"
export TEST_REAL_MV=$real_mv

updater_before=$(sha256sum "$ROOT/scripts/updater/release.env")
PATH="$tmp/bin:$PATH" \
TEST_MESSAGE_DIGEST=$message_digest \
TEST_AGENT_DIGEST=$agent_digest \
TEST_MESSAGE_REVISION=$message_revision \
TEST_AGENT_REVISION=$agent_revision \
DIREXTALK_MESSAGE_SERVER_ROOT=$message_root \
DIREXTALK_AGENT_ROOT=$agent_root \
DIREXTALK_RELEASE_PIN_FILE=$pin \
  bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/success.out"

grep -Fqx 'DIREXTALK_MESSAGE_SERVER_VERSION=v1.1.5' "$pin"
grep -Fqx 'DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai' "$pin"
grep -Fqx "DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=docker.io/dirextalk/message-server@$message_digest" "$pin"
grep -Fqx "DIREXTALK_MESSAGE_SOURCE_REVISION=$message_revision" "$pin"
grep -Fqx "DIREXTALK_SPLIT_SOURCE_REVISION=$message_head" "$pin"
grep -Fqx 'DIREXTALK_AGENT_VERSION=v1.0.3' "$pin"
grep -Fqx "DIREXTALK_AGENT_IMAGE_IMMUTABLE=docker.io/dirextalk/agent@$agent_digest" "$pin"
grep -Fqx "DIREXTALK_AGENT_SOURCE_REVISION=$agent_revision" "$pin"
grep -Fqx "DIREXTALK_POSTGRES_IMAGE_IMMUTABLE=$postgres_image" "$pin"
grep -Fqx "DIREXTALK_CADDY_IMAGE_IMMUTABLE=$caddy_image" "$pin"
grep -Fqx "DIREXTALK_COTURN_IMAGE_IMMUTABLE=$coturn_image" "$pin"
[ "$(stat -c '%a' "$pin")" = 644 ]
if grep -Fq ':latest' "$pin"; then
  echo 'production release pin retained a mutable latest tag' >&2
  exit 1
fi
[ "$updater_before" = "$(sha256sum "$ROOT/scripts/updater/release.env")" ]
bundle_revision=$(tar -xOzf "$bundle" deploy/split-agent/SOURCE_REVISION)
[ "$bundle_revision" = "$message_head" ]
grep -Fqx "$(sha256sum "$bundle" | awk '{print $1}')  canonical-bundle.tar.gz" "$bundle_sha"
consumer_bundle=$tmp/consumer-canonical-bundle.tar.gz
DIREXTALK_SPLIT_BUNDLE_FILE=$bundle \
DIREXTALK_SPLIT_BUNDLE_SHA256_FILE=$bundle_sha \
  bash "$ROOT/scripts/render/render-split-bundle.sh" "$consumer_bundle"
cmp "$bundle" "$consumer_bundle"
[ "$(tar -xOzf "$consumer_bundle" deploy/split-agent/SOURCE_REVISION)" = \
  "$(sed -n 's/^DIREXTALK_SPLIT_SOURCE_REVISION=//p' "$pin")" ]

cp "$pin" "$tmp/publish-failure-preserved.env"
cp "$bundle" "$tmp/publish-failure-preserved.tar.gz"
cp "$bundle_sha" "$tmp/publish-failure-preserved.sha256"
if PATH="$tmp/bin:$PATH" \
  TEST_REAL_MV=$real_mv TEST_FAIL_PUBLISH_DEST=$bundle_sha \
  TEST_FAIL_PUBLISH_ONCE=$tmp/publish-failure-once \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/publish-failure.out" 2>"$tmp/publish-failure.err"; then
  echo 'production release preparation accepted a partial publication failure' >&2
  exit 1
fi
cmp "$tmp/publish-failure-preserved.env" "$pin"
cmp "$tmp/publish-failure-preserved.tar.gz" "$bundle"
cmp "$tmp/publish-failure-preserved.sha256" "$bundle_sha"
[ ! -e "$pin.prepare.lock" ]

cp "$pin" "$tmp/version-race-preserved.env"
cp "$bundle" "$tmp/version-race-preserved.tar.gz"
cp "$bundle_sha" "$tmp/version-race-preserved.sha256"
if PATH="$tmp/bin:$PATH" \
  TEST_MOVE_VERSION_TAG=message TEST_TAG_COUNTER=$tmp/version-tag-counter \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/version-race.out" 2>"$tmp/version-race.err"; then
  echo 'production release preparation accepted a moved version tag' >&2
  exit 1
fi
cmp "$tmp/version-race-preserved.env" "$pin"
cmp "$tmp/version-race-preserved.tar.gz" "$bundle"
cmp "$tmp/version-race-preserved.sha256" "$bundle_sha"

cp "$pin" "$tmp/preserved.env"
sed -i 's#^DIREXTALK_RELEASE_CATALOG_ORIGIN=.*#DIREXTALK_RELEASE_CATALOG_ORIGIN=https://invalid.example.test#' "$pin"
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/dev-origin.out" 2>"$tmp/dev-origin.err"; then
  echo 'production release preparation accepted the development catalog origin' >&2
  exit 1
fi
cp "$tmp/preserved.env" "$pin"

PATH="$tmp/bin:$PATH" \
TEST_NO_SOURCE=agent \
TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
DIREXTALK_RELEASE_PIN_FILE=$pin \
  bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/no-source.out"
cmp "$tmp/preserved.env" "$pin"

printf 'dirty\n' >"$agent_root/untracked"
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/dirty.out" 2>"$tmp/dirty.err"; then
  echo 'release preparation accepted a dirty Agent sibling' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"
rm "$agent_root/untracked"

if PATH="$tmp/bin:$PATH" \
  TEST_BAD_SOURCE=agent \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/source.out" 2>"$tmp/source.err"; then
  echo 'release preparation accepted an unexpected source repository label' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"

printf 'image-affecting change\n' >"$message_root/server.go"
git -C "$message_root" add server.go
git -C "$message_root" commit -qm 'message binary input changed'
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/message-binary.out" 2>"$tmp/message-binary.err"; then
  echo 'release preparation accepted a Message Server binary input after its image revision' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"
printf 'artifact input\n' >"$message_root/server.go"
git -C "$message_root" add server.go
git -C "$message_root" commit -qm 'restore message binary input'

git -C "$message_root" rm -q server.go
git -C "$message_root" commit -qm 'delete message binary input'
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/message-delete.out" 2>"$tmp/message-delete.err"; then
  echo 'release preparation accepted a deleted Message Server image input' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"
git -C "$message_root" show "$message_revision:server.go" >"$message_root/server.go"
git -C "$message_root" add server.go
git -C "$message_root" commit -qm 'restore deleted message binary input'

printf 'binary input\n' >"$agent_root/runtime.go"
git -C "$agent_root" add runtime.go
git -C "$agent_root" commit -qm 'binary input changed'
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/binary.out" 2>"$tmp/binary.err"; then
  echo 'release preparation accepted an Agent binary input after its image revision' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"
git -C "$agent_root" rm -q runtime.go
git -C "$agent_root" commit -qm 'remove changed Agent binary input'

mkdir -p "$message_root/deploy/other"
printf 'unrelated deploy input\n' >"$message_root/deploy/other/tool.sh"
git -C "$message_root" add deploy/other/tool.sh
git -C "$message_root" commit -qm 'add unrelated deploy input'
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/unrelated-deploy.out" 2>"$tmp/unrelated-deploy.err"; then
  echo 'release preparation accepted an unrelated deploy path after the image revision' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"
git -C "$message_root" rm -q deploy/other/tool.sh
git -C "$message_root" commit -qm 'remove unrelated deploy input'

printf 'data/\n' >"$message_root/.dockerignore"
git -C "$message_root" add .dockerignore
git -C "$message_root" commit -qm 'make split tooling part of image context'
if PATH="$tmp/bin:$PATH" \
  TEST_MESSAGE_DIGEST=$message_digest TEST_AGENT_DIGEST=$agent_digest \
  TEST_MESSAGE_REVISION=$message_revision TEST_AGENT_REVISION=$agent_revision \
  DIREXTALK_MESSAGE_SERVER_ROOT=$message_root DIREXTALK_AGENT_ROOT=$agent_root \
  DIREXTALK_RELEASE_PIN_FILE=$pin \
    bash "$ROOT/scripts/render/prepare-production-release.sh" >"$tmp/build-context.out" 2>"$tmp/build-context.err"; then
  echo 'release preparation reused an image after split tooling entered its build context' >&2
  exit 1
fi
cmp "$tmp/preserved.env" "$pin"

echo 'production release preparation ok'
