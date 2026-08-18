#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
script=$script_dir/update-message-server-local.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-message-rollback.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
fake_bin=$tmp/bin
out=$tmp/out
mkdir -p "$fake_bin" "$out"
chmod 0700 "$out"

old_id=$(printf '1%.0s' {1..64})
rollback_id=$(printf '2%.0s' {1..64})
old_image_id=sha256:$(printf '3%.0s' {1..64})
target_image_id=sha256:$(printf '4%.0s' {1..64})
target_revision=$(printf '5%.0s' {1..40})

cat >"$out/.env" <<EOF
DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.39
DIREXTALK_MESSAGE_SERVER_VERSION=v1.1.39
DIREXTALK_MESSAGE_SOURCE_REVISION=$(printf '6%.0s' {1..40})
UNRELATED_ENV=preserve-me
EOF
cat >"$out/.manifest" <<'EOF'
compose_mode=production
stack_name=test-stack
EOF
cat >"$out/.cleanup-receipt" <<EOF
state=complete
control.env_identity=fixture
control.env_sha256=fixture
container.count=2
container.0.service=message-server
container.0.id=$old_id
container.0.project=test-stack
container.1.service=agent
container.1.id=$(printf '7%.0s' {1..64})
container.1.project=test-stack
unrelated.receipt=preserve-me
EOF
chmod 0400 "$out/.env" "$out/.manifest" "$out/.cleanup-receipt"
cp "$out/.env" "$tmp/original.env"

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$DOCKER_FIXTURE_LOG"
case "${1:-}" in
  inspect)
    case "${2:-}" in
      "$OLD_ID") printf '[{"Id":"%s","Image":"%s","Config":{"Image":"docker.io/dirextalk/message-server:v1.1.39"},"State":{"Health":{"Status":"healthy"}}}]\n' "$OLD_ID" "$OLD_IMAGE_ID" ;;
      "$ROLLBACK_ID") printf '[{"Id":"%s","Image":"%s","Config":{"Image":"docker.io/dirextalk/message-server:v1.1.39"},"State":{"Health":{"Status":"healthy"}}}]\n' "$ROLLBACK_ID" "$OLD_IMAGE_ID" ;;
      *) exit 1 ;;
    esac
    ;;
  image)
    case "${2:-}:${3:-}" in
      inspect:"$OLD_IMAGE_ID") printf 'v1.1.39\n' ;;
      inspect:fixture-target) printf 'v1.1.40|%s|%s\n' "$TARGET_IMAGE_ID" "$TARGET_REVISION" ;;
      tag:*) ;;
      *) exit 1 ;;
    esac
    ;;
  run) printf 'v1.1.40\n' ;;
  compose)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in up|ps) command=$1; shift; break ;; *) shift ;; esac
    done
    case "${command:-}" in
      up)
        if [ "${DIREXTALK_MESSAGE_SERVER_IMAGE:-}" = docker.io/dirextalk/message-server:v1.1.40 ]; then
          exit 17
        fi
        ;;
      ps) printf '%s\n' "$ROLLBACK_ID" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$fake_bin/docker"

if PATH="$fake_bin:$PATH" \
  DIREXTALK_MESSAGE_SERVER_UPDATE_TEST_FIXTURE=true \
  DIREXTALK_MESSAGE_SERVER_UPDATE_HEALTH_ATTEMPTS=1 \
  DIREXTALK_MESSAGE_SERVER_LOCAL_IMAGE_REF=fixture-target \
  DOCKER_FIXTURE_LOG="$tmp/docker.log" \
  OLD_ID="$old_id" ROLLBACK_ID="$rollback_id" \
  OLD_IMAGE_ID="$old_image_id" TARGET_IMAGE_ID="$target_image_id" TARGET_REVISION="$target_revision" \
  "$script" "$out" v1.1.40 >"$tmp/stdout" 2>"$tmp/stderr"; then
  echo 'failed message-server apply unexpectedly succeeded' >&2
  exit 1
fi

grep -Fq 'restoring previous local image after failed apply' "$tmp/stderr"
cmp "$tmp/original.env" "$out/.env"
grep -Fqx "container.0.id=$rollback_id" "$out/.cleanup-receipt"
grep -Fqx 'container.1.service=agent' "$out/.cleanup-receipt"
grep -Fqx 'unrelated.receipt=preserve-me' "$out/.cleanup-receipt"
[ "$(grep -Fc 'up -d --no-deps --force-recreate --no-build --pull never message-server' "$tmp/docker.log")" -eq 2 ]
grep -Fq "inspect $rollback_id" "$tmp/docker.log"
printf 'message-server failed-update exact image and receipt rollback verified\n'
