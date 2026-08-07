#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
consumer=$ROOT/scripts/cloud-init/split/bootstrap-production.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=$tmp/production
split=$base/deploy/split-agent
fakebin=$tmp/fakebin
mkdir -p "$split/scripts" "$fakebin"

cat >"$split/scripts/prepare-runner-cgroups.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'DIREXTALK_RUNNER_PREPARED=true'
EOF
cat >"$split/scripts/provision-local.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=$1
[ ! -e "$DIREXTALK_TEST_RESOURCE" ] || { echo 'fresh network already exists' >&2; exit 71; }
count=0
[ ! -f "$DIREXTALK_TEST_PROVISION_COUNT" ] || count=$(cat "$DIREXTALK_TEST_PROVISION_COUNT")
printf '%s\n' "$((count + 1))" >"$DIREXTALK_TEST_PROVISION_COUNT"
mkdir -m 0700 "$out"
printf 'stack=%s\n' "$DIREXTALK_SPLIT_STACK_NAME" >"$out/.env"
printf 'stack_name=%s\n' "$DIREXTALK_SPLIT_STACK_NAME" >"$out/.manifest"
chmod 0400 "$out/.env" "$out/.manifest"
EOF
cat >"$split/scripts/start-local.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=$(dirname "$1")
count=0
[ ! -f "$DIREXTALK_TEST_START_COUNT" ] || count=$(cat "$DIREXTALK_TEST_START_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$DIREXTALK_TEST_START_COUNT"
if [ "$count" -eq 1 ]; then
  [ "${DIREXTALK_TEST_NO_RECEIPT:-false}" != true ] || exit 42
  : >"$DIREXTALK_TEST_RESOURCE"
  printf '# receipt\nstate=incomplete\n' >"$out/.cleanup-receipt"
  chmod 0400 "$out/.cleanup-receipt"
  exit 42
fi
EOF
cat >"$split/scripts/cleanup-local.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = --purge ] || exit 91
[ -f "$2/.cleanup-receipt" ] || exit 92
[ -e "$DIREXTALK_TEST_RESOURCE" ] || exit 93
[ -z "${DIREXTALK_TEST_CLEANUP_LOCAL_STATUS:-}" ] || exit "$DIREXTALK_TEST_CLEANUP_LOCAL_STATUS"
printf 'cleanup-local %s\n' "$1" >>"$DIREXTALK_TEST_CLEANUP_CALLS"
rm -f "$DIREXTALK_TEST_RESOURCE"
EOF
cat >"$split/scripts/cleanup-provision-failure.sh" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected provision cleanup\n' >>"$DIREXTALK_TEST_CLEANUP_CALLS"
exit "${DIREXTALK_TEST_PROVISION_CLEANUP_STATUS:-94}"
EOF
cat >"$split/scripts/update-message-server-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$split/scripts/export-portal-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"ready":true}\n' >"$2"
chmod 0400 "$2"
EOF
chmod 0755 "$split/scripts/"*.sh
: >"$split/compose.production.yaml"
cat >"$split/edge-compose.yaml" <<'EOF'
services:
  caddy: {}
EOF
printf '%s\n' cccccccccccccccccccccccccccccccccccccccc >"$split/SOURCE_REVISION"
(cd "$split" && find . -type f ! -name SOURCE_FILES.sha256 -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum >SOURCE_FILES.sha256)

cat >"$base/.env" <<'EOF'
DOMAIN=retry.example.test
MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AGENT_IMAGE=docker.io/dirextalk/agent@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
POSTGRES_IMAGE=docker.io/pgvector/pgvector:pg18@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
CADDY_IMAGE=docker.io/library/caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
COTURN_IMAGE=docker.io/coturn/coturn:4.6.3-alpine@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
MESSAGE_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SPLIT_SOURCE_REVISION=cccccccccccccccccccccccccccccccccccccccc
AGENT_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai
EOF
chmod 0600 "$base/.env"
printf '%s\n' 203.0.113.92 >"$base/stable-public-ip"
chmod 0600 "$base/stable-public-ip"

cat >"$fakebin/stat" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/.env"|*"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/stable-public-ip") printf '%s\n' '0:600' ;;
  *"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/edge.env") printf '%s\n' '0:400' ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$fakebin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' volume create '*) printf '%s\n' volume ;;
  *' compose '*' config --quiet '*) ;;
  *' compose '*' pull '*) ;;
  *' compose '*' up -d --wait '*) ;;
  *' compose '*' ps -q caddy '*) printf 'f%.0s' {1..64}; printf '\n' ;;
  *) echo "unexpected docker call: $*" >&2; exit 95 ;;
