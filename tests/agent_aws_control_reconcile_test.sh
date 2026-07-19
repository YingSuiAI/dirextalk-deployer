#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

state_root="$tmp/root"
base="$state_root/var/dirextalk-message-server"
source_dir="$tmp/payload"
mkdir -p "$base" "$source_dir" "$tmp/bin"

message_image='dirextalk/message-server:v1.2.3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
agent_image='registry.example/dirextalk-agent:v0.1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
agent_instance_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
foundation_compose="$tmp/foundation-compose.yml"
managed_compose="$source_dir/docker-compose.yml"
publication="$source_dir/agent-worker-ami-publication.json"
runtime_source="$tmp/agent-runtime"
profiles_file="$runtime_source/agent-model-profiles.json"
reaper_image='registry.example/dirextalk-aws-reaper:v0.1.0@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
worker_endpoint='grpcs://worker-control.example.test:443'
mkdir -p "$runtime_source"

cat > "$foundation_compose" <<'EOF'
services:
  agent:
    environment:
      AGENT_ENABLE_MANAGED_PREPARATION_AWS: "false"
EOF
cat > "$managed_compose" <<'EOF'
services:
  agent:
    environment:
      AGENT_ENABLE_MANAGED_PREPARATION_AWS: "true"
      AGENT_WORKER_AMI_PUBLICATION_FILE: /run/dirextalk-agent/worker-ami-publication.json
    volumes:
      - ./agent-worker-ami-publication.json:/run/dirextalk-agent/worker-ami-publication.json:ro
EOF
printf '%s\n' '{"schema_version":"dirextalk.agent.worker-ami-publication/v1","image_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}' > "$publication"
printf '%s\n' '{"schema_version":1,"profiles":[]}' > "$profiles_file"
cp "$foundation_compose" "$base/docker-compose.yml"
cat > "$base/.env" <<EOF
MESSAGE_SERVER_IMAGE=$message_image
AGENT_IMAGE=$agent_image
AGENT_INSTANCE_ID=$agent_instance_id
EOF

export FAKE_DOCKER_CALLS="$tmp/docker-calls"
export FAKE_ACTIVE_MODE="$tmp/active-mode"
export FAKE_DOCKER_FAIL_ONCE="$tmp/docker-fail-once"
export FAKE_DOCKER_UP_DELAY_FILE="$tmp/docker-up-delay"
export FAKE_BASE="$base"
export FAKE_RUNTIME_SOURCE="$runtime_source"
export FAKE_AGENT_IMAGE="$agent_image"
export FAKE_AGENT_INSTANCE_ID="$agent_instance_id"
export FAKE_REAPER_IMAGE="$reaper_image"
export FAKE_WORKER_ENDPOINT="$worker_endpoint"
export FAKE_PUBLICATION_SOURCE_OVERRIDE=
export FAKE_DUPLICATE_MANAGED_ENV=
printf 'foundation\n' > "$FAKE_ACTIVE_MODE"
: > "$FAKE_DOCKER_CALLS"

cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  compose)
    case " $* " in
      *" ps -q agent "*)
        printf 'agent-container\n'
        ;;
      *" up -d --no-deps agent "*)
        mode=foundation
        compose_file=
        args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
          [ "${args[$i]}" = -f ] && compose_file=${args[$((i + 1))]}
        done
        grep -q 'AGENT_ENABLE_MANAGED_PREPARATION_AWS: "true"' "$compose_file" && mode=managed
        printf 'up:%s\n' "$mode" >> "$FAKE_DOCKER_CALLS"
        if [ -e "$FAKE_DOCKER_FAIL_ONCE" ]; then
          rm -f "$FAKE_DOCKER_FAIL_ONCE"
          exit 72
        fi
        [ ! -e "$FAKE_DOCKER_UP_DELAY_FILE" ] || sleep 1
        printf '%s\n' "$mode" > "$FAKE_ACTIVE_MODE"
        ;;
      *)
        echo "unexpected docker compose command: $*" >&2
        exit 90
        ;;
    esac
    ;;
  inspect)
    mode=$(cat "$FAKE_ACTIVE_MODE")
    case "$*" in
      *State.Running*)
        printf 'true\n'
        ;;
      *Config.Image*)
        printf '%s\n' "$FAKE_AGENT_IMAGE"
        ;;
      *Config.Env*)
        printf 'AGENT_INSTANCE_ID=%s\n' "$FAKE_AGENT_INSTANCE_ID"
        printf 'AGENT_ENABLE_AWS_CONTROL=true\n'
        printf 'AGENT_AWS_REAPER_IMAGE_URI=%s\n' "$FAKE_REAPER_IMAGE"
        printf 'AGENT_WORKER_CONTROL_ENDPOINT=%s\n' "$FAKE_WORKER_ENDPOINT"
        printf 'AGENT_MODEL_PROFILES_FILE=/run/dirextalk-agent/agent-model-profiles.json\n'
        case "$mode" in
          foundation) printf 'AGENT_ENABLE_MANAGED_PREPARATION_AWS=false\n' ;;
          managed)
            printf 'AGENT_ENABLE_MANAGED_PREPARATION_AWS=true\n'
            printf 'AGENT_WORKER_AMI_PUBLICATION_FILE=/run/dirextalk-agent/worker-ami-publication.json\n'
            [ -z "$FAKE_DUPLICATE_MANAGED_ENV" ] || printf 'AGENT_ENABLE_MANAGED_PREPARATION_AWS=false\n'
            ;;
          drift) printf 'AGENT_ENABLE_MANAGED_PREPARATION_AWS=changed\n' ;;
        esac
        ;;
      *Mounts*)
        printf '%s|/run/dirextalk-agent|false\n' "$FAKE_RUNTIME_SOURCE"
        if [ "$mode" = managed ]; then
          publication_source=${FAKE_PUBLICATION_SOURCE_OVERRIDE:-$FAKE_BASE/agent-worker-ami-publication.json}
          printf '%s|/run/dirextalk-agent/worker-ami-publication.json|false\n' "$publication_source"
        fi
        ;;
      *)
        echo "unexpected docker inspect command: $*" >&2
        exit 91
        ;;
    esac
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 92
    ;;
