#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DOMAIN="timeout.example.test"
mkdir -p "$HOME" "$tmp/bin"

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit 0
EOF
chmod 700 "$tmp/bin/curl"

cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
case " $* " in
  *" ConnectTimeout=6 "*" BatchMode=yes "*" ServerAliveInterval=4 "*" ServerAliveCountMax=3 "*) printf '{"password":"12345678","agent_token":"agent","access_token":"access"}'; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$tmp/bin/ssh"

cat > "$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TIMEOUT_LOG"
shift
exec "$@"
EOF
chmod 700 "$tmp/bin/timeout"

export PATH="$tmp/bin:$PATH"
export CURL_LOG="$tmp/curl.log"
export SSH_LOG="$tmp/ssh.log"
export TIMEOUT_LOG="$tmp/timeout.log"
export HEALTH_CURL_CONNECT_TIMEOUT=7
export HEALTH_CURL_MAX_TIME=11
export SSH_CONNECT_TIMEOUT=6
export SSH_SERVER_ALIVE_INTERVAL=4
export SSH_SERVER_ALIVE_COUNT_MAX=3
export SSH_COMMAND_TIMEOUT=19

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
res_set public_ip "203.0.113.10"

# shellcheck disable=SC1090
source "$ROOT/scripts/phases/s4_bootstrap_stack.sh"
_healthz_ok "timeout.example.test"
grep -q -- '--connect-timeout 7' "$CURL_LOG"
grep -q -- '--max-time 11' "$CURL_LOG"
grep -q -- '--resolve timeout.example.test:443:203.0.113.10' "$CURL_LOG"

# shellcheck disable=SC1090
source "$ROOT/scripts/phases/s5_init_tokens.sh"
_read_remote_bootstrap "$tmp/key.pem" "203.0.113.10" "$tmp/bootstrap.json"
grep -q 'ConnectTimeout=6' "$SSH_LOG"
grep -q 'BatchMode=yes' "$SSH_LOG"
grep -q 'ServerAliveInterval=4' "$SSH_LOG"
grep -q 'ServerAliveCountMax=3' "$SSH_LOG"
grep -q '/var/dirextalk-message-server/p2p/bootstrap.json' "$SSH_LOG"
deprecated_bootstrap_path="/opt""/p2p/bootstrap.json"
if grep -q "$deprecated_bootstrap_path" "$SSH_LOG" || grep -q 'elif sudo test -s' "$SSH_LOG"; then
  echo "S5 must use only the current bootstrap path" >&2
  exit 1
fi
grep -q '^19$' "$TIMEOUT_LOG"
json_test_check "$tmp/bootstrap.json" "data.password === '12345678' && data.agent_token === 'agent' && data.access_token === 'access'"

printf '{"password":"01234567","agent_token":"agent","access_token":"access"}\n' > "$tmp/bootstrap-leading-zero.json"
IFS=$'\t' read -r password token access_token < <(_extract_output_tokens "$tmp/bootstrap-leading-zero.json")
[ "$password" = "01234567" ]
[ "$token" = "agent" ]
[ "$access_token" = "access" ]

printf '{"password":"8848121","agent_token":"agent","access_token":"access"}\n' > "$tmp/bootstrap-short-code.json"
if _extract_output_tokens "$tmp/bootstrap-short-code.json" >/dev/null; then
  echo "S5 must reject initialization codes that are not exactly eight digits" >&2
  exit 1
fi

printf '{"password":12345678,"agent_token":"agent","access_token":"access"}\n' > "$tmp/bootstrap-numeric-code.json"
if _extract_output_tokens "$tmp/bootstrap-numeric-code.json" >/dev/null; then
  echo "S5 must reject numeric initialization codes; they must stay JSON strings to preserve leading zeros" >&2
  exit 1
fi

echo "phase timeout guards ok"
