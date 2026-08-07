#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
helper="$ROOT/scripts/cloud-init/split/advance-split-source-revision.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"%u:%g:%a"*) printf '0:0:%s\n' "$(/usr/bin/stat -c '%a' "${!#}")" ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$tmp/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit "${CHOWN_STATUS:-0}"
EOF
cat >"$tmp/bin/install" <<'EOF'
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
chmod 0755 "$tmp/bin/"*

old=1111111111111111111111111111111111111111
current=2222222222222222222222222222222222222222
message_revision=3333333333333333333333333333333333333333
agent_revision=4444444444444444444444444444444444444444
message_image=docker.io/dirextalk/message-server@sha256:$(printf 'a%.0s' {1..64})
agent_image=docker.io/dirextalk/agent@sha256:$(printf 'b%.0s' {1..64})
caddy_image=docker.io/library/caddy@sha256:$(printf 'c%.0s' {1..64})
coturn_image=docker.io/coturn/coturn:4.6.3-alpine@sha256:$(printf 'd%.0s' {1..64})

write_pin() {
  [ ! -e "$tmp/release.env" ] || chmod 0600 "$tmp/release.env"
  cat >"$tmp/release.env" <<EOF
DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=$message_image
DIREXTALK_MESSAGE_SOURCE_REVISION=$message_revision
DIREXTALK_SPLIT_SOURCE_REVISION=$current
DIREXTALK_AGENT_IMAGE_IMMUTABLE=$agent_image
DIREXTALK_AGENT_SOURCE_REVISION=$agent_revision
DIREXTALK_CADDY_IMAGE_IMMUTABLE=$caddy_image
DIREXTALK_COTURN_IMAGE_IMMUTABLE=$coturn_image
EOF
  chmod 0400 "$tmp/release.env"
}
write_env() {
  cat >"$tmp/.env" <<EOF
DOMAIN=service.example.test
MESSAGE_SERVER_IMAGE=$message_image
AGENT_IMAGE=$agent_image
CADDY_IMAGE=$caddy_image
COTURN_IMAGE=$coturn_image
MESSAGE_SOURCE_REVISION=$message_revision
SPLIT_SOURCE_REVISION=$old
AGENT_SOURCE_REVISION=$agent_revision
UNRELATED_KEY=preserved
EOF
  chmod 0600 "$tmp/.env"
  printf '203.0.113.44\n' >"$tmp/stable-public-ip"
  chmod 0600 "$tmp/stable-public-ip"
}

write_pin; write_env
before_unrelated=$(grep -v '^SPLIT_SOURCE_REVISION=' "$tmp/.env")
PATH="$tmp/bin:$PATH" bash "$helper" "$tmp/.env" "$old" "$tmp/release.env" >/dev/null
[ "$(grep -c '^SPLIT_SOURCE_REVISION=' "$tmp/.env")" -eq 1 ]
grep -Fqx "SPLIT_SOURCE_REVISION=$current" "$tmp/.env"
[ "$before_unrelated" = "$(grep -v '^SPLIT_SOURCE_REVISION=' "$tmp/.env")" ]
[ "$(stat -c '%a' "$tmp/.env")" = 600 ]

write_env
sed -i "s#^AGENT_IMAGE=.*#AGENT_IMAGE=docker.io/dirextalk/agent@sha256:$(printf 'e%.0s' {1..64})#" "$tmp/.env"
if PATH="$tmp/bin:$PATH" bash "$helper" "$tmp/.env" "$old" "$tmp/release.env" >/dev/null 2>&1; then
  echo 'split source advance accepted a changed business image pin' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fqx "SPLIT_SOURCE_REVISION=$old" "$tmp/.env"

write_env
printf 'SPLIT_SOURCE_REVISION=%s\n' "$old" >>"$tmp/.env"
if PATH="$tmp/bin:$PATH" bash "$helper" "$tmp/.env" "$old" "$tmp/release.env" >/dev/null 2>&1; then
  echo 'split source advance accepted a duplicate protected key' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]

# The real authorization-staging wrapper must preserve its three-state result
# without touching any runtime input when authorization does not succeed.
authorization="$ROOT/scripts/cloud-init/split/authorize-split-source-revision.sh"
mkdir -p "$tmp/runtime"
printf 'runtime-before\n' >"$tmp/runtime/sentinel"
cat >"$tmp/source-helper.sh" <<'EOF'
#!/usr/bin/env bash
exit "${AUTH_HELPER_STATUS:-0}"
EOF
chmod 0755 "$tmp/source-helper.sh"
write_pin; write_env
for expected_status in 3 1; do
  before=$(sha256sum "$tmp/runtime/sentinel")
  if AUTH_HELPER_STATUS=$expected_status PATH="$tmp/bin:$PATH" \
      bash "$authorization" "$tmp/source-helper.sh" "$tmp/release.env" "$tmp/.env" "$old" \
      203.0.113.44 \
      >/dev/null 2>&1; then
    echo "authorization staging accepted helper status $expected_status" >&2
    exit 1
  else
    status=$?
  fi
  case "$expected_status" in
    3) [ "$status" -eq 3 ] ;;
    *) [ "$status" -eq 1 ] ;;
  esac
  [ "$before" = "$(sha256sum "$tmp/runtime/sentinel")" ]
  if find "$tmp" -maxdepth 1 -type d -name '.split-source-authorization.*' | grep -q .; then
    echo 'authorization staging was not cleaned after failure' >&2
    exit 1
  fi
done

# Execute the real remote mutation consumer. Authorization failures must leave
# both the canonical runtime and updater integration byte-for-byte unchanged.
apply_integration="$ROOT/scripts/cloud-init/split/apply-host-integration.sh"
transport="$tmp/transport"
remote_base="$tmp/remote-base"
mkdir -p "$transport/cloud-init/split" "$transport/updater" \
  "$remote_base/deploy/split-agent" "$remote_base/updater"
chmod 0700 "$transport"
cp "$authorization" "$transport/cloud-init/split/authorize-split-source-revision.sh"
cp "$tmp/source-helper.sh" "$transport/cloud-init/split/advance-split-source-revision.sh"
cp "$tmp/release.env" "$transport/cloud-init/split/release.env"
cp "$tmp/.env" "$remote_base/.env"
cp "$tmp/stable-public-ip" "$remote_base/stable-public-ip"
printf 'runtime-before\n' >"$remote_base/deploy/split-agent/sentinel"
printf 'updater-before\n' >"$remote_base/updater/sentinel"
printf 'not-read-before-authorization\n' >"$transport/split-bundle.tar.gz"
for expected_status in 3 1; do
  before=$(find "$remote_base" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
  if AUTH_HELPER_STATUS=$expected_status PATH="$tmp/bin:$PATH" \
      bash "$apply_integration" "$transport" "$transport/split-bundle.tar.gz" \
      "$remote_base" "$old" 203.0.113.44 >/dev/null 2>&1; then
    echo "host integration consumer accepted authorization status $expected_status" >&2
    exit 1
  else
    status=$?
  fi
  case "$expected_status" in
    3) [ "$status" -eq 3 ] ;;
    *) [ "$status" -eq 1 ] ;;
  esac
  [ "$before" = "$(find "$remote_base" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)" ] || {
    echo "host integration consumer mutated live runtime after authorization status $expected_status" >&2
    exit 1
  }
done

echo 'split source revision advance ok'