esac
EOF
chmod 0700 "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"

foundation_sha=$(sha256sum "$foundation_compose" | awk '{print $1}')
managed_sha=$(sha256sum "$managed_compose" | awk '{print $1}')
publication_sha=$(sha256sum "$publication" | awk '{print $1}')
profiles_sha=$(sha256sum "$profiles_file" | awk '{print $1}')
marker="$state_root/var/lib/dirextalk-bootstrap/agent-aws-control-import"

reconcile() {
  DIREXTALK_AGENT_AWS_CONTROL_ROOT="$state_root" \
    bash "$ROOT/scripts/updater/reconcile-agent-aws-control.sh" \
      "$source_dir" "$base" "$foundation_sha" "$managed_sha" "$publication_sha" \
      "$message_image" "$agent_image" "$agent_instance_id" "$profiles_sha" \
      "$reaper_image" "$worker_endpoint"
}

# First application installs exact bytes and restarts the Agent once.
reconcile > "$tmp/success.out"
grep -F -q $'applied\t'"$managed_sha"$'\t'"$publication_sha"$'\trestarted' "$tmp/success.out"
cmp "$managed_compose" "$base/docker-compose.yml"
cmp "$publication" "$base/agent-worker-ami-publication.json"
grep -Fxq "compose_sha256=$managed_sha" "$marker"
grep -Fxq "publication_sha256=$publication_sha" "$marker"
[ "$(grep -c '^up:managed$' "$FAKE_DOCKER_CALLS")" = 1 ]

# Concurrent invocations serialize on the host and perform one mutation.
cp "$foundation_compose" "$base/docker-compose.yml"
rm -f "$base/agent-worker-ami-publication.json" "$marker"
printf 'foundation\n' > "$FAKE_ACTIVE_MODE"
: > "$FAKE_DOCKER_CALLS"
touch "$FAKE_DOCKER_UP_DELAY_FILE"
reconcile > "$tmp/concurrent-1.out" &
first_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^up:managed$' "$FAKE_DOCKER_CALLS" && break
  sleep 0.1
done
reconcile > "$tmp/concurrent-2.out" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
rm -f "$FAKE_DOCKER_UP_DELAY_FILE"
[ "$(grep -c '^up:managed$' "$FAKE_DOCKER_CALLS")" = 1 ]
[ "$(grep -l $'\trestarted$' "$tmp/concurrent-1.out" "$tmp/concurrent-2.out" | wc -l | tr -d '[:space:]')" = 1 ]
[ "$(grep -l $'\treadback$' "$tmp/concurrent-1.out" "$tmp/concurrent-2.out" | wc -l | tr -d '[:space:]')" = 1 ]

# Exact retry and a crash after remote mutation both resolve by readback.
reconcile > "$tmp/retry.out"
grep -q $'\treadback$' "$tmp/retry.out"
[ "$(grep -c '^up:managed$' "$FAKE_DOCKER_CALLS")" = 1 ]
rm -f "$marker"
reconcile > "$tmp/crash-readback.out"
grep -q $'\treadback$' "$tmp/crash-readback.out"
[ -s "$marker" ]
[ "$(grep -c '^up:managed$' "$FAKE_DOCKER_CALLS")" = 1 ]

