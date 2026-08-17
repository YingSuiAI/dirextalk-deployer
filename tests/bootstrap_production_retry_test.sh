#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
consumer=$tmp/bootstrap-production.sh
sed "s#/usr/local/libexec/dirextalk/split-agent#$tmp/runner-libexec#g" \
  "$ROOT/scripts/cloud-init/split/bootstrap-production.sh" >"$consumer"
cp "$ROOT/scripts/cloud-init/split/Caddyfile" "$ROOT/scripts/cloud-init/split/edge-compose.override.yaml" "$tmp/"
base=$tmp/production
split=$base/deploy/split-agent
fakebin=$tmp/fakebin
mkdir -p "$split/scripts" "$split/systemd" "$split/sysusers.d" "$split/apparmor.d" "$fakebin"

cat >"$split/scripts/prepare-runner-cgroups.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[ ! -f "$DIREXTALK_TEST_PREPARATION_COUNT" ] || count=$(cat "$DIREXTALK_TEST_PREPARATION_COUNT")
printf '%s\n' "$((count + 1))" >"$DIREXTALK_TEST_PREPARATION_COUNT"
: >"$DIREXTALK_TEST_RUNNER_INTEGRATION"
printf 'prepare %s\n' "$((count + 1))" >>"$DIREXTALK_TEST_CLEANUP_CALLS"
printf '%s\n' \
  'DIREXTALK_RUNNER_PREPARED=true' \
  "DIREXTALK_RUNNER_APPARMOR_PROFILE_PATH=$DIREXTALK_TEST_RUNNER_INTEGRATION" \
  "DIREXTALK_RUNNER_APPARMOR_MANAGER_PATH=$(cd "$(dirname "$0")" && pwd -P)/manage-runner-apparmor.sh" \
  "DIREXTALK_RUNNER_PREP_HELPER_PATH=$(cd "$(dirname "$0")" && pwd -P)/prepare-runner-cgroups.sh"
