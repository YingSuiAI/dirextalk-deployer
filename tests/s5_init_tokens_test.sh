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
{"password":"12345678","agent_token":"agent-test","access_token":"owner-test","agent_room_id":"!real:resume.example.test","as_url":"https://resume.example.test"}
JSON
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '200'
EOF
chmod 0755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

log() { :; }
warn() { :; }
ok() { :; }
fail() { echo "$*" >&2; return 1; }
poll_until() { local _label=$1 _interval=$2 _maximum=$3; shift 3; "$@"; }

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s5_init_tokens.sh"
run_phase

json_test_check "$STATE_JSON" "data.phases.S5_INIT_TOKENS.status === 'done' && data.password === '12345678' && data.agent_token === 'agent-test' && data.access_token === 'owner-test' && data.agent_room_id === '!real:resume.example.test'"
echo "s5 init tokens ok"