# Missing or changed payload bytes and core drift fail before any restart.
before_up=$(wc -l < "$FAKE_DOCKER_CALLS")
mv "$publication" "$tmp/publication.saved"
if reconcile > "$tmp/missing-publication.out" 2>&1; then
  echo "reconcile accepted a missing publication payload" >&2
  exit 1
fi
mv "$tmp/publication.saved" "$publication"
printf '\n' >> "$publication"
if reconcile > "$tmp/changed-publication.out" 2>&1; then
  echo "reconcile accepted changed publication bytes" >&2
  exit 1
fi
printf '%s\n' '{"schema_version":"dirextalk.agent.worker-ami-publication/v1","image_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}' > "$publication"
sed -i "s|^AGENT_IMAGE=.*|AGENT_IMAGE=registry.example/drift@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd|" "$base/.env"
if reconcile > "$tmp/core-drift.out" 2>&1; then
  echo "reconcile accepted changed Agent core inputs" >&2
  exit 1
fi
sed -i "s|^AGENT_IMAGE=.*|AGENT_IMAGE=$agent_image|" "$base/.env"
[ "$(wc -l < "$FAKE_DOCKER_CALLS")" = "$before_up" ]

# Exact runtime readback rejects image, model-profile, mount, and environment drift.
FAKE_AGENT_IMAGE='registry.example/dirextalk-agent:v0.1.0@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
export FAKE_AGENT_IMAGE
if reconcile > "$tmp/image-drift.out" 2>&1; then
  echo "reconcile accepted a changed running Agent image" >&2
  exit 1
fi
FAKE_AGENT_IMAGE=$agent_image
export FAKE_AGENT_IMAGE
printf '%s\n' '{"schema_version":1,"profiles":[{"profile_id":"drift"}]}' > "$profiles_file"
if reconcile > "$tmp/profile-drift.out" 2>&1; then
  echo "reconcile accepted changed mounted model-profile bytes" >&2
  exit 1
fi
printf '%s\n' '{"schema_version":1,"profiles":[]}' > "$profiles_file"
export FAKE_PUBLICATION_SOURCE_OVERRIDE="$tmp/wrong-publication-source"
if reconcile > "$tmp/mount-drift.out" 2>&1; then
  echo "reconcile accepted a changed publication mount source" >&2
  exit 1
fi
export FAKE_PUBLICATION_SOURCE_OVERRIDE=
export FAKE_DUPLICATE_MANAGED_ENV=1
if reconcile > "$tmp/duplicate-env-drift.out" 2>&1; then
  echo "reconcile accepted duplicate conflicting managed-preparation environment" >&2
  exit 1
fi
export FAKE_DUPLICATE_MANAGED_ENV=

# Other runtime drift is never overwritten even when the target files match.
printf 'drift\n' > "$FAKE_ACTIVE_MODE"
if reconcile > "$tmp/runtime-drift.out" 2>&1; then
  echo "reconcile overwrote active Agent runtime drift" >&2
  exit 1
fi
[ "$(wc -l < "$FAKE_DOCKER_CALLS")" = "$before_up" ]
printf 'managed\n' > "$FAKE_ACTIVE_MODE"

# A failed managed restart restores usable foundation bytes and is retryable.
cp "$foundation_compose" "$base/docker-compose.yml"
rm -f "$base/agent-worker-ami-publication.json" "$marker"
printf 'foundation\n' > "$FAKE_ACTIVE_MODE"
: > "$FAKE_DOCKER_CALLS"
touch "$FAKE_DOCKER_FAIL_ONCE"
if reconcile > "$tmp/rollback.out" 2>&1; then
  echo "reconcile unexpectedly succeeded after managed restart failure" >&2
  exit 1
fi
cmp "$foundation_compose" "$base/docker-compose.yml"
[ ! -e "$base/agent-worker-ami-publication.json" ]
[ ! -e "$marker" ]
[ "$(cat "$FAKE_ACTIVE_MODE")" = foundation ]
grep -Fxq 'up:managed' "$FAKE_DOCKER_CALLS"
grep -Fxq 'up:foundation' "$FAKE_DOCKER_CALLS"

reconcile > "$tmp/rollback-retry.out"
grep -q $'\trestarted$' "$tmp/rollback-retry.out"
cmp "$managed_compose" "$base/docker-compose.yml"
cmp "$publication" "$base/agent-worker-ami-publication.json"
[ "$(cat "$FAKE_ACTIVE_MODE")" = managed ]

echo "Agent AWS-control remote reconcile state machine ok"
