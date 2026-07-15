#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_KEEP_WORKDIR=1
export AWS_DEFAULT_REGION=us-east-1
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "sts get-caller-identity") printf 'arn:aws:iam::123456789012:user/DirextalkDeployer\n' ;;
  *) exit 0 ;;
esac
EOF
chmod 700 "$fakebin/aws"

cat > "$fakebin/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'OPENCLAW_CONFIG_PATH=%s\n' "${OPENCLAW_CONFIG_PATH:-}" >> "$OPENCLAW_CALLS"
printf '%s\n' "$*" >> "$OPENCLAW_CALLS"
case "$*" in
  *'config patch --stdin'*) cat > "$OPENCLAW_PATCH" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$fakebin/openclaw"

cat > "$fakebin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'HERMES_HOME=%s\n' "${HERMES_HOME:-}" >> "$HERMES_CALLS"
printf '%s\n' "$*" >> "$HERMES_CALLS"
[ "${1:-}" = profile ] && [ "${2:-}" = delete ] && [ "${3:-}" = -y ]
EOF
chmod 700 "$fakebin/hermes"

write_state() {
  local state=$1 service_dir=$2 owner=$3
  mkdir -p "$service_dir"
  case "$owner" in
    openclaw)
      json_build object \
        region=us-east-1 \
        cloud_provider=lightsail \
        domain_mode=user \
        domain=cleanup-openclaw.example.test \
        "agent_service_dir=$service_dir" \
        agent_service_id=cleanup-openclaw.example.test \
        mcp_host_registry_owner=openclaw \
        mcp_host_registry_server=dirextalk-cleanup-openclaw \
        mcp_host_token_env_key=DIREXTALK_MCP_DIREXTALK_CLEANUP_OPENCLAW_AGENT_TOKEN \
        "mcp_openclaw_config_path=$tmp/openclaw-config.json" > "$state"
      ;;
    hermes)
      json_build object \
        region=us-east-1 \
        cloud_provider=lightsail \
        domain_mode=user \
        domain=cleanup-hermes.example.test \
        "agent_service_dir=$service_dir" \
        agent_service_id=cleanup-hermes.example.test \
        mcp_host_registry_owner=hermes \
        mcp_host_registry_server=dirextalk-cleanup-hermes \
        mcp_host_token_env_key=DIREXTALK_MCP_DIREXTALK_CLEANUP_HERMES_AGENT_TOKEN \
        "mcp_hermes_home=$tmp/hermes-home" \
        mcp_hermes_profile=dirextalk-cleanup-hermes \
        mcp_hermes_profile_owned=true > "$state"
      ;;
  esac
}

openclaw_service="$HOME/.dirextalk/nodes/cleanup-openclaw.example.test"
openclaw_state="$openclaw_service/state.json"
write_state "$openclaw_state" "$openclaw_service" openclaw
: > "$tmp/openclaw.calls"
PATH="$fakebin:$PATH" DIREXTALK_OPENCLAW_COMMAND="$fakebin/openclaw" OPENCLAW_CALLS="$tmp/openclaw.calls" OPENCLAW_PATCH="$tmp/openclaw.patch.json" \
  bash "$ROOT/scripts/destroy.sh" "$openclaw_state" >/dev/null
grep -Fxq "OPENCLAW_CONFIG_PATH=$tmp/openclaw-config.json" "$tmp/openclaw.calls"
grep -Fxq 'config patch --stdin' "$tmp/openclaw.calls"
json_test_check "$tmp/openclaw.patch.json" 'data.mcp.servers["dirextalk-cleanup-openclaw"] === null && data.env.vars.DIREXTALK_MCP_DIREXTALK_CLEANUP_OPENCLAW_AGENT_TOKEN === null'

hermes_service="$HOME/.dirextalk/nodes/cleanup-hermes.example.test"
hermes_state="$hermes_service/state.json"
write_state "$hermes_state" "$hermes_service" hermes
: > "$tmp/hermes.calls"
PATH="$fakebin:$PATH" DIREXTALK_HERMES_COMMAND="$fakebin/hermes" HERMES_CALLS="$tmp/hermes.calls" \
  bash "$ROOT/scripts/destroy.sh" "$hermes_state" >/dev/null
grep -Fxq "HERMES_HOME=$tmp/hermes-home" "$tmp/hermes.calls"
grep -Fxq 'profile delete -y dirextalk-cleanup-hermes' "$tmp/hermes.calls"

echo "destroy host MCP cleanup ok"
