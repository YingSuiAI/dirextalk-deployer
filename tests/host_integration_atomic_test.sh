#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
apply="$ROOT/scripts/cloud-init/split/apply-host-integration.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/host/etc/systemd/system"

cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"%u:%g:%a"*) printf '0:0:%s\n' "$(/usr/bin/stat -c '%a' "${!#}")" ;;
  *"%u:%g"*) printf '0:0\n' ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$tmp/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
cat >"$tmp/bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'passwordauthentication no\npubkeyauthentication yes\n'
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  daemon-reload) exit "${DAEMON_RELOAD_STATUS:-0}" ;;
  enable) exit "${ENABLE_STATUS:-0}" ;;
  is-enabled) exit 1 ;;
  disable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$tmp/bin/"*

old=1111111111111111111111111111111111111111
target=2222222222222222222222222222222222222222
message_revision=3333333333333333333333333333333333333333
agent_revision=4444444444444444444444444444444444444444
message_image=docker.io/dirextalk/message-server@sha256:$(printf 'a%.0s' {1..64})
agent_image=docker.io/dirextalk/agent@sha256:$(printf 'b%.0s' {1..64})
caddy_image=docker.io/library/caddy@sha256:$(printf 'c%.0s' {1..64})
coturn_image=docker.io/coturn/coturn@sha256:$(printf 'd%.0s' {1..64})

stage="$tmp/stage"
mkdir -p "$stage/cloud-init/split" "$stage/updater"
chmod 0700 "$stage"
cp "$ROOT/scripts/cloud-init/split/authorize-split-source-revision.sh" "$stage/cloud-init/split/"
cp "$ROOT/scripts/cloud-init/split/advance-split-source-revision.sh" "$stage/cloud-init/split/"
for file in bootstrap-production.sh production-ops-common.sh recover-production.sh reconcile-production.sh reset-production.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stage/cloud-init/split/$file"
done
printf 'fixture\n' >"$stage/cloud-init/split/Caddyfile"
printf 'services: {}\n' >"$stage/cloud-init/split/edge-compose.override.yaml"
printf '[Unit]\nDescription=fixture\n' >"$stage/cloud-init/split/dirextalk-split-recovery.service"
cat >"$stage/cloud-init/split/release.env" <<EOF
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE=$message_image
DIREXTALK_MESSAGE_SOURCE_REVISION=$message_revision
DIREXTALK_SPLIT_SOURCE_REVISION=$target
DIREXTALK_AGENT_IMAGE_IMMUTABLE=$agent_image
DIREXTALK_AGENT_SOURCE_REVISION=$agent_revision
DIREXTALK_CADDY_IMAGE_IMMUTABLE=$caddy_image
DIREXTALK_COTURN_IMAGE_IMMUTABLE=$coturn_image
EOF
chmod 0400 "$stage/cloud-init/split/release.env"
for file in bootstrap-host.sh install.sh set-desired-state.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stage/updater/$file"
done
cat >"$stage/updater/reconcile-host.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
base=$2
[ "$(cat "$base/deploy/split-agent/SOURCE_REVISION")" = "$DIREXTALK_AUTHORIZED_SPLIT_SOURCE_REVISION" ]
grep -Fqx "SPLIT_SOURCE_REVISION=$EXPECTED_OLD" "$base/.env"
exit "${RECONCILE_STATUS:-0}"
EOF
printf 'fixture\n' >"$stage/updater/release.env"
printf '{}\n' >"$stage/updater/config.json"
printf '[Unit]\nDescription=updater fixture\n' >"$stage/updater/dirextalk-updater.service"
chmod 0755 "$stage/cloud-init/split/"*.sh "$stage/updater/"*.sh

bundle_root="$tmp/bundle-root"
split="$bundle_root/deploy/split-agent"
mkdir -p "$split/scripts"
printf '%s\n' "$target" >"$split/SOURCE_REVISION"
printf 'new-runtime\n' >"$split/current-file"
printf '#!/usr/bin/env bash\nexit 0\n' >"$split/scripts/update-message-server-local.sh"
chmod 0755 "$split/scripts/update-message-server-local.sh"
(cd "$split" && find . -type f ! -name SOURCE_FILES.sha256 -print | LC_ALL=C sort \
  | while IFS= read -r file; do sha256sum "$file"; done >SOURCE_FILES.sha256)
bundle="$stage/runtime.tar.gz"
tar -C "$bundle_root" -czf "$bundle" deploy

write_live() {
  base=$1
  rm -rf "$base"
  mkdir -p "$base/deploy/split-agent" "$base/production-ops" "$base/updater"
  printf 'removed-old-file\n' >"$base/deploy/split-agent/removed-file"
  printf 'old-ops\n' >"$base/production-ops/sentinel"
  printf 'old-updater\n' >"$base/updater/sentinel"
  cat >"$base/.env" <<EOF
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
MESSAGE_SERVER_IMAGE=$message_image
AGENT_IMAGE=$agent_image
CADDY_IMAGE=$caddy_image
COTURN_IMAGE=$coturn_image
MESSAGE_SOURCE_REVISION=$message_revision
SPLIT_SOURCE_REVISION=$old
AGENT_SOURCE_REVISION=$agent_revision
EOF
  printf '203.0.113.44\n' >"$base/stable-public-ip"
  chmod 0600 "$base/.env" "$base/stable-public-ip"
}