esac
EOF
chmod 0755 "$fakebin/stat" "$fakebin/docker"
cp -a "$base" "$tmp/pristine"

export DIREXTALK_BOOTSTRAP_BASE=$base
export DIREXTALK_TEST_RESOURCE=$tmp/fresh-network
export DIREXTALK_TEST_PROVISION_COUNT=$tmp/provision-count
export DIREXTALK_TEST_START_COUNT=$tmp/start-count
export DIREXTALK_TEST_CLEANUP_CALLS=$tmp/cleanup-calls

if PATH="$fakebin:$PATH" bash "$consumer" >"$tmp/first.out" 2>"$tmp/first.err"; then
  echo 'first bootstrap unexpectedly succeeded' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 42 ] || { cat "$tmp/first.err" >&2; exit 1; }
grep -Fqx 'cleanup-local --purge' "$DIREXTALK_TEST_CLEANUP_CALLS"
grep -Fq 'partial fresh stack was cleaned for retry' "$tmp/first.err"
[ ! -e "$DIREXTALK_TEST_RESOURCE" ]
[ ! -e "$base/split" ]
[ "$(cat "$DIREXTALK_TEST_PROVISION_COUNT")" -eq 1 ]

PATH="$fakebin:$PATH" bash "$consumer" >"$tmp/retry.out" 2>"$tmp/retry.err"
[ "$(cat "$DIREXTALK_TEST_PROVISION_COUNT")" -eq 2 ]
[ "$(cat "$DIREXTALK_TEST_START_COUNT")" -eq 2 ]
[ -f "$base/.split-deploy-done" ]
[ -f "$base/p2p/bootstrap.json" ]
[ "$(cat "$base/.split-bootstrap-stage")" = completed ]

# Exit 3 from the no-receipt wrapper is an expected negative state, not proof
# that every partial resource was removed. Preserve the controls fail closed.
negative=$tmp/negative
cp -a "$tmp/pristine" "$negative"
if PATH="$fakebin:$PATH" \
    DIREXTALK_BOOTSTRAP_BASE="$negative" \
    DIREXTALK_TEST_RESOURCE="$tmp/negative-resource" \
    DIREXTALK_TEST_PROVISION_COUNT="$tmp/negative-provision-count" \
    DIREXTALK_TEST_START_COUNT="$tmp/negative-start-count" \
    DIREXTALK_TEST_CLEANUP_CALLS="$tmp/negative-cleanup-calls" \
    DIREXTALK_TEST_NO_RECEIPT=true \
    DIREXTALK_TEST_PROVISION_CLEANUP_STATUS=3 \
    bash "$consumer" >"$tmp/negative.out" 2>"$tmp/negative.err"; then
  echo 'expected-negative cleanup bootstrap unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'provision cleanup stopped in an expected negative state' "$tmp/negative.err"
[ -d "$negative/split" ]

# Infrastructure cleanup failure is separately reported and also preserves
# the receipt-bound directory and resource for an operator-safe retry.
infra=$tmp/infra
cp -a "$tmp/pristine" "$infra"
if PATH="$fakebin:$PATH" \
    DIREXTALK_BOOTSTRAP_BASE="$infra" \
    DIREXTALK_TEST_RESOURCE="$tmp/infra-resource" \
    DIREXTALK_TEST_PROVISION_COUNT="$tmp/infra-provision-count" \
    DIREXTALK_TEST_START_COUNT="$tmp/infra-start-count" \
    DIREXTALK_TEST_CLEANUP_CALLS="$tmp/infra-cleanup-calls" \
    DIREXTALK_TEST_CLEANUP_LOCAL_STATUS=74 \
    bash "$consumer" >"$tmp/infra.out" 2>"$tmp/infra.err"; then
  echo 'infrastructure cleanup failure bootstrap unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'stack cleanup failed (status 74)' "$tmp/infra.err"
[ -d "$infra/split" ]
[ -e "$tmp/infra-resource" ]

echo 'production bootstrap first-start failure cleanup and retry test passed'
