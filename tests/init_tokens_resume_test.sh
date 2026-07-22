#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

base="$tmp/server"
fakebin="$tmp/bin"
stage_file="$base/.bootstrap-stage"
mkdir -p "$base/p2p" "$fakebin"
printf 'P2P_PORTAL_PASSWORD=test-only-password\n' > "$base/.env"
cat > "$base/p2p/bootstrap.json" <<'JSON'
{"password":"ready","agent_token":"agent-ready","access_token":"owner-ready","agent_room_id":"!real:resume.example.test"}
JSON

cat > "$fakebin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$*" in
  *'/_p2p/health'*) exit 0 ;;
  *) echo "an existing bootstrap file must not trigger another portal.bootstrap call" >&2; exit 97 ;;
esac
EOF
chmod 0755 "$fakebin/docker"

cat > "$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TIMEOUT_CALLS"
case "${1:-}" in
  --kill-after=5s) ;;
  *) echo "timeout must use the configured kill-after policy" >&2; exit 98 ;;
esac
shift
[ "${1:-}" = 30s ] || { echo "timeout must use the configured command timeout" >&2; exit 99; }
shift
exec "$@"
EOF
chmod 0755 "$fakebin/timeout"

export PATH="$fakebin:$PATH"
export DOCKER_CALLS="$tmp/docker.calls"
export TIMEOUT_CALLS="$tmp/timeout.calls"
DOMAIN=resume.example.test \
  DIREXTALK_DIR="$base" \
  BOOTSTRAP_FILE="$base/p2p/bootstrap.json" \
  bash "$ROOT/scripts/cloud-init/init-tokens.sh" > "$tmp/out"

grep -qF "$base/p2p/bootstrap.json" "$tmp/out"
grep -q '/_p2p/health' "$DOCKER_CALLS"
grep -q -- '--kill-after=5s 30s docker compose' "$TIMEOUT_CALLS"
[ "$(cat "$stage_file")" = init_complete ]
[ "$(wc -l < "$stage_file")" -eq 1 ]
! grep -Eq 'resume\.example\.test|ready|agent|owner|token|secret' "$stage_file"
if grep -q '/_p2p/command' "$DOCKER_CALLS"; then
  echo "resume must reuse complete bootstrap credentials" >&2
  cat "$DOCKER_CALLS" >&2
  exit 1
fi

if DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT=0 \
  DOMAIN=resume.example.test \
  DIREXTALK_DIR="$base" \
  BOOTSTRAP_FILE="$base/p2p/bootstrap.json" \
  bash "$ROOT/scripts/cloud-init/init-tokens.sh" >"$tmp/invalid.out" 2>&1; then
  echo "invalid command timeout must fail closed" >&2
  exit 1
fi

for stage in init_health init_portal init_credentials init_agent_session init_room_create init_room_join init_complete; do
  grep -q "write_bootstrap_stage $stage" "$ROOT/scripts/cloud-init/init-tokens.sh"
done

echo "init tokens resume ok"
