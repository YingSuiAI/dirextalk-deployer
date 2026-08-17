#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
stack_dir=$(cd -- "$script_dir/.." && pwd -P)
tmp_root=$(printenv TMPDIR 2>/dev/null || true)
[ -n "$tmp_root" ] || tmp_root=/tmp
run_dir=$(mktemp -d "$tmp_root/dirextalk-runner-limits.XXXXXX")
cleanup() {
  rm -rf -- "$run_dir"
}
trap cleanup EXIT

provision_env=(env
  DIREXTALK_MESSAGE_HTTP_BIND=18008
  DIREXTALK_SPLIT_COMPOSE_MODE=production
  DIREXTALK_CORE_EXTENSION_ENABLED=true
  DIREXTALK_CORE_WORKLOAD_ENABLED=true
  DIREXTALK_MESSAGE_TLS_MODE=edge-terminated
  DIREXTALK_MESSAGE_SERVER_NAME=message.example.com
  DIREXTALK_MESSAGE_CLIENT_BASE_URL=https://message.example.com
  DIREXTALK_TURN_EXTERNAL_IP=203.0.113.10
  DIREXTALK_MESSAGE_SERVER_IMAGE=docker.io/dirextalk/message-server:v1.1.32
  DIREXTALK_MESSAGE_SERVER_VERSION=v1.1.32
  DIREXTALK_MESSAGE_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  DIREXTALK_AGENT_IMAGE=docker.io/dirextalk/agent:v1.0.69
  DIREXTALK_AGENT_VERSION=v1.0.69
  DIREXTALK_AGENT_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  DIREXTALK_SPLIT_FIXTURE_MODE=true
  DIREXTALK_SPLIT_TEST_MODE=true)

if "${provision_env[@]}" "$script_dir/provision-local.sh" "$run_dir/missing-region" >/dev/null 2>&1; then
  echo 'production provision accepted a missing Cloud Worker host region' >&2
  exit 1
fi
if DIREXTALK_CLOUD_WORKER_HOST_REGION='ap-east-1;false' \
    "${provision_env[@]}" "$script_dir/provision-local.sh" "$run_dir/invalid-region" >/dev/null 2>&1; then
  echo 'production provision accepted a malformed Cloud Worker host region' >&2
  exit 1
fi
DIREXTALK_CLOUD_WORKER_HOST_REGION=ap-east-1 \
  "${provision_env[@]}" "$script_dir/provision-local.sh" "$run_dir/provision" >/dev/null 2>"$run_dir/provision.stderr"
[ "$(grep -Fxc 'core_cloud_worker_host_region: ap-east-1' "$run_dir/provision/agent-config.yaml")" -eq 1 ]
[ "$(grep -c '^core_cloud_worker_host_region:' "$run_dir/provision/agent-config.yaml")" -eq 1 ]
grep -Fqx 'core_message_mcp_enabled: true' "$run_dir/provision/agent-config.yaml"
grep -Fqx 'core_message_mcp_endpoint: http://message-server:8008/mcp' "$run_dir/provision/agent-config.yaml"
grep -Fqx 'core_message_mcp_token_file: /run/secrets/message_mcp_token' "$run_dir/provision/agent-config.yaml"
[ "$(stat -c '%a:%u:%g:%s' "$run_dir/provision/message-mcp-token")" = "400:$(id -u):$(id -g):0" ]
grep -Fqx "DIREXTALK_MESSAGE_MCP_TOKEN_FILE=$run_dir/provision/message-mcp-token" "$run_dir/provision/.env"
grep -Fqx "message_mcp_token_path=$run_dir/provision/message-mcp-token" "$run_dir/provision/.manifest"
if grep -Fq 'p2p_agent_' "$run_dir/provision/.env" "$run_dir/provision/.manifest" "$run_dir/provision/agent-config.yaml"; then
  echo 'Message MCP token escaped into non-secret configuration' >&2
  exit 1
