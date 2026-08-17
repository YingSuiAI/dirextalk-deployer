#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
script=$script_dir/refresh-message-mcp-token.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-message-mcp-token.XXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

stack_name=d-aaaaaaaaaaaaaaaaaaaaaaaaaa
message_id=$(printf '1%.0s' {1..64})
replacement_id=$(printf '2%.0s' {1..64})
message_image=docker.io/dirextalk/message-server:v1.1.62
agent_token=p2p_agent_0123456789abcdef
out=$tmp/out
fixture_bootstrap=$tmp/bootstrap.json
docker_log=$tmp/docker.log
inspect_count=$tmp/inspect-count
mkdir -p "$out" "$tmp/bin"
chmod 0700 "$out"
: >"$docker_log"
: >"$inspect_count"

cat >"$out/.env" <<EOF
DIREXTALK_SPLIT_STACK_NAME=$stack_name
DIREXTALK_MESSAGE_SERVER_IMAGE=$message_image
DIREXTALK_MESSAGE_MCP_TOKEN_FILE=$out/message-mcp-token
EOF
cat >"$out/.manifest" <<EOF
stack_name=$stack_name
message_mcp_token_path=$out/message-mcp-token
EOF
: >"$out/message-mcp-token"
chmod 0400 "$out/.env" "$out/.manifest" "$out/message-mcp-token"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$DOCKER_FIXTURE_LOG"
case "${1:-}" in
  inspect)
    count=$(wc -l <"$DOCKER_FIXTURE_INSPECT_COUNT")
    printf 'x\n' >>"$DOCKER_FIXTURE_INSPECT_COUNT"
    actual_id=$DOCKER_FIXTURE_MESSAGE_ID
    [ "${DOCKER_FIXTURE_REPLACE_AFTER_READ:-false}" != true ] || [ "$count" -lt 1 ] \
      || actual_id=$DOCKER_FIXTURE_REPLACEMENT_ID
    printf '[{"Id":"%s","Config":{"Image":"%s","Labels":{"com.docker.compose.project":"%s","com.docker.compose.service":"message-server"}},"State":{"Status":"running","Health":{"Status":"healthy"}}}]\n' \
      "$actual_id" "$DOCKER_FIXTURE_MESSAGE_IMAGE" "$DOCKER_FIXTURE_STACK"
    ;;
  cp)
    [ "${2:-}" = "$DOCKER_FIXTURE_MESSAGE_ID:/var/dirextalk-message-server/p2p/bootstrap.json" ]
    cp -- "$DOCKER_FIXTURE_BOOTSTRAP" "${3:?missing destination}"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker"

run_refresh() {
  PATH="$tmp/bin:$PATH" \
  DOCKER_FIXTURE_LOG=$docker_log \
  DOCKER_FIXTURE_INSPECT_COUNT=$inspect_count \
  DOCKER_FIXTURE_MESSAGE_ID=$message_id \
  DOCKER_FIXTURE_REPLACEMENT_ID=$replacement_id \
  DOCKER_FIXTURE_MESSAGE_IMAGE=$message_image \
  DOCKER_FIXTURE_STACK=$stack_name \
  DOCKER_FIXTURE_BOOTSTRAP=$fixture_bootstrap \
    "$script" "$out" "$message_id"
}

assert_literal_absent() {
  local needle=$1
  shift
  if grep -Fq -- "$needle" "$@"; then
    echo 'secret value escaped its protected token file' >&2
    exit 1
  fi
}

cat >"$fixture_bootstrap" <<EOF
{"access_token":"owner-secret","agent_token":"$agent_token","password":"12345678"}
EOF
stdout=$tmp/stdout
stderr=$tmp/stderr
run_refresh >"$stdout" 2>"$stderr"
[ ! -s "$stdout" ]
[ ! -s "$stderr" ]
[ "$(cat "$out/message-mcp-token")" = "$agent_token" ]
[ "$(stat -c '%a:%u:%g' "$out/message-mcp-token")" = "400:$(id -u):$(id -g)" ]
[ "$(wc -l <"$inspect_count")" -eq 4 ]
if find "$out" -maxdepth 1 -name '.message-mcp-*' -print -quit | grep -q .; then
  echo 'refresh retained transient bootstrap or token material' >&2
  exit 1
fi
assert_literal_absent "$agent_token" "$stdout" "$stderr" "$docker_log" "$out/.env" "$out/.manifest"
assert_literal_absent owner-secret "$out/message-mcp-token" "$out/.env" "$out/.manifest" "$docker_log"

assert_invalid_preserves_token() {
  local label=$1
  chmod 0600 "$out/message-mcp-token"
  printf '%s' 'previous-stable-token' >"$out/message-mcp-token"
  chmod 0400 "$out/message-mcp-token"
  : >"$docker_log"
  : >"$inspect_count"
  if run_refresh >"$stdout" 2>"$stderr"; then
    echo "$label bootstrap unexpectedly refreshed the token" >&2
    exit 1
  fi
  [ "$(cat "$out/message-mcp-token")" = previous-stable-token ]
  [ "$(wc -l <"$inspect_count")" -eq 2 ]
  if grep -Eq '(^| )(rm|stop|up|restart|kill)( |$)' "$docker_log"; then
    echo "$label bootstrap failure mutated Message Server" >&2
    exit 1
  fi
  assert_literal_absent previous-stable-token "$stdout" "$stderr" "$docker_log"
}

printf '%s\n' '{"access_token":"owner-secret"}' >"$fixture_bootstrap"
assert_invalid_preserves_token missing
printf '%s\n' '{"agent_token":""}' >"$fixture_bootstrap"
assert_invalid_preserves_token empty
printf '%s\n' '{"agent_token":42}' >"$fixture_bootstrap"
assert_invalid_preserves_token non-string
printf '%s\n' '{"agent_token":"line1\nline2"}' >"$fixture_bootstrap"
assert_invalid_preserves_token multiline

cat >"$fixture_bootstrap" <<EOF
{"agent_token":"$agent_token"}
EOF
chmod 0600 "$out/message-mcp-token"
printf '%s' 'previous-stable-token' >"$out/message-mcp-token"
chmod 0400 "$out/message-mcp-token"
: >"$docker_log"
: >"$inspect_count"
if DOCKER_FIXTURE_REPLACE_AFTER_READ=true run_refresh >"$stdout" 2>"$stderr"; then
  echo 'same-name Message Server replacement unexpectedly refreshed the token' >&2
  exit 1
fi
[ "$(cat "$out/message-mcp-token")" = previous-stable-token ]
[ "$(wc -l <"$inspect_count")" -eq 2 ]
assert_literal_absent "$agent_token" "$stdout" "$stderr" "$docker_log" "$out/.env" "$out/.manifest"

printf '%s\n' 'Message MCP token refresh test passed'
