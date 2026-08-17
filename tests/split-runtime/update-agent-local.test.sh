#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd -P)
script=$script_dir/update-agent-local.sh
[ -x "$script" ]
bash -n "$script"
grep -Fq 'target_image="docker.io/dirextalk/agent:$target_version"' "$script"
grep -Fq '/usr/local/bin/dirextalk-agent' "$script"
grep -Fq '/usr/local/bin/dirextalk-extension-runner' "$script"
grep -Fq '/usr/local/bin/dirextalk-core-runner' "$script"
grep -Fq 'DIREXTALK_AGENT_LOCAL_IMAGE_REF' "$script"
grep -Fq 'docker image tag "$target_image_id" "$target_image"' "$script"
grep -Fq 'DIREXTALK_AGENT_IMAGE="$image"' "$script"
grep -Fq 'rollback_agent' "$script"
grep -Fq 'verify_message_server' "$script"
grep -Fq 'exact receipt-bound message-server container is unavailable' "$script"
grep -Fq 'prepare-agent-start-local.sh' "$script"
grep -Fq 'prepare-runner-cgroups.sh' "$script"
grep -Fq 'restart-agent-local.sh' "$script"
if grep -Eq 'compose\[@\].*(up|ps).*message-server|message-server recreate|new_message_id|recovered_message_id|rollback_message_id' "$script"; then
  echo 'Agent update can recreate or adopt Message Server' >&2
  exit 1
fi
grep -Fq 'agent_http_enabled: true' "$script"
grep -Fq 'agent_http_listen: 0.0.0.0:8082' "$script"
grep -Fq 'capability_grpc_listen' "$script"
if grep -Eq 'config_backup|config_restore|agent-secret-init|materializ' "$script"; then
  echo 'retired Agent config migration remains' >&2
  exit 1
fi
if grep -Eq 'attestation|RepoDigests|@sha256' "$script"; then
  echo 'superseded Agent image attestation contract remains' >&2
  exit 1
fi
printf 'Agent version-tag update contract verified\n'
