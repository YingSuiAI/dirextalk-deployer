#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
: "${DIREXTALK_TEST_ROOT:?run this test through tests/lib/run_isolated.sh}"

required=${DIREXTALK_REQUIRE_SPLIT_FAULT_GATE:-false}
pull_image=${DIREXTALK_SPLIT_FAULT_GATE_PULL:-false}
unavailable() {
  if [ "$required" = true ]; then
    echo "split-stack fault gate required but unavailable: $*" >&2
    exit 1
  fi
  echo "split-stack fault gate skipped: $*" >&2
  exit 0
}

[ "$(uname -s)" = Linux ] || unavailable 'Docker host networking is supported by this gate only on Linux'
command -v docker >/dev/null 2>&1 || unavailable 'docker CLI is missing'
docker info >/dev/null 2>&1 || unavailable 'Docker Engine is unavailable'

caddy_image=${DIREXTALK_CADDY_TEST_IMAGE:-$(sed -n 's/^DIREXTALK_CADDY_IMAGE_IMMUTABLE=//p' "$ROOT/scripts/cloud-init/split/release.env")}
printf '%s\n' "$caddy_image" | grep -Eq '^docker\.io/library/caddy@sha256:[0-9a-f]{64}$' \
  || { echo 'split-stack fault gate requires the immutable repository Caddy image' >&2; exit 1; }
if ! docker image inspect "$caddy_image" >/dev/null 2>&1; then
  if [ "$pull_image" = true ]; then
    docker pull "$caddy_image" >/dev/null || unavailable "could not pull $caddy_image"
  else
    unavailable "missing local image $caddy_image"
  fi
fi

