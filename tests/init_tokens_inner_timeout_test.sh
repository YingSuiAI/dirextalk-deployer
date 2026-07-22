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
printf '%s\n' "$@" > "$WGET_ARGS"
if [ "${WGET_HANG:-0}" = 1 ]; then
  if [ "${WGET_IGNORE_TERM:-0}" = 1 ]; then
    trap ':' TERM
    while :; do :; done
  fi
  sleep 30
fi
printf '%s\n' '{"ok":true}'
EOF

cat > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
echo "container POST must not create a secret config file" >&2
exit 96
EOF
chmod 0755 "$fakebin"/*

# Load function definitions without running the script's production entrypoint.
sed '/^mkdir -p /,$d' "$ROOT/scripts/cloud-init/init-tokens.sh" > "$tmp/init-tokens-functions.sh"
export PATH="$fakebin:$PATH"
export DIREXTALK_DIR="$base" DOMAIN=inner-timeout.example.test
export DIREXTALK_INIT_TOKENS_COMMAND_TIMEOUT=1 DIREXTALK_INIT_TOKENS_COMMAND_KILL_AFTER=1
# shellcheck disable=SC1091
source "$tmp/init-tokens-functions.sh"

assert_arg() {
  local expected=$1 args=$2
  grep -F -x -q -- "$expected" "$args" || {
    echo "missing wget argument: ${expected}" >&2
    exit 1
  }
}

assert_no_config_arg() {
  local args=$1
  if grep -q -- '--config' "$args"; then
    echo "BusyBox wget call must not use --config" >&2
    exit 1
  fi
}

marker="$tmp/injected"
token="agent-token; touch $marker"
password="password; touch $marker"
payload="{\"action\":\"test\",\"params\":{\"password\":\"${password}\"}}"
export WGET_ARGS="$tmp/post.args"
WGET_HANG=0 container_post_json /_p2p/command "$payload" "$token" > "$tmp/response.json" 2> "$tmp/post.err"
assert_arg -T "$WGET_ARGS"
assert_arg 1 "$WGET_ARGS"
assert_arg '--header=Content-Type: application/json' "$WGET_ARGS"
assert_arg "--header=Authorization: Bearer $token" "$WGET_ARGS"
assert_arg "--post-data=$payload" "$WGET_ARGS"
assert_arg 'http://127.0.0.1:8008/_p2p/command' "$WGET_ARGS"
assert_no_config_arg "$WGET_ARGS"
[ ! -e "$marker" ] || { echo "POST arguments must not be evaluated as shell code" >&2; exit 1; }
if grep -F -q -- "$token" "$tmp/response.json" "$tmp/post.err" \
  || grep -F -q -- "$password" "$tmp/response.json" "$tmp/post.err"; then
  echo "POST must not leak credentials to output" >&2
  exit 1
fi
if grep -R -F -q -- "$token" "$base" || grep -R -F -q -- "$password" "$base"; then
  echo "POST must not leave credentials in the deployment directory" >&2
  exit 1
fi

export WGET_ARGS="$tmp/health.args"
WGET_HANG=0 container_wget http://127.0.0.1:8008/_p2p/health > "$tmp/health-success.out"
assert_arg -T "$WGET_ARGS"
assert_arg 1 "$WGET_ARGS"
assert_arg 'http://127.0.0.1:8008/_p2p/health' "$WGET_ARGS"
assert_no_config_arg "$WGET_ARGS"

started=$(date +%s)
export WGET_ARGS="$tmp/hang-post.args"
if WGET_HANG=1 WGET_IGNORE_TERM=1 container_post_json /_p2p/command '{"action":"hang"}' > "$tmp/hang.out" 2>&1; then
  echo "hung POST must be terminated inside the container" >&2
  exit 1
fi
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 5 ] || { echo "TERM-resistant POST must be force-killed inside the container" >&2; exit 1; }
assert_no_config_arg "$WGET_ARGS"

export WGET_ARGS="$tmp/hang-health.args"
if WGET_HANG=1 WGET_IGNORE_TERM=1 container_wget http://127.0.0.1:8008/_p2p/health > "$tmp/health.out" 2>&1; then
  echo "hung health wget must be terminated inside the container" >&2
  exit 1
fi
assert_no_config_arg "$WGET_ARGS"

echo "init tokens inner timeout ok"
