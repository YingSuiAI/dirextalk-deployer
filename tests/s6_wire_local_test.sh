#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$HOME"

# shellcheck disable=SC1090
source "$ROOT/scripts/phases/s6_wire_local.sh"

unset DIREXIO_HOME
[ "$(_direxio_home)" = "$HOME/.direxio" ]
[ "$(DIREXIO_HOME="$tmp/custom-direxio" _direxio_home)" = "$tmp/custom-direxio" ]
[ "$(_direxio_service_id "https://IM.Example.com:8443/_p2p")" = "im.example.com-8443" ]
[ "$(_direxio_service_dir "https://IM.Example.com:8443/_p2p")" = "$HOME/.direxio/nodes/im.example.com-8443" ]

envfile=$(_write_agent_env_file "https://im.example.com" "agent-token" "access-token" "!agent:im.example.com")

[ "$envfile" = "$HOME/.direxio/env" ]
grep -q 'DIREXIO_DOMAIN=https://im.example.com' "$envfile"
grep -q 'DIREXIO_AGENT_TOKEN=agent-token' "$envfile"
grep -q 'DIREXIO_AGENT_ROOM_ID=\\!agent:im.example.com' "$envfile"
! grep -q '^export P2P_' "$envfile"
! grep -q 'P2P_ADMIN_ACCESS_TOKEN' "$envfile"
! grep -q 'P2P_MATRIX_ACCESS_TOKEN' "$envfile"

# shellcheck disable=SC1090
source "$envfile"
[ "$DIREXIO_AGENT_ROOM_ID" = "!agent:im.example.com" ]

if grep -R 'P2P_MATRIX_AS_URL\|P2P_MATRIX_AGENT_TOKEN\|P2P_AGENT_RUNTIME\|p2p-agent-skill\|p2p-matrix-agent' "$ROOT/scripts" "$ROOT/SKILL.md" "$ROOT/references/runtime-wiring.md"; then
  echo "deprecated Matrix-AS env names or old agent skill wiring must not be used by deployer wiring" >&2
  exit 1
fi

[ "$(DIREXIO_AGENT_PLATFORM=hermes _detect_agent_runtime)" = "hermes" ]
[ "$(DIREXIO_AGENT_PLATFORM=openclaw _detect_agent_runtime)" = "openclaw" ]
assert_active_runtime() {
  local expected=$1 signal=$2
  shift 2
  (
    unset HERMES_HOME CODEX_HOME CLAUDE_HOME GEMINI_HOME CURSOR_HOME COPILOT_HOME OPENCLAW_HOME
    unset HERMES_SESSION CODEX_SANDBOX CLAUDECODE GEMINI_CLI CURSOR_TRACE_ID GITHUB_COPILOT_TOKEN OPENCLAW_SESSION
    mkdir -p "$HOME/.hermes" "$HOME/.codex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.cursor" "$HOME/.copilot" "$HOME/.openclaw" "$tmp/neutral"
    cd "$tmp/neutral"
    PATH="/usr/bin:/bin"
    local kv
    for kv in "$@"; do
      export "$kv"
    done
    actual=$(_detect_agent_runtime)
    if [ "$actual" != "$expected" ]; then
      echo "expected active $expected runtime from $signal, got $actual" >&2
      exit 1
    fi
  )
}

assert_active_runtime codex CODEX_SANDBOX CODEX_SANDBOX=1
assert_active_runtime claude-code CLAUDECODE CLAUDECODE=1
assert_active_runtime gemini GEMINI_CLI GEMINI_CLI=1
assert_active_runtime cursor CURSOR_TRACE_ID CURSOR_TRACE_ID=1
assert_active_runtime copilot GITHUB_COPILOT_TOKEN GITHUB_COPILOT_TOKEN=1
assert_active_runtime openclaw OPENCLAW_SESSION OPENCLAW_SESSION=1
assert_active_runtime hermes HERMES_SESSION HERMES_SESSION=1
assert_active_runtime codex .codex/tmp PATH="/tmp/.codex/tmp/codex-arg123:/usr/bin:/bin"
(
  unset HERMES_HOME CODEX_HOME CLAUDE_HOME GEMINI_HOME CURSOR_HOME COPILOT_HOME OPENCLAW_HOME
  unset HERMES_SESSION CODEX_SANDBOX CLAUDECODE GEMINI_CLI CURSOR_TRACE_ID GITHUB_COPILOT_TOKEN OPENCLAW_SESSION
  mkdir -p "$HOME/.hermes" "$HOME/.codex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.cursor" "$HOME/.copilot" "$HOME/.openclaw" "$tmp/neutral"
  cd "$tmp/neutral"
  PATH="/usr/bin:/bin"
  export CLAUDE_API_KEY=test GEMINI_API_KEY=test
  [ "$(_detect_agent_runtime)" = "hermes" ]
)
[ "$(DIREXIO_AGENT_INSTALL=skip _agent_install_policy)" = "skip" ]
[ "$(DIREXIO_AGENT_INSTALL=recommend _agent_install_policy)" = "recommend" ]
[ "$(DIREXIO_AGENT_INSTALL=auto _agent_install_policy)" = "auto" ]
[ "$(_agent_install_mode hermes)" = "native" ]
[ "$(_agent_install_mode openclaw)" = "native" ]
[ "$(_agent_install_mode codex)" = "gateway" ]
[ "$(_agent_install_mode cursor)" = "mcp" ]
[ "$(DIREXIO_AGENT_INSTALL_MODE=gateway _agent_install_mode hermes)" = "gateway" ]

[ "$(_agent_skill_install_path codex)" = "PROJECT_ROOT/.codex/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path claude-code)" = "PROJECT_ROOT/.claude/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path gemini)" = "PROJECT_ROOT/.gemini/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path cursor)" = "PROJECT_ROOT/.cursor/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path copilot)" = "PROJECT_ROOT/.github/copilot/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path openclaw)" = "PROJECT_ROOT/.openclaw/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path hermes)" = "PROJECT_ROOT/.hermes/skills/direxio-deployer" ]
[ "$(_agent_skill_install_path unknown)" = "PROJECT_ROOT/.agent/skills/direxio-deployer" ]

[ "$(_agent_global_skill_install_path codex)" = '${CODEX_HOME:-$HOME/.codex}/skills/direxio-deployer' ]
[ "$(_agent_global_skill_install_path claude-code)" = '${CLAUDE_HOME:-$HOME/.claude}/skills/direxio-deployer' ]
[ "$(_agent_global_skill_install_path generic)" = '$HOME/.agent/skills/direxio-deployer' ]

codex_mcp_fallback=$(
  unset CODEX_HOME
  PATH="/usr/bin:/bin"
  mkdir -p "$tmp/neutral"
  cd "$tmp/neutral"
  _agent_mcp_config_path codex codex-im
)
[ "$codex_mcp_fallback" = "$HOME/.codex/direxio-agent/nodes/codex-im/mcp.json" ]
[ "$(CODEX_HOME=/mnt/c/Users/alice/.codex _agent_mcp_config_path codex codex-im)" = "/mnt/c/Users/alice/.codex/direxio-agent/nodes/codex-im/mcp.json" ]
codex_mcp_from_active_path=$(
  unset CODEX_HOME
  cd "$tmp/neutral"
  PATH="/mnt/c/Users/alice/.codex/tmp/arg0:/usr/bin:/bin" _agent_mcp_config_path codex codex-im
)
[ "$codex_mcp_from_active_path" = "/mnt/c/Users/alice/.codex/direxio-agent/nodes/codex-im/mcp.json" ]
[ "$(_agent_mcp_config_path claude-code codex-im)" = "$HOME/.claude/direxio-agent/nodes/codex-im/mcp.json" ]
[ "$(_agent_mcp_config_path openclaw codex-im)" = "$HOME/.openclaw/direxio/nodes/codex-im/mcp.json" ]
[ "$(_agent_mcp_config_path hermes codex-im)" = "$HOME/.hermes/direxio/nodes/codex-im/mcp.json" ]
[ "$(_agent_mcp_config_path cursor codex-im)" = "$XDG_CONFIG_HOME/direxio-agent/nodes/codex-im/cursor.mcp.json" ]
[ "$(_agent_mcp_config_path copilot codex-im)" = "$XDG_CONFIG_HOME/direxio-agent/nodes/codex-im/copilot.mcp.json" ]
[ "$(_agent_mcp_config_path gemini codex-im)" = "$HOME/.gemini/direxio/nodes/codex-im/settings.json" ]
[ "$(_agent_mcp_config_path unknown codex-im)" = "$XDG_CONFIG_HOME/direxio-agent/nodes/codex-im/mcp.json" ]

[ "$(_agent_project_mcp_target cursor)" = "PROJECT_ROOT/.cursor/mcp.json" ]
[ "$(_agent_project_mcp_target copilot)" = "PROJECT_ROOT/.github/copilot/mcp.json" ]
[ -z "$(_agent_project_mcp_target codex)" ]

cursor_summary=$(_agent_install_target_summary cursor "$(_agent_mcp_config_path cursor)")
[[ "$cursor_summary" == *"PROJECT_ROOT/.cursor/mcp.json"* ]]
[[ "$cursor_summary" == *"PROJECT_ROOT/.cursor/skills/direxio-deployer"* ]]

copilot_summary=$(_agent_install_target_summary copilot "$(_agent_mcp_config_path copilot)")
[[ "$copilot_summary" == *"read-only"* ]]
[[ "$copilot_summary" == *"PROJECT_ROOT/.github/copilot/mcp.json"* ]]
[[ "$copilot_summary" == *"PROJECT_ROOT/.github/copilot/skills/direxio-deployer"* ]]

install_command=$(_agent_install_command hermes native "$HOME/.direxio/nodes/im.example.com/credentials.json")
case "$install_command" in
  *"direxio-agent-install"*"--platform hermes"*"--mode native"*"--credentials-file"*"im.example.com/credentials.json"*"--write"*) ;;
  *)
    echo "install command did not include expected platform/mode/credentials/write flags: $install_command" >&2
    exit 1
    ;;