tree_digest() { find "$1" -type f ! -name .split-source-revision.lock -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; }
base="$tmp/live"
write_live "$base"
before=$(tree_digest "$base")
if RECONCILE_STATUS=17 EXPECTED_OLD="$old" PATH="$tmp/bin:$PATH" \
    DIREXTALK_HOST_INTEGRATION_ROOT="$tmp/host" \
    bash "$apply" "$stage" "$bundle" "$base" "$old" 203.0.113.44 >/dev/null 2>&1; then
  echo 'host integration accepted reconcile failure' >&2; exit 1
else status=$?; fi
[ "$status" -eq 1 ]
grep -Fqx "SPLIT_SOURCE_REVISION=$old" "$base/.env"
[ -f "$base/deploy/split-agent/current-file" ]
[ ! -e "$base/deploy/split-agent/removed-file" ]
[ ! -e "$base/production-ops/sentinel" ]
[ ! -e "$base/updater/sentinel" ]
# Once real reconcile begins, the transaction converges forward on retry
# because host-level updater/runtime side effects cannot be safely rolled back
# with directory swaps alone.
EXPECTED_OLD="$old" PATH="$tmp/bin:$PATH" DIREXTALK_HOST_INTEGRATION_ROOT="$tmp/host" \
  bash "$apply" "$stage" "$bundle" "$base" "$old" 203.0.113.44 >/dev/null
grep -Fqx "SPLIT_SOURCE_REVISION=$target" "$base/.env"

write_live "$base"
if RECONCILE_STATUS=3 EXPECTED_OLD="$old" PATH="$tmp/bin:$PATH" \
    DIREXTALK_HOST_INTEGRATION_ROOT="$tmp/host" \
    bash "$apply" "$stage" "$bundle" "$base" "$old" 203.0.113.44 >/dev/null 2>&1; then
  echo 'host integration accepted expected-negative reconcile' >&2; exit 1
else status=$?; fi
[ "$status" -eq 3 ]
grep -Fqx "SPLIT_SOURCE_REVISION=$old" "$base/.env"
[ -f "$base/deploy/split-agent/current-file" ]
[ ! -e "$base/deploy/split-agent/removed-file" ]

write_live "$base"
before=$(tree_digest "$base")
if ENABLE_STATUS=17 EXPECTED_OLD="$old" PATH="$tmp/bin:$PATH" \
    DIREXTALK_HOST_INTEGRATION_ROOT="$tmp/host" \
    bash "$apply" "$stage" "$bundle" "$base" "$old" 203.0.113.44 >/dev/null 2>&1; then
  echo 'host integration accepted pre-reconcile systemd failure' >&2; exit 1
else status=$?; fi
[ "$status" -eq 1 ]
[ "$before" = "$(tree_digest "$base")" ]
grep -Fqx "SPLIT_SOURCE_REVISION=$old" "$base/.env"

write_live "$base"
EXPECTED_OLD="$old" PATH="$tmp/bin:$PATH" DIREXTALK_HOST_INTEGRATION_ROOT="$tmp/host" \
  bash "$apply" "$stage" "$bundle" "$base" "$old" 203.0.113.44 >/dev/null
grep -Fqx "SPLIT_SOURCE_REVISION=$target" "$base/.env"
[ -f "$base/deploy/split-agent/current-file" ]
[ ! -e "$base/deploy/split-agent/removed-file" ]
[ ! -e "$base/production-ops/sentinel" ]
[ ! -e "$base/updater/sentinel" ]

# Bundle/release prebinding must fail before any live mutation.
write_live "$base"
printf '%s\n' 9999999999999999999999999999999999999999 >"$split/SOURCE_REVISION"
(cd "$split" && find . -type f ! -name SOURCE_FILES.sha256 -print | LC_ALL=C sort \
  | while IFS= read -r file; do sha256sum "$file"; done >SOURCE_FILES.sha256)
tar -C "$bundle_root" -czf "$bundle" deploy
before=$(tree_digest "$base")
if EXPECTED_OLD="$old" PATH="$tmp/bin:$PATH" DIREXTALK_HOST_INTEGRATION_ROOT="$tmp/host" \
    bash "$apply" "$stage" "$bundle" "$base" "$old" 203.0.113.44 >/dev/null 2>&1; then
  echo 'host integration accepted an unbound canonical bundle' >&2; exit 1
fi
[ "$before" = "$(tree_digest "$base")" ]
grep -Fqx "SPLIT_SOURCE_REVISION=$old" "$base/.env"

echo 'host integration atomic apply ok'