EOF
cat >"$split/scripts/provision-local.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=$1
[ -f "${DIREXTALK_RUNNER_APPARMOR_PROFILE_PATH:-}" ] || {
  echo 'runner host integration is unavailable' >&2
  exit 72
}
[ ! -e "$DIREXTALK_TEST_RESOURCE" ] || { echo 'fresh network already exists' >&2; exit 71; }
count=0
[ ! -f "$DIREXTALK_TEST_PROVISION_COUNT" ] || count=$(cat "$DIREXTALK_TEST_PROVISION_COUNT")
printf '%s\n' "$((count + 1))" >"$DIREXTALK_TEST_PROVISION_COUNT"
mkdir -m 0700 "$out"
[ "${DIREXTALK_TEST_FAIL_EMPTY_PROVISION:-false}" != true ] || exit 73
mkdir -p "$out/static-sites/public"
printf 'stack=%s\n' "$DIREXTALK_SPLIT_STACK_NAME" >"$out/.env"
printf 'DIREXTALK_STATIC_SITES_ROOT=%s\n' "$out/static-sites" >>"$out/.env"
printf 'DIREXTALK_MESSAGE_SERVER_IMAGE=%s\n' "$DIREXTALK_MESSAGE_SERVER_IMAGE" >>"$out/.env"
printf 'DIREXTALK_MESSAGE_SERVER_VERSION=%s\n' "$DIREXTALK_MESSAGE_SERVER_VERSION" >>"$out/.env"
printf 'DIREXTALK_MESSAGE_SOURCE_REVISION=%s\n' "$DIREXTALK_MESSAGE_SOURCE_REVISION" >>"$out/.env"
printf 'DIREXTALK_AGENT_IMAGE=%s\n' "$DIREXTALK_AGENT_IMAGE" >>"$out/.env"
printf 'DIREXTALK_AGENT_VERSION=%s\n' "$DIREXTALK_AGENT_VERSION" >>"$out/.env"
printf 'DIREXTALK_AGENT_SOURCE_REVISION=%s\n' "$DIREXTALK_AGENT_SOURCE_REVISION" >>"$out/.env"
printf 'stack_name=%s\n' "$DIREXTALK_SPLIT_STACK_NAME" >"$out/.manifest"
chmod 0400 "$out/.env" "$out/.manifest"
EOF
cat >"$split/scripts/manage-runner-apparmor.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$split/scripts/start-local.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=$(dirname "$1")
count=0
[ ! -f "$DIREXTALK_TEST_START_COUNT" ] || count=$(cat "$DIREXTALK_TEST_START_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$DIREXTALK_TEST_START_COUNT"
printf 'start %s\n' "$count" >>"$DIREXTALK_TEST_CLEANUP_CALLS"
if [ "${DIREXTALK_TEST_AGENT_ATTENTION:-false}" = true ]; then
  : >"$DIREXTALK_TEST_RESOURCE"
  printf '# receipt\nstate=complete\n' >"$out/.cleanup-receipt"
  chmod 0400 "$out/.cleanup-receipt"
  exit 3
fi
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
rm -f "$DIREXTALK_TEST_RUNNER_INTEGRATION"
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
cat >"$split/scripts/prepare-host-dependencies.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$split/scripts/export-portal-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"ready":true}\n' >"$2"
chmod 0400 "$2"
EOF
chmod 0755 "$split/scripts/"*.sh
printf '%s\n' extension >"$split/systemd/dirextalk-extension-runner@.service"
printf '%s\n' core >"$split/systemd/dirextalk-core-runner@.service"
printf '%s\n' users >"$split/sysusers.d/dirextalk-split-agent.conf"
printf '%s\n' apparmor >"$split/apparmor.d/dirextalk-runner-userns"
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
chmod 0600 "$base/.env"
printf '%s\n' 203.0.113.92 >"$base/stable-public-ip"
chmod 0600 "$base/stable-public-ip"

cat >"$fakebin/stat" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/.env"|*"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/stable-public-ip") printf '%s\n' '0:600' ;;
  *"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/edge.env"|*"%u:%a"*"$DIREXTALK_BOOTSTRAP_BASE/split/.env") printf '%s\n' '0:400' ;;
  *"%u:%g:%a"*"$DIREXTALK_BOOTSTRAP_BASE/split") printf '%s\n' '0:0:700' ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$fakebin/install" <<'EOF'
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
cat >"$fakebin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' pull --platform linux/amd64 docker.io/dirextalk/message-server:v1.1.32 '*) ;;
  *' pull --platform linux/amd64 docker.io/dirextalk/agent:v1.0.'*) ;;
  *' image inspect docker.io/dirextalk/message-server:v1.1.32 '*) printf '%s\n' 'v1.1.32|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
  *' image inspect docker.io/dirextalk/agent:v1.0.'*) printf '%s|%s\n' "${DIREXTALK_TEST_AGENT_VERSION:-v1.0.69}" "${DIREXTALK_TEST_AGENT_REVISION:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" ;;
  *' run --rm --entrypoint /usr/bin/dirextalk-message-server '*) printf '%s\n' v1.1.32 ;;
  *' run --rm --entrypoint /usr/local/bin/dirextalk-'*) printf '%s\n' "${DIREXTALK_TEST_AGENT_VERSION:-v1.0.69}" ;;
  *' volume create '*) printf '%s\n' volume ;;
  *' compose '*' config --quiet '*) ;;
  *' compose '*' pull '*) ;;
  *' compose '*' up -d --wait '*) ;;
  *' compose '*' ps -q caddy '*) printf 'f%.0s' {1..64}; printf '\n' ;;
  *) echo "unexpected docker call: $*" >&2; exit 95 ;;
esac
EOF
chmod 0755 "$fakebin/stat" "$fakebin/install" "$fakebin/docker"
cp -a "$base" "$tmp/pristine"

export DIREXTALK_BOOTSTRAP_BASE=$base
export DIREXTALK_TEST_RESOURCE=$tmp/fresh-network
export DIREXTALK_TEST_PROVISION_COUNT=$tmp/provision-count
export DIREXTALK_TEST_START_COUNT=$tmp/start-count
export DIREXTALK_TEST_CLEANUP_CALLS=$tmp/cleanup-calls
export DIREXTALK_TEST_PREPARATION_COUNT=$tmp/preparation-count
export DIREXTALK_TEST_RUNNER_INTEGRATION=$tmp/runner-integration
export DIREXTALK_TEST_AGENT_VERSION=${DIREXTALK_TEST_AGENT_VERSION:-v1.0.69}
export DIREXTALK_TEST_AGENT_REVISION=${DIREXTALK_TEST_AGENT_REVISION:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}

if PATH="$fakebin:$PATH" bash "$consumer" >"$tmp/first.out" 2>"$tmp/first.err"; then
  echo 'first bootstrap unexpectedly succeeded' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ] || { cat "$tmp/first.err" >&2; exit 1; }
