#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
state_root="$tmp/root"
base="$state_root/var/dirextalk-message-server"
source_dir="$tmp/payload"
runtime_source="$tmp/agent-runtime"
mkdir -p "$base" "$source_dir" "$runtime_source" "$tmp/bin"

message_image='dirextalk/message-server:v1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
agent_image='registry.example/dirextalk-agent:v1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
reaper_image='registry.example/reaper:v1@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
endpoint='grpcs://worker-control.y1.dirextalk.ai:443'
service_name='com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef0'
foundation="$tmp/foundation.yml"
producer="$source_dir/docker-compose.yml"
printf '%s\n' 'services:' '  agent:' '    environment:' '      AGENT_ENABLE_MANAGED_PREPARATION_AWS: "false"' > "$foundation"
printf '%s\n' 'services:' '  agent:' '    environment:' '      AGENT_ENABLE_MANAGED_PREPARATION_AWS: "false"' \
  "      AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME: \"$service_name\"" > "$producer"
printf '%s\n' '{"schema_version":1,"profiles":[]}' > "$runtime_source/agent-model-profiles.json"
cp "$foundation" "$base/docker-compose.yml"
printf 'MESSAGE_SERVER_IMAGE=%s\nAGENT_IMAGE=%s\nAGENT_INSTANCE_ID=%s\n' \
  "$message_image" "$agent_image" "$instance_id" > "$base/.env"

export FAKE_ACTIVE_MODE="$tmp/mode" FAKE_DOCKER_CALLS="$tmp/calls" FAKE_FAIL_ONCE="$tmp/fail-once"
export FAKE_AGENT_IMAGE="$agent_image" FAKE_INSTANCE_ID="$instance_id" FAKE_REAPER="$reaper_image"
export FAKE_ENDPOINT="$endpoint" FAKE_SERVICE_NAME="$service_name" FAKE_RUNTIME_SOURCE="$runtime_source"
printf 'foundation\n' > "$FAKE_ACTIVE_MODE"
: > "$FAKE_DOCKER_CALLS"

cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  compose)
    case " $* " in
      *" ps -q agent "*) printf 'agent-container\n' ;;
      *" up -d --no-deps agent "*)
        compose_file=
        args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
          [ "${args[$i]}" = -f ] && compose_file=${args[$((i + 1))]}
        done
        mode=foundation
        grep -q 'AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME' "$compose_file" && mode=producer
        printf 'up:%s\n' "$mode" >> "$FAKE_DOCKER_CALLS"
        if [ "$mode" = producer ] && [ -e "$FAKE_FAIL_ONCE" ]; then
          rm -f "$FAKE_FAIL_ONCE"
          exit 72
        fi
        printf '%s\n' "$mode" > "$FAKE_ACTIVE_MODE"
        ;;
      *) exit 90 ;;
    esac
    ;;
  inspect)
    mode=$(cat "$FAKE_ACTIVE_MODE")
    case "$*" in
      *State.Running*) printf 'true\n' ;;
      *Config.Image*) printf '%s\n' "$FAKE_AGENT_IMAGE" ;;
      *Config.Env*)
        printf 'AGENT_INSTANCE_ID=%s\n' "$FAKE_INSTANCE_ID"
        printf 'AGENT_ENABLE_AWS_CONTROL=true\n'
        printf 'AGENT_AWS_REAPER_IMAGE_URI=%s\n' "$FAKE_REAPER"
        printf 'AGENT_WORKER_CONTROL_ENDPOINT=%s\n' "$FAKE_ENDPOINT"
        printf 'AGENT_ENABLE_MANAGED_PREPARATION_AWS=false\n'
        printf 'AGENT_MODEL_PROFILES_FILE=/run/dirextalk-agent/agent-model-profiles.json\n'
        [ "$mode" != producer ] || printf 'AGENT_WORKER_CONTROL_ENDPOINT_SERVICE_NAME=%s\n' "$FAKE_SERVICE_NAME"
        ;;
      *Mounts*) printf '%s|/run/dirextalk-agent|false\n' "$FAKE_RUNTIME_SOURCE" ;;
      *) exit 91 ;;
    esac
    ;;
  *) exit 92 ;;
esac
EOF
chmod 0700 "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"

foundation_sha=$(sha256sum "$foundation" | awk '{print $1}')
producer_sha=$(sha256sum "$producer" | awk '{print $1}')
profiles_sha=$(sha256sum "$runtime_source/agent-model-profiles.json" | awk '{print $1}')
reconcile_with_service() {
  local candidate=${1:-$service_name}
  DIREXTALK_AGENT_AWS_CONTROL_ROOT="$state_root" \
    bash "$ROOT/scripts/updater/reconcile-agent-worker-control.sh" \
      "$source_dir" "$base" "$foundation_sha" "$producer_sha" \
      "$message_image" "$agent_image" "$instance_id" "$profiles_sha" \
      "$reaper_image" "$endpoint" "$candidate"
}
reconcile() { reconcile_with_service "$service_name"; }

before_calls=$(wc -l < "$FAKE_DOCKER_CALLS")
for unsafe_service_name in \
  'com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef' \
  'com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef01' \
  'com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdeF0' \
  'com.amazonaws.vpce.ap-northeast-1.vpce-svc-0123456789abcdef0'; do
  if reconcile_with_service "$unsafe_service_name" > "$tmp/unsafe-service.out" 2>&1; then
    echo "worker-control reconcile accepted unsafe service name: $unsafe_service_name" >&2
    exit 1
  fi
done
[ "$(wc -l < "$FAKE_DOCKER_CALLS")" = "$before_calls" ]

reconcile > "$tmp/first.out"
grep -Fq $'applied\t'"$producer_sha"$'\trestarted' "$tmp/first.out"
cmp "$producer" "$base/docker-compose.yml"
[ "$(grep -c '^up:producer$' "$FAKE_DOCKER_CALLS")" = 1 ]
reconcile > "$tmp/retry.out"
grep -Fq $'applied\t'"$producer_sha"$'\treadback' "$tmp/retry.out"
[ "$(grep -c '^up:producer$' "$FAKE_DOCKER_CALLS")" = 1 ]

# A failed Agent-only recreation restores the exact foundation Compose and
# leaves the mounted runtime/secret volume in place for a safe retry.
cp "$foundation" "$base/docker-compose.yml"
printf 'foundation\n' > "$FAKE_ACTIVE_MODE"
touch "$FAKE_FAIL_ONCE"
if reconcile > "$tmp/fail.out" 2>&1; then
  echo 'worker-control reconcile unexpectedly survived a failed Agent restart' >&2
  exit 1
fi
cmp "$foundation" "$base/docker-compose.yml"
[ "$(cat "$FAKE_ACTIVE_MODE")" = foundation ]
grep -Fq 'up:foundation' "$FAKE_DOCKER_CALLS"

echo 'Agent worker-control staged runtime reconcile ok'
