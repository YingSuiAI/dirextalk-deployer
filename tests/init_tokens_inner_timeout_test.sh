#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base="$tmp/server"
fakebin="$tmp/bin"
mkdir -p "$base/p2p" "$fakebin"
printf 'P2P_PORTAL_PASSWORD=test-only-password\n' > "$base/.env"

# Execute the command passed to `docker compose exec ... sh -c` so the test
# exercises the same watchdog and cleanup code that runs in the container.
cat > "$fakebin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = -c ]; then
    script=${args[i + 1]}
    set -- "${args[@]:i + 2}"
    exec sh -c "$script" "$@"
  fi
done
echo "docker fake did not receive sh -c" >&2
exit 97
EOF

cat > "$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = --kill-after=1s ] || exit 98
shift
[ "${1:-}" = 1s ] || exit 99
shift
exec "$@"
EOF

cat > "$fakebin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${WGET_HANG:-0}" = 1 ]; then
  sleep 30
fi
for arg in "$@"; do
  case "$arg" in
    --config=*)
      config=${arg#--config=}
      printf '%s\n' "$config" > "$WGET_CONFIG_PATH"
      cat "$config" > "$WGET_CONFIG_BODY"
      ;;
  esac
done
printf '%s\n' '{"ok":true}'
EOF
chmod 0755 "$fakebin"/*

# Load function definitions without running the script's production entrypoint.
sed '/^mkdir -p /,$d' "$ROOT/scripts/cloud-init/init-tokens.sh" > "$tmp/init-tokens-functions.sh"
export PATH="$fakebin:$PATH"
export DIREXTALK_DIR="$base" DOMAIN=inner-timeout.example.test
export DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT=1 DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER=1
export WGET_CONFIG_PATH="$tmp/config.path" WGET_CONFIG_BODY="$tmp/config.body"
# shellcheck disable=SC1091
source "$tmp/init-tokens-functions.sh"

WGET_HANG=0
container_post_json /_p2p/command '{"action":"test"}' > "$tmp/response.json"
config_path=$(cat "$WGET_CONFIG_PATH")
[ ! -e "$config_path" ] || { echo "POST config must be removed after wget exits" >&2; exit 1; }
grep -q '^header=Content-Type: application/json$' "$WGET_CONFIG_BODY"
grep -q '^post_data={"action":"test"}$' "$WGET_CONFIG_BODY"

if WGET_HANG=1 container_post_json /_p2p/command '{"action":"hang"}' > "$tmp/hang.out" 2>&1; then
  echo "hung POST must be terminated inside the container" >&2
  exit 1
fi
config_path=$(cat "$WGET_CONFIG_PATH")
[ ! -e "$config_path" ] || { echo "POST config must be removed after watchdog termination" >&2; exit 1; }

if WGET_HANG=1 container_wget http://127.0.0.1:8008/_p2p/health > "$tmp/health.out" 2>&1; then
  echo "hung health wget must be terminated inside the container" >&2
  exit 1
fi

echo "init tokens inner timeout ok"