fi
grep -Fq 'database_url core_secret_master_key message_mcp_token' "$script_dir/materialize-agent-secrets.sh"
# shellcheck disable=SC2016 # Assert the literal materializer loop body.
grep -Fq 'install -m 0400 "/run/secrets/$item" "/out/$item"' "$script_dir/materialize-agent-secrets.sh"
grep -Fq 'chown -R 65532:65532 /out /out-config /out-data' "$script_dir/materialize-agent-secrets.sh"
# shellcheck disable=SC2016 # Assert the literal command substitution in source.
message_identity_line=$(grep -n 'message_server_container_id=$(healthy_service_container message-server)' "$script_dir/start-local.sh" | cut -d: -f1)
token_refresh_line=$(grep -n 'refresh-message-mcp-token.sh' "$script_dir/start-local.sh" | cut -d: -f1)
agent_start_line=$(grep -n 'run_with_heartbeat agent_runtime_wait' "$script_dir/start-local.sh" | cut -d: -f1)
[ "$message_identity_line" -lt "$token_refresh_line" ]
[ "$token_refresh_line" -lt "$agent_start_line" ]
grep -Fqx 'DIREXTALK_CLOUD_WORKER_HOST_REGION=ap-east-1' "$run_dir/provision/cloud-worker-host-region"
static_sites_root=$(awk -F= '$1 == "DIREXTALK_STATIC_SITES_ROOT" {print substr($0,index($0,"=")+1)}' "$run_dir/provision/.env")
[ -n "$static_sites_root" ]

render_and_assert() {
  local output=$1 token_source=$run_dir/provision/message-mcp-token
  shift
  (
    cd -- "$stack_dir"
    "$@" docker compose --env-file "$run_dir/provision/.env" \
      -f compose.yaml -f compose.production.yaml config --format json
  ) >"$output"
  jq -e --arg static_root "$static_sites_root" --arg token_source "$token_source" '
    def exact_runner_security:
      (.security_opt | sort) == ([
        "apparmor=dirextalk-runner-userns",
        "no-new-privileges:true",
        "seccomp=unconfined"
      ] | sort);
    def preserves_outer_runner_boundary:
      .read_only == true and
      .user != "0:0" and
      (.cap_drop == ["ALL"]) and
      .network_mode == "none" and
      exact_runner_security;
    .services["extension-runner"].cpus == 2 and
    (.services["extension-runner"].mem_limit | tostring) == "1073741824" and
    .services["extension-runner"].pids_limit == 256 and
    (.services["extension-runner"] | preserves_outer_runner_boundary) and
    (.services["core-runner"] | preserves_outer_runner_boundary) and
    .services["extension-runner"].cgroup == "host" and
    .services["core-runner"].cgroup == "host" and
    ([.services | to_entries[] |
      select(.key != "extension-runner" and .key != "core-runner") |
      .value.security_opt[]? |
      select(. == "apparmor=dirextalk-runner-userns" or . == "seccomp=unconfined")]
      | length) == 0 and
    (.services["extension-runner"].tmpfs | any(. == "/tmp:rw,noexec,nosuid,nodev,mode=1777")) and
    (.services["core-runner"].tmpfs | any(. == "/tmp:rw,noexec,nosuid,nodev,mode=1777")) and
    (.services["extension-runner"].command as $command |
      ($command | index("--prepared-root")) as $prepared |
      ($command | index("--node-runtime-root")) as $runtime |
      $prepared != null and $command[$prepared + 1] == "/var/lib/dirextalk-agent/extension-install/.prepared" and
      $runtime != null and $command[$runtime + 1] == "/usr/local/libexec/dirextalk-node-runtime") and
    ((.services["extension-runner-storage-init"].command | join("\n")) as $init |
      ($init | contains("mkdir -p /install/.prepared;")) and
      ($init | contains("chown 65531:65531 /install/.prepared;")) and
      ($init | contains("chmod 0700 /install/.prepared;")) and
      ($init | contains("stat -c")) and
      ($init | contains("/install/.prepared"))) and
    ([.services.agent.volumes[] | select(.type == "bind" and .source == $static_root and .target == "/var/lib/dirextalk-agent/static-sites" and .bind.create_host_path == false)] | length) == 1 and
    ([.services["extension-runner"].volumes[] | select(.source == $static_root or .target == "/var/lib/dirextalk-agent/static-sites")] | length) == 0 and
    ([.services["core-runner"].volumes[] | select(.source == $static_root or .target == "/var/lib/dirextalk-agent/static-sites")] | length) == 0 and
    .secrets.message_mcp_token.file == $token_source and
    ([.services | to_entries[] |
      select(any(.value.secrets[]?; .source == "message_mcp_token")) |
      .key] | sort) == ["agent-secret-init"] and
    ([.services["agent-secret-init"].secrets[] |
      select(.source == "message_mcp_token" and .target == "message_mcp_token" and .mode == "0400")] | length) == 1
  ' "$output" >/dev/null
}

render_and_assert "$run_dir/production.json" env

printf '%s\n' 'extension-runner Compose limits test passed'
