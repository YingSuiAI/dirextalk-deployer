#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

required=(
  AGENTS.md
  SKILL.md
  package.json
  README.md
  README_zh.md
  agents/openai.yaml
  bin/dirextalk-deployer.mjs
  scripts/orchestrate.sh
  scripts/orchestrate.ps1
  scripts/destroy.sh
  scripts/destroy.ps1
  scripts/update.sh
  scripts/reset-app-data.sh
  scripts/aws-credentials.sh
  scripts/pricing-estimate.sh
  scripts/json.mjs
  scripts/lib/atomic-write.sh
  scripts/lib/json.sh
  scripts/lib/local-paths.sh
  scripts/lib/windows-paths.ps1
  scripts/lib/mcp-client-adapters.sh
  scripts/phases/s6_wire_local.sh
  references/agent-targets.md
  references/deployment-workflow.md
  references/runtime-wiring.md
  references/verification-recovery.md
  references/windows-deployment-notes.md
)

for path in "${required[@]}"; do
  [ -s "$path" ] || { echo "missing or empty required file: $path" >&2; exit 1; }
done

grep -q '^name: dirextalk-deployer$' SKILL.md
grep -q '^description: .*deploy, resume, status, verify, update, reset, destroy' SKILL.md
grep -q 'latest published stable GitHub Release' SKILL.md
grep -q 'immutable image digest' SKILL.md
grep -q 'Ubuntu 22.04/24.04' SKILL.md
grep -q 'agent_room_id' SKILL.md
grep -q 'https://<domain>/mcp' SKILL.md
grep -q 'explicit confirmation' SKILL.md
grep -q 'operation-report.json' SKILL.md
grep -q 'possible_remaining_billable_resources' SKILL.md
grep -q 'DIREXTALK_RESET_APP_DATA_CONFIRM=1' SKILL.md
grep -q 'destroy.ps1' SKILL.md

skill_lines=$(wc -l < SKILL.md)
if [ "$skill_lines" -gt 180 ]; then
  echo "SKILL.md should stay a compact entrypoint (lines=$skill_lines)" >&2
  exit 1
fi

if grep -q 'npm install -g' SKILL.md; then
  echo "operations skill must not mutate the global toolchain automatically" >&2
  exit 1
fi
if grep -q 'dirextalk/message-server:latest' SKILL.md; then
  echo "production guidance must not pin a mutable latest image" >&2
  exit 1
fi
if grep -Eq '100-200 USD|three months of free Lightsail|Root access key \(default fastest path\)|AdministratorAccess.*default' SKILL.md; then
  echo "time-sensitive promotions and broad root/admin defaults belong outside SKILL.md" >&2
  exit 1
fi

legacy_json_cli_name=$(printf '\152\161')
legacy_json_cli_pattern="(^|[^[:alnum:]_])${legacy_json_cli_name}([^[:alnum:]_]|$)|${legacy_json_cli_name}\\.exe"
if grep -R -n -E "$legacy_json_cli_pattern" scripts tests README.md README_zh.md SKILL.md references AGENTS.md agents package.json docs >/dev/null; then
  echo "current docs/scripts/tests must use scripts/json.mjs" >&2
  exit 1
fi

if grep -RE 'dirextalk-mcp|127\.0\.0\.1:19757|localhost:19757|serve-http' AGENTS.md SKILL.md README.md README_zh.md agents references scripts package.json .github >/dev/null; then
  echo "active docs/scripts must not restore the retired local MCP implementation" >&2
  exit 1
fi
if grep -RE '(^|[^[:alnum:]_])([a-z0-9-]+\.)*example\.com([^[:alnum:]_]|$)|agentp2p\.im|54\.161\.73\.211' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published material must use placeholders, not example/session domains or IPs" >&2
  exit 1
fi

grep -q 'mcp_agent_token' scripts/phases/s6_wire_local.sh
grep -q 'agent_room_id' scripts/phases/s6_wire_local.sh
grep -q 'mcp_capability' scripts/phases/s6_wire_local.sh
grep -q 'mcp_endpoint_url' scripts/phases/s6_wire_local.sh
grep -q '^codex|session|none$' scripts/lib/mcp-client-adapters.sh
grep -q '^cursor|host-managed|none$' scripts/lib/mcp-client-adapters.sh
grep -q '^hermes|host-managed|hermes$' scripts/lib/mcp-client-adapters.sh
grep -q '^pi|unsupported|none$' scripts/lib/mcp-client-adapters.sh

if grep -q '_write_mcp_json_config "$hermes_config"' scripts/lib/mcp-client-adapters.sh; then
  echo "Hermes must use native host guidance, not generic MCP JSON" >&2
  exit 1
fi
if grep -q '_write_agent_env_file\|state_set agent_env_file' scripts/phases/s6_wire_local.sh; then
  echo "S6 must not recreate the retired service env artifact" >&2
  exit 1
fi
if awk '/_write_connect_config\(\)/,/^}/' scripts/phases/s6_wire_local.sh | grep -q 'DIREXTALK_CREDENTIALS_FILE'; then
  echo "dirextalk-connect must use direct Matrix config" >&2
  exit 1
fi

echo "skill structure ok"