grep -Fqx 'cleanup-local --purge' "$DIREXTALK_TEST_CLEANUP_CALLS"
grep -Fq 'partial fresh stack was cleaned for retry' "$tmp/first.err"
[ ! -e "$DIREXTALK_TEST_RESOURCE" ]
[ ! -e "$base/split" ]
[ ! -e "$base/runner-preparation.env" ]
[ ! -e "$DIREXTALK_TEST_RUNNER_INTEGRATION" ]
[ "$(cat "$DIREXTALK_TEST_PROVISION_COUNT")" -eq 1 ]
[ "$(cat "$DIREXTALK_TEST_PREPARATION_COUNT")" -eq 1 ]

PATH="$fakebin:$PATH" bash "$consumer" >"$tmp/retry.out" 2>"$tmp/retry.err"
[ "$(cat "$DIREXTALK_TEST_PROVISION_COUNT")" -eq 2 ]
[ "$(cat "$DIREXTALK_TEST_START_COUNT")" -eq 2 ]
[ "$(cat "$DIREXTALK_TEST_PREPARATION_COUNT")" -eq 2 ]
[ -f "$DIREXTALK_TEST_RUNNER_INTEGRATION" ]
[ -f "$base/runner-preparation.env" ]
cat >"$tmp/expected-retry-events" <<'EOF'
prepare 1
start 1
cleanup-local --purge
prepare 2
start 2
EOF
cmp "$tmp/expected-retry-events" "$DIREXTALK_TEST_CLEANUP_CALLS"
[ -f "$base/.split-deploy-done" ]
[ -f "$base/p2p/bootstrap.json" ]
[ "$(cat "$base/.split-bootstrap-stage")" = completed ]

# A healthy Message Server with an Agent startup failure remains available for
# messaging and bootstrap export. The protected marker makes the next host
# bootstrap use receipt-bound Agent recovery instead of another fresh start.
attention=$tmp/attention
cp -a "$tmp/pristine" "$attention"
if PATH="$fakebin:$PATH" \
    DIREXTALK_BOOTSTRAP_BASE="$attention" \
    DIREXTALK_TEST_RESOURCE="$tmp/attention-resource" \
    DIREXTALK_TEST_PROVISION_COUNT="$tmp/attention-provision-count" \
    DIREXTALK_TEST_START_COUNT="$tmp/attention-start-count" \
    DIREXTALK_TEST_CLEANUP_CALLS="$tmp/attention-cleanup-calls" \
    DIREXTALK_TEST_PREPARATION_COUNT="$tmp/attention-preparation-count" \
    DIREXTALK_TEST_RUNNER_INTEGRATION="$tmp/attention-runner-integration" \
    DIREXTALK_TEST_AGENT_ATTENTION=true \
    bash "$consumer" >"$tmp/attention.out" 2>"$tmp/attention.err"; then
  echo 'Agent-attention bootstrap unexpectedly reported full health' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
grep -Fq 'continuing Edge and bootstrap export while Agent needs attention' "$tmp/attention.err"
grep -Fq 'preserved healthy messaging; Agent recovery is required' "$tmp/attention.err"
[ -f "$attention/.split-deploy-done" ]
[ -f "$attention/edge-bootstrap-receipt" ]
[ -f "$attention/p2p/bootstrap.json" ]
[ -e "$tmp/attention-resource" ]
! grep -q '^cleanup-' "$tmp/attention-cleanup-calls"

# A formal Agent release updates the protected runtime receipt, not the
# fresh-bootstrap input. A later tooling/Caddy reconcile must use that current
# receipt while leaving the original bootstrap inputs unchanged.
sed -i \
  -e 's#^DIREXTALK_AGENT_IMAGE=.*#DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.70#' \
  -e 's/^DIREXTALK_AGENT_VERSION=.*/DIREXTALK_AGENT_VERSION=v1.0.70/' \
  -e 's/^DIREXTALK_AGENT_SOURCE_REVISION=.*/DIREXTALK_AGENT_SOURCE_REVISION=dddddddddddddddddddddddddddddddddddddddd/' \
  "$base/split/.env"
chmod 0400 "$base/split/.env"
export DIREXTALK_TEST_AGENT_VERSION=v1.0.70
export DIREXTALK_TEST_AGENT_REVISION=dddddddddddddddddddddddddddddddddddddddd
PATH="$fakebin:$PATH" \
  bash "$consumer" --reconcile-edge >"$tmp/reconcile-edge.out" 2>"$tmp/reconcile-edge.err"
grep -Fqx 'AGENT_VERSION=v1.0.69' "$base/.env"
grep -Fqx 'AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.69' "$base/.env"
[ "$(cat "$base/.split-bootstrap-stage")" = completed ]
export DIREXTALK_TEST_AGENT_VERSION=v1.0.69
export DIREXTALK_TEST_AGENT_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