tmp=$(mktemp -d "$DIREXTALK_TEST_ROOT/split-stack-fault.XXXXXX")
test_id=$(basename "$tmp")
suffix=$(printf '%s' "$test_id-$$" | sha256sum | cut -c1-20)
container=dirextalk-split-fault-$suffix
message_pid=
agent_pid=
cleanup() {
  local owner
  for pid in "$agent_pid" "$message_pid"; do
    [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  if docker container inspect "$container" >/dev/null 2>&1; then
    owner=$(docker container inspect --format '{{ index .Config.Labels "io.dirextalk.test-id" }}' "$container" 2>/dev/null || true)
    if [ "$owner" = "$test_id" ]; then
      docker container rm -f "$container" >/dev/null 2>&1 || true
    else
      echo "refusing to remove replacement test container: $container" >&2
    fi
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT

allocate_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}
message_port=$(allocate_port)
agent_port=$(allocate_port)
edge_port=$(allocate_port)
[ "$message_port" != "$agent_port" ] && [ "$message_port" != "$edge_port" ] && [ "$agent_port" != "$edge_port" ] \
  || { echo 'could not allocate distinct test ports' >&2; exit 1; }

upstream=$ROOT/tests/fixtures/split-stack-fault-upstream.mjs
wait_ready() {
  local ready_file=$1 pid=$2 attempt=0
  while [ "$attempt" -lt 100 ]; do
    [ -s "$ready_file" ] && return 0
    kill -0 "$pid" 2>/dev/null || { echo "upstream $pid exited before readiness" >&2; return 1; }
    sleep 0.02
    attempt=$((attempt + 1))
  done
  echo "upstream $pid did not become ready" >&2
  return 1
}
start_message() {
  rm -f "$tmp/message.ready"
  node "$upstream" message "$message_port" "$tmp/message.ready" >"$tmp/message.log" 2>&1 &
  message_pid=$!
  wait_ready "$tmp/message.ready" "$message_pid"
}
start_agent() {
  rm -f "$tmp/agent.ready"
  node "$upstream" agent "$agent_port" "$tmp/agent.ready" "$tmp/agent-disconnects" >"$tmp/agent.log" 2>&1 &
  agent_pid=$!
  wait_ready "$tmp/agent.ready" "$agent_pid"
}
stop_message() {
  [ -z "$message_pid" ] || kill "$message_pid"
  [ -z "$message_pid" ] || wait "$message_pid"
  message_pid=
}
stop_agent() {
  [ -z "$agent_pid" ] || kill "$agent_pid"
  [ -z "$agent_pid" ] || wait "$agent_pid"
  agent_pid=
}

start_message
start_agent
sed \
  -e "s#__DIREXTALK_PUBLIC_DOMAIN__#https://localhost:$edge_port#g" \
  -e "s#message-server:8008#127.0.0.1:$message_port#g" \
  -e "s#agent:8082#127.0.0.1:$agent_port#g" \
  "$ROOT/scripts/cloud-init/split/Caddyfile" >"$tmp/site.caddy"
{
  printf '{\n\tadmin off\n}\n'
  awk 'NR == 1 { print; print "\ttls internal"; next } { print }' "$tmp/site.caddy"
} >"$tmp/Caddyfile"

docker run -d \
  --name "$container" \
  --label "io.dirextalk.test-id=$test_id" \
  --network host \
  --read-only \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  --tmpfs /data:rw,noexec,nosuid,nodev,mode=0700 \
  --tmpfs /config:rw,noexec,nosuid,nodev,mode=0700 \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
  --mount "type=bind,src=$tmp/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
  "$caddy_image" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
edge_id=$(docker container inspect --format '{{.Id}}' "$container")

root_cert=$tmp/root.crt
for _ in $(seq 1 100); do
  owner=$(docker container inspect --format '{{ index .Config.Labels "io.dirextalk.test-id" }}' "$container" 2>/dev/null || true)
  [ "$owner" = "$test_id" ] || { echo 'Caddy test container identity changed before CA export' >&2; exit 1; }
  docker exec "$container" cat /data/caddy/pki/authorities/local/root.crt \
    >"$root_cert" 2>/dev/null && break
  sleep 0.05
done
[ -s "$root_cert" ] || { docker logs "$container" >&2; echo 'Caddy test CA was not created' >&2; exit 1; }
base=https://localhost:$edge_port
curl_args=(--cacert "$root_cert" --silent --show-error --connect-timeout 2 --max-time 5)
for _ in $(seq 1 100); do
  curl "${curl_args[@]}" --fail "$base/_p2p/health" >"$tmp/health.json" 2>/dev/null && break
  sleep 0.05
done
grep -Fq '"status":"ok"' "$tmp/health.json" || { docker logs "$container" >&2; exit 1; }
curl "${curl_args[@]}" --fail "$base/_matrix/client/v3/sync?timeout=0" >"$tmp/sync.json"
grep -Fq '"next_batch":"fault-gate"' "$tmp/sync.json"

# The first frame must cross Caddy before the delayed frame exists. The request
# remains open until curl times out, which must propagate a disconnect upstream.
set +e
curl --cacert "$root_cert" --silent --show-error --no-buffer --max-time 3.5 \
  -H 'Authorization: Bearer fault-gate-ticket' "$base/agent/v1/events" \
  >"$tmp/sse.out" 2>"$tmp/sse.err" &
sse_pid=$!
set -e
first_seen=false
for _ in $(seq 1 80); do
  if grep -Fq 'data: first' "$tmp/sse.out" 2>/dev/null; then first_seen=true; break; fi
  kill -0 "$sse_pid" 2>/dev/null || break
  sleep 0.025
done
[ "$first_seen" = true ] || { echo 'Caddy did not flush the first SSE frame before the delayed frame' >&2; exit 1; }
if grep -Fq 'data: delayed' "$tmp/sse.out"; then
  echo 'Caddy buffered the first SSE frame until the delayed frame' >&2
  exit 1
fi
set +e
wait "$sse_pid"
sse_status=$?
set -e
[ "$sse_status" -eq 28 ] || { echo "SSE disconnect probe returned $sse_status, expected curl timeout 28" >&2; exit 1; }
grep -Fq 'data: delayed' "$tmp/sse.out"
for _ in $(seq 1 40); do [ -s "$tmp/agent-disconnects" ] && break; sleep 0.025; done
[ -s "$tmp/agent-disconnects" ] || { echo 'Caddy did not propagate the SSE client disconnect upstream' >&2; exit 1; }

# Message Server interruption is visible through the same trusted edge, then
# the exact Matrix-style and health routes recover without replacing Caddy.
stop_message
message_failure=$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' "$base/_p2p/health" || true)
[ "$message_failure" = 502 ] || { echo "Message Server outage returned HTTP $message_failure, expected 502" >&2; exit 1; }
start_message
curl "${curl_args[@]}" --fail "$base/_p2p/health" >"$tmp/recovered-health.json"
curl "${curl_args[@]}" --fail "$base/_matrix/client/v3/sync?timeout=0" >"$tmp/recovered-sync.json"
grep -Fq '"status":"ok"' "$tmp/recovered-health.json"
grep -Fq '"next_batch":"fault-gate"' "$tmp/recovered-sync.json"

# Agent failure must not interrupt IM. Then restart both application upstreams
# and prove the edge identity and both routes remain stable.
stop_agent
agent_failure=$(curl "${curl_args[@]}" -H 'Authorization: Bearer fault-gate-ticket' -o /dev/null -w '%{http_code}' "$base/agent/v1/status" || true)
[ "$agent_failure" = 502 ] || { echo "Agent outage returned HTTP $agent_failure, expected 502" >&2; exit 1; }
curl "${curl_args[@]}" --fail "$base/_p2p/health" >/dev/null
curl "${curl_args[@]}" --fail "$base/_matrix/client/v3/sync?timeout=0" >"$tmp/agent-down-sync.json"
grep -Fq '"next_batch":"fault-gate"' "$tmp/agent-down-sync.json"
stop_message
start_message
start_agent
curl "${curl_args[@]}" --fail "$base/_p2p/health" >/dev/null
curl "${curl_args[@]}" --fail -H 'Authorization: Bearer fault-gate-ticket' "$base/agent/v1/status" >"$tmp/restarted-agent.json"
grep -Fq '"status":"ok"' "$tmp/restarted-agent.json"
[ "$(docker container inspect --format '{{.Id}}' "$container")" = "$edge_id" ] || {
  echo 'Caddy edge identity changed during the split application restart' >&2
  exit 1
}

printf 'trusted Caddy SSE, split outage isolation, and restart gate passed\n'
