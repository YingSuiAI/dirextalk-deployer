#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

base="$tmp/server"
fakebin="$tmp/bin"
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

export PATH="$fakebin:$PATH"
export DOCKER_CALLS="$tmp/docker.calls"
DOMAIN=resume.example.test \
  DIREXTALK_DIR="$base" \
  BOOTSTRAP_FILE="$base/p2p/bootstrap.json" \
  bash "$ROOT/scripts/cloud-init/init-tokens.sh" > "$tmp/out"

grep -qF "$base/p2p/bootstrap.json" "$tmp/out"
grep -q '/_p2p/health' "$DOCKER_CALLS"
if grep -q '/_p2p/command' "$DOCKER_CALLS"; then
  echo "resume must reuse complete bootstrap credentials" >&2
  cat "$DOCKER_CALLS" >&2
  exit 1
fi

echo "init tokens resume ok"
