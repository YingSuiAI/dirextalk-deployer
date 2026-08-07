#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_HOME="$HOME/.dirextalk" DIREXTALK_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set domain resume.example.test
res_set public_ip 203.0.113.10
printf 'test key\n' > "$tmp/key.pem"
res_set key_file "$tmp/key.pem"

cat > "$tmp/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -gt 0 ] || { echo "S5 must not use the shell default temp directory" >&2; exit 98; }
exec /usr/bin/mktemp "$@"
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"password":"12345678","agent_token":"agent-test","access_token":"bootstrap-p2p-test","agent_room_id":"!real:resume.example.test","as_url":"https://resume.example.test"}
JSON
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out= data= url= resolve=
args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) out=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    --resolve) resolve=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "${args[*]}" >> "$PORTAL_CURL_LOG"
case "$url" in
  https://resume.example.test/.well-known/portal/owner.json)
    printf '200'
    ;;
  https://resume.example.test/_p2p/command)
    [ "$resolve" = "resume.example.test:443:203.0.113.10" ]
    [ -n "$out" ] && [ "$(stat -c '%a' "$out")" = 600 ]
    case "$data" in @*) request=${data#@} ;; *) exit 91 ;; esac
    [ "$(stat -c '%a' "$request")" = 600 ]
    [ "$(tr -d '\n' < "$request")" = '{"action":"portal.auth","params":{"password":"12345678"}}' ]
    case "${PORTAL_CURL_MODE:-success}" in
      success)
        printf '%s\n' '{"access_token":"matrix-owner-test","device_id":"OWNER_DEVICE","user_id":"@owner:resume.example.test","homeserver":"https://resume.example.test"}' > "$out"
        printf '200'
        ;;
      rejected)
        printf '%s\n' '{"errcode":"M_FORBIDDEN","error":"password invalid"}' > "$out"
        printf '401'
        ;;
      infrastructure)
        exit 7
        ;;
      *) exit 92 ;;
    esac
    ;;
  *) exit 93 ;;
esac
EOF
chmod 0755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export PORTAL_CURL_LOG="$tmp/portal-curl.log"

log() { :; }
warn() { :; }
ok() { :; }
fail() { echo "$*" >&2; return 1; }
poll_until() { local _label=$1 _interval=$2 _maximum=$3; shift 3; "$@"; }

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s5_init_tokens.sh"
run_phase

json_test_check "$STATE_JSON" "data.phases.S5_INIT_TOKENS.status === 'done' && data.password === '12345678' && data.agent_token === 'agent-test' && data.access_token === 'matrix-owner-test' && data.access_token !== 'bootstrap-p2p-test' && data.agent_room_id === '!real:resume.example.test'"
grep -q -- '--resolve resume.example.test:443:203.0.113.10' "$PORTAL_CURL_LOG"
grep -q -- '--request POST' "$PORTAL_CURL_LOG"
grep -q -- '--header Content-Type: application/json' "$PORTAL_CURL_LOG"
grep -q -- '--data-binary @' "$PORTAL_CURL_LOG"
if grep -Eq '12345678|matrix-owner-test|bootstrap-p2p-test|agent-test' "$PORTAL_CURL_LOG"; then
  echo "S5 portal authentication leaked a credential into curl argv" >&2
  exit 1
fi
if find "$DIREXTALK_WORKDIR" -maxdepth 1 \( -name '.portal-auth-*' -o -name '.owner-matrix-session.*' \) | grep -q .; then
  echo "S5 left protected portal authentication temporary files behind" >&2
  exit 1
fi

# The real S5 consumer must preserve the last good token and fail closed while
# distinguishing an authentication rejection from an infrastructure failure.
export PORTAL_CURL_MODE=rejected
set +e
run_phase >/dev/null 2>"$tmp/portal-rejected.err"
portal_status=$?
set -e
[ "$portal_status" -eq 3 ]
json_test_check "$STATE_JSON" "data.phases.S5_INIT_TOKENS.status === 'failed' && data.access_token === 'matrix-owner-test' && data.agent_token === 'agent-test'"
if grep -Eq '12345678|matrix-owner-test|bootstrap-p2p-test|agent-test' "$tmp/portal-rejected.err"; then
  echo "S5 expected-negative diagnostics leaked credentials" >&2
  exit 1
fi

export PORTAL_CURL_MODE=infrastructure
set +e
run_phase >/dev/null 2>"$tmp/portal-infrastructure.err"
portal_status=$?
set -e
[ "$portal_status" -eq 1 ]
json_test_check "$STATE_JSON" "data.phases.S5_INIT_TOKENS.status === 'failed' && data.access_token === 'matrix-owner-test' && data.agent_token === 'agent-test'"
if grep -Eq '12345678|matrix-owner-test|bootstrap-p2p-test|agent-test' "$tmp/portal-infrastructure.err"; then
  echo "S5 infrastructure diagnostics leaked credentials" >&2
  exit 1