esac

stale_node_id=$(DIREXIO_AGENT_NODE_ID=codex-old.example.test _agent_node_id codex new.example.test '!agent:new.example.test')
[[ "$stale_node_id" == codex-new.example.test-* ]]

matching_node_id=$(DIREXIO_AGENT_NODE_ID=codex-new.example.test-123 _agent_node_id codex new.example.test '!agent:new.example.test')
[ "$matching_node_id" = "codex-new.example.test-123" ]

guidance=$(
  _print_mcp_plugin_guidance codex https://im.example.com "$HOME/.direxio/nodes/im.example.com/credentials.json" "$HOME/.direxio/nodes/im.example.com/env" recommend gateway "install command" codex-im 2>&1 >/dev/null
)
[[ "$guidance" == *"DIREXIO_DOMAIN"* ]]
[[ "$guidance" == *"DIREXIO_AGENT_TOKEN"* ]]
[[ "$guidance" == *"DIREXIO_AGENT_ROOM_ID"* ]]
[[ "$guidance" == *"DIREXIO_AGENT_NODE_ID"* ]]
[[ "$guidance" == *"DIREXIO_CODEX_COMMAND"* ]]
bad_mcp_env_name="DIREXIO_CREDENTIALS""_FILE"
if [[ "$guidance" == *"$bad_mcp_env_name"* ]]; then
  echo "MCP guidance must not use $bad_mcp_env_name; @direxio/local-mcp expects direct DIREXIO_* env" >&2
  exit 1
fi

echo "s6 wire local ok"