pre_control=$tmp/pre-control
cp -a "$tmp/pristine" "$pre_control"
mkdir -m 0700 "$pre_control/split"
cat >"$pre_control/runner-preparation.env" <<'EOF'
DIREXTALK_RUNNER_APPARMOR_MANAGER_PATH=/var/dirextalk-message-server/deploy/split-agent/scripts/manage-runner-apparmor.sh
DIREXTALK_RUNNER_PREP_HELPER_PATH=/var/dirextalk-message-server/deploy/split-agent/scripts/prepare-runner-cgroups.sh
EOF
chmod 0600 "$pre_control/runner-preparation.env"
if PATH="$fakebin:$PATH" \
    DIREXTALK_BOOTSTRAP_BASE="$pre_control" \
    DIREXTALK_TEST_RESOURCE="$tmp/pre-control-resource" \
    DIREXTALK_TEST_PROVISION_COUNT="$tmp/pre-control-provision-count" \
    DIREXTALK_TEST_START_COUNT="$tmp/pre-control-start-count" \
    DIREXTALK_TEST_CLEANUP_CALLS="$tmp/pre-control-cleanup-calls" \
    DIREXTALK_TEST_PREPARATION_COUNT="$tmp/pre-control-preparation-count" \
    DIREXTALK_TEST_RUNNER_INTEGRATION="$tmp/pre-control-runner-integration" \
    DIREXTALK_TEST_FAIL_EMPTY_PROVISION=true \
    bash "$consumer" >"$tmp/pre-control-first.out" 2>"$tmp/pre-control-first.err"; then
  echo 'empty-directory provision failure unexpectedly succeeded' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 73 ] || { cat "$tmp/pre-control-first.err" >&2; exit 1; }
[ ! -e "$pre_control/split" ]
printf '%s\n' 1 >"$tmp/pre-control-start-count"
PATH="$fakebin:$PATH" \
  DIREXTALK_BOOTSTRAP_BASE="$pre_control" \
  DIREXTALK_TEST_RESOURCE="$tmp/pre-control-resource" \
  DIREXTALK_TEST_PROVISION_COUNT="$tmp/pre-control-provision-count" \
  DIREXTALK_TEST_START_COUNT="$tmp/pre-control-start-count" \
  DIREXTALK_TEST_CLEANUP_CALLS="$tmp/pre-control-cleanup-calls" \
  DIREXTALK_TEST_PREPARATION_COUNT="$tmp/pre-control-preparation-count" \
  DIREXTALK_TEST_RUNNER_INTEGRATION="$tmp/pre-control-runner-integration" \
  bash "$consumer" >"$tmp/pre-control-retry.out" 2>"$tmp/pre-control-retry.err"
[ "$(cat "$tmp/pre-control-provision-count")" -eq 2 ]
[ -f "$pre_control/.split-deploy-done" ]

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
    DIREXTALK_TEST_PREPARATION_COUNT="$tmp/negative-preparation-count" \
    DIREXTALK_TEST_RUNNER_INTEGRATION="$tmp/negative-runner-integration" \
    DIREXTALK_TEST_NO_RECEIPT=true \
    DIREXTALK_TEST_PROVISION_CLEANUP_STATUS=3 \
    bash "$consumer" >"$tmp/negative.out" 2>"$tmp/negative.err"; then
  echo 'expected-negative cleanup bootstrap unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'provision cleanup stopped in an expected negative state' "$tmp/negative.err"
[ -d "$negative/split" ]
[ -f "$negative/runner-preparation.env" ]
[ -f "$tmp/negative-runner-integration" ]

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
    DIREXTALK_TEST_PREPARATION_COUNT="$tmp/infra-preparation-count" \
    DIREXTALK_TEST_RUNNER_INTEGRATION="$tmp/infra-runner-integration" \
    DIREXTALK_TEST_CLEANUP_LOCAL_STATUS=74 \
    bash "$consumer" >"$tmp/infra.out" 2>"$tmp/infra.err"; then
  echo 'infrastructure cleanup failure bootstrap unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'stack cleanup failed (status 74)' "$tmp/infra.err"
[ -d "$infra/split" ]
[ -e "$tmp/infra-resource" ]
[ -f "$infra/runner-preparation.env" ]
[ -f "$tmp/infra-runner-integration" ]

echo 'production bootstrap first-start failure cleanup and retry test passed'