fi
unset PORTAL_CURL_MODE

# Keep the timeout and initialization-code shape contract beside the S5
# success flow instead of maintaining a second bootstrap-token test file.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit 0
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
case " $* " in
  *" ConnectTimeout=6 "*" BatchMode=yes "*" ServerAliveInterval=4 "*" ServerAliveCountMax=3 "*) printf '{"password":"12345678","agent_token":"agent","access_token":"access"}'; exit 0 ;;
  *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TIMEOUT_LOG"
shift
exec "$@"
EOF
chmod 700 "$tmp/bin/curl" "$tmp/bin/ssh" "$tmp/bin/timeout"
hash -r
export CURL_LOG="$tmp/curl-timeout.log"
export SSH_LOG="$tmp/ssh-timeout.log"
export TIMEOUT_LOG="$tmp/timeout.log"
export HEALTH_CURL_CONNECT_TIMEOUT=7
export HEALTH_CURL_MAX_TIME=11
export SSH_CONNECT_TIMEOUT=6
export SSH_SERVER_ALIVE_INTERVAL=4
export SSH_SERVER_ALIVE_COUNT_MAX=3
export SSH_COMMAND_TIMEOUT=19

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s4_bootstrap_stack.sh"
_server_health_ok resume.example.test
grep -q -- '--connect-timeout 7' "$CURL_LOG"
grep -q -- '--max-time 11' "$CURL_LOG"
grep -q -- '--resolve resume.example.test:443:203.0.113.10' "$CURL_LOG"

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s5_init_tokens.sh"
_read_remote_bootstrap "$tmp/key.pem" "203.0.113.10" "$tmp/bootstrap-timeout.json"
grep -q 'ConnectTimeout=6' "$SSH_LOG"
grep -q 'BatchMode=yes' "$SSH_LOG"
grep -q 'ServerAliveInterval=4' "$SSH_LOG"
grep -q 'ServerAliveCountMax=3' "$SSH_LOG"
grep -q '/var/dirextalk-message-server/p2p/bootstrap.json' "$SSH_LOG"
if grep -q '/opt/p2p/bootstrap.json\|elif sudo test -s' "$SSH_LOG"; then
  echo "S5 must use only the current bootstrap path" >&2
  exit 1
fi
grep -q '^19$' "$TIMEOUT_LOG"
json_test_check "$tmp/bootstrap-timeout.json" "data.password === '12345678' && data.agent_token === 'agent' && data.access_token === 'access'"

printf '{"password":"01234567","agent_token":"agent","access_token":"access"}\n' > "$tmp/bootstrap-leading-zero.json"
IFS=$'\t' read -r password token access_token < <(_extract_output_tokens "$tmp/bootstrap-leading-zero.json")
[ "$password" = "01234567" ]
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

# Failure diagnostics must bind Compose to the protected production split
# controls and must never print bootstrap credentials.
export WARN_LOG="$tmp/split-diagnostics.log"
warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
poll_until() { return 1; }

: > "$WARN_LOG"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s4_bootstrap_stack.sh"
if run_phase; then
  echo "S4 timeout fixture unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq '/var/dirextalk-message-server/split/.manifest' "$WARN_LOG"
grep -Fq -- '--project-name "$stack" -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml --env-file /var/dirextalk-message-server/split/.env ps' "$WARN_LOG"
grep -Fq -- '--env-file /var/dirextalk-message-server/split/.env logs --tail=80 message-server' "$WARN_LOG"
if grep -Fq 'cd /var/dirextalk-message-server && sudo docker compose' "$WARN_LOG"; then
  echo "S4 diagnostics fell back to the removed root-level Compose project" >&2
  exit 1
fi

: > "$WARN_LOG"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s5_init_tokens.sh"
if run_phase; then
  echo "S5 missing-bootstrap fixture unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'init_tokens_stage=' "$WARN_LOG"
grep -Fq 'bootstrap.json size=%s mode=%a owner=%U:%G modified=%y' "$WARN_LOG"
grep -Fq -- '--project-name "$stack" -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml --env-file /var/dirextalk-message-server/split/.env ps' "$WARN_LOG"
grep -Fq -- '--env-file /var/dirextalk-message-server/split/.env logs --tail=40 message-server' "$WARN_LOG"
if grep -Fq "sudo cat $DIREXTALK_REMOTE_BOOTSTRAP_FILE" "$WARN_LOG"; then
  echo "S5 diagnostics would print bootstrap credentials" >&2
  exit 1
fi

echo "s5 init tokens ok"
