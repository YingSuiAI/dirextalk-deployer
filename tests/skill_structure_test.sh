#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

required=(
  AGENTS.md
  package.json
  SKILL.md
  README.md
  README_zh.md
  agents/README.md
  agents/openai.yaml
  bin/direxio-deployer.mjs
  scripts/orchestrate.sh
  scripts/orchestrate.ps1
  scripts/aws-credentials.sh
  scripts/destroy.sh
  scripts/destroy.ps1
  scripts/json.mjs
  scripts/update.sh
  scripts/reset-app-data.sh
  scripts/pricing-estimate.sh
  scripts/mcp-tools-list.mjs
  scripts/lib/windows-paths.ps1
  scripts/lib/ops.sh
  scripts/lib/operation_report.sh
  scripts/lib/json.sh
  scripts/phases/s6_wire_local.sh
  tests/json_helper_test.sh
  tests/lib/json_test.sh
  tests/operation_report_test.sh
  tests/npm_skill_distribution_test.sh
  tests/private_file_permissions_test.sh
  tests/local_paths_test.sh
  tests/windows_path_wrappers_test.sh
  tests/windows_path_wrappers_test.ps1
  tests/orchestrate_status_recovery_test.sh
  tests/update_reset_ops_test.sh
  tests/aws_credentials_test.sh
  tests/connect_daemon_runtime_check_test.sh
  tests/pricing_estimate_test.sh
  tests/eip_preflight_test.sh
  tests/route53_zone_auto_create_test.sh
  tests/route53_overwrite_guard_test.sh
  tests/destroy_root_identity_test.sh
  tests/destroy_route53_zone_test.sh
  tests/domain_authoritative_dns_test.sh
  tests/mcp_doctor_runtime_check_test.sh
  tests/mcp_smoke_runtime_check_test.sh
  tests/mcp_tools_runtime_check_test.sh
  tests/root_volume_tracking_test.sh
  tests/runtime_summary_check_test.sh
  tests/user_confirmation_gates_test.sh
  references/agent-targets.md
  references/deployment-optimization-audit.md
  references/runtime-wiring.md
)

for path in "${required[@]}"; do
  [ -s "$path" ] || {
    echo "missing or empty required file: $path" >&2
    exit 1
  }
done

skill_lines=$(wc -l < SKILL.md | tr -d ' ')
if [ "$skill_lines" -gt 360 ]; then
  echo "SKILL.md should stay concise; move detailed runbook material to references/ (lines=$skill_lines)" >&2
  exit 1
fi

legacy_json_cli_name=$(printf '\152\161')
legacy_json_cli_pattern="(^|[^[:alnum:]_])${legacy_json_cli_name}([^[:alnum:]_]|$)|${legacy_json_cli_name}\\.exe"
if grep -R -n -E "$legacy_json_cli_pattern" scripts tests README.md README_zh.md SKILL.md references AGENTS.md agents package.json docs >/dev/null; then
  echo "current docs/scripts/tests must use scripts/json.mjs instead of the legacy external JSON CLI" >&2
  grep -R -n -E "$legacy_json_cli_pattern" scripts tests README.md README_zh.md SKILL.md references AGENTS.md agents package.json docs >&2
  exit 1
fi

grep -q 'direxio/message-server:latest' SKILL.md
grep -q 'direxio-deployer' package.json
grep -q 'bin/direxio-deployer.mjs' package.json
grep -q 'compact agent-facing entrypoint' AGENTS.md
grep -q 'scripts/lib/local-paths.sh' AGENTS.md
grep -q 'scripts/lib/windows-paths.ps1' AGENTS.md
grep -q 'scripts/json.mjs' AGENTS.md
grep -q 'direxio-connent@latest' AGENTS.md
grep -q 'direxio-mcp@latest' AGENTS.md
grep -q 'bash tests/local_paths_test.sh' AGENTS.md
grep -q 'npm test' AGENTS.md
grep -q 'scripts/json.mjs' agents/README.md
grep -q 'direxio-connect' agents/README.md
grep -q 'direxio-connect' agents/openai.yaml
grep -q 'direxio-mcp' agents/openai.yaml
grep -q 'connect_install_status' SKILL.md
grep -q 'connect_install_status' scripts/phases/s6_wire_local.sh
grep -q 'connect_install_status' scripts/orchestrate.sh
grep -q 'skill install --agent' README.md
grep -q 'skill update --agent' README_zh.md
grep -q 'skill refresh --agent' SKILL.md
grep -q 'Windows PowerShell' README.md
grep -q 'Windows PowerShell' README_zh.md
grep -q '.direxio-skill-install.json' references/agent-targets.md
grep -q 'DIREXIO_DOMAIN' scripts/phases/s6_wire_local.sh
grep -q 'DIREXIO_AGENT_TOKEN' scripts/phases/s6_wire_local.sh
grep -q 'DIREXIO_AGENT_ROOM_ID' scripts/phases/s6_wire_local.sh
grep -q 'DIREXIO_CONNECT_REPO' scripts/phases/s6_wire_local.sh
grep -q 'DIREXIO_LOCAL_PATH_STYLE' scripts/phases/s6_wire_local.sh
grep -q 'DIREXIO_CREDENTIALS_FILE' scripts/phases/s6_wire_local.sh
grep -q 'direxio-mcp' scripts/phases/s6_wire_local.sh
grep -q 'PLATFORMS_INCLUDE=matrix' scripts/phases/s6_wire_local.sh
grep -q 'YingSuiAI/direxio-connect.git' scripts/phases/s6_wire_local.sh
grep -q 'DIREXIO_CONNECT_AGENT' scripts/phases/s6_wire_local.sh
grep -q 'orchestrate.ps1' README.md
grep -q 'destroy.ps1' README.md
grep -q 'destroy.ps1' README_zh.md
grep -q 'destroy.ps1' SKILL.md
grep -q 'destroy.ps1' references/deployment-workflow.md
grep -q 'destroy.ps1' references/windows-deployment-notes.md
grep -q 'direxio-connect' SKILL.md
grep -q 'mcp_config_dir' SKILL.md
grep -q 'mcp_codex_config' references/runtime-wiring.md
if grep -R '@direxio/agent-plugins' SKILL.md scripts README.md README_zh.md references >/dev/null; then
  echo "current docs/scripts must not reference legacy agent plugin packages" >&2
  exit 1
fi
legacy_agent_install_prefix=$(printf 'agent_%s' 'install')
if grep -R -n "${legacy_agent_install_prefix}_status\\|${legacy_agent_install_prefix}_policy\\|${legacy_agent_install_prefix}_mode\\|${legacy_agent_install_prefix}_command" SKILL.md scripts README.md README_zh.md references AGENTS.md agents tests/*.sh >/dev/null; then
  echo "connect daemon install state must use connect_install_* fields, not stale agent_install_* fields" >&2
  grep -R -n "${legacy_agent_install_prefix}_status\\|${legacy_agent_install_prefix}_policy\\|${legacy_agent_install_prefix}_mode\\|${legacy_agent_install_prefix}_command" SKILL.md scripts README.md README_zh.md references AGENTS.md agents tests/*.sh >&2
  exit 1
fi
legacy_plugin_word=plugin
legacy_mcp_plugin_pattern="MCP/${legacy_plugin_word}|agent ${legacy_plugin_word}s|${legacy_plugin_word} access|${legacy_plugin_word} configuration|wire Direxio MCP/${legacy_plugin_word}|runtime-specific ${legacy_plugin_word}"
if grep -R -n -E "$legacy_mcp_plugin_pattern" AGENTS.md agents SKILL.md README.md README_zh.md references >/dev/null; then
  echo "current docs and agent metadata must not use stale combined MCP and extension wording" >&2
  grep -R -n -E "$legacy_mcp_plugin_pattern" AGENTS.md agents SKILL.md README.md README_zh.md references >&2
  exit 1
fi
grep -q '简体中文](README_zh.md)' README.md
grep -q '通用 Agent Skill' README_zh.md
grep -q 'PROJECT_ROOT/.cursor/skills/direxio-deployer' references/agent-targets.md
grep -q 'direxio-connent' references/agent-targets.md
grep -q 'direxio-connect daemon install' references/agent-targets.md
grep -q 'acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux' references/agent-targets.md

legacy_cc_repo=$(printf 'cc-%s' 'connect')
wrong_connect_repo=$(printf 'direxio-%s' 'connext')
if grep -R "YingSuiAI/${legacy_cc_repo}\\|github.com/YingSuiAI/${legacy_cc_repo}\\|YingSuiAI/${wrong_connect_repo}\\|github.com/YingSuiAI/${wrong_connect_repo}" SKILL.md scripts README.md README_zh.md references AGENTS.md >/dev/null; then
  echo "current docs/scripts must use YingSuiAI/direxio-connect, not stale bridge repository names" >&2
  exit 1
fi

if grep -RE '(^|[^[:alnum:]_])([a-z0-9-]+\.)*example\.com([^[:alnum:]_]|$)' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must use placeholders such as __DOMAIN__, not example.com-style domains" >&2
  exit 1
fi

if grep -RE '(^|[^[:alnum:]_])([a-z0-9-]+\.)*direxio\.ai([^[:alnum:]_]|$)' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must use placeholders such as __DOMAIN__, not real Direxio-owned domains" >&2
  exit 1
fi

if grep -RE 'agentp2p\.im|54\.161\.73\.211' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must use placeholders such as __DOMAIN__ and __EIP__, not session-specific domains or IPs" >&2
  exit 1
fi

if awk '/_write_connect_config\(\)/,/^}/' scripts/phases/s6_wire_local.sh | grep -q 'DIREXIO_CREDENTIALS_FILE'; then
  echo "direxio-connect config must not use DIREXIO_CREDENTIALS_FILE; it must use direct Matrix config" >&2
  exit 1
fi

if awk '/_print_connect_guidance\(\)/,/^}/' scripts/phases/s6_wire_local.sh | grep -q 'DIREXIO_CREDENTIALS_FILE'; then
  echo "direxio-connect guidance must not use DIREXIO_CREDENTIALS_FILE; MCP guidance owns that env var" >&2
  exit 1
fi

if grep -RE 'fixed order.*\.codex.*\.hermes|\.codex.*checked before.*\.hermes' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must not describe stale Codex-before-Hermes runtime detection" >&2
  exit 1
fi

if grep -R 'direxio-mcp@0\.1\.[0-9]' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must not reference stale direxio-mcp versions" >&2
  exit 1
fi

if grep -R 'direxio-connent@1\.' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must not pin direxio-connent by default" >&2
  exit 1
fi

if grep -RE 'Elastic IP.*attached.*free|attached.*Elastic IP.*free' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must not say attached Elastic IP or public IPv4 is free" >&2
  exit 1
fi

if grep -F 'Host runtimes such as Hermes or OpenClaw are not direxio-connect backends; when they are detected, set `DIREXIO_CONNECT_AGENT` explicitly' SKILL.md >/dev/null; then
  echo "SKILL.md must not override ACP-backed OpenClaw/Hermes defaults with stale explicit-agent guidance" >&2
  exit 1
fi

if grep -F 'paste into the IM login form' scripts/orchestrate.sh SKILL.md >/dev/null; then
  echo "delivery output must present the password field as an app initialization code, not an IM login form password" >&2
  exit 1
fi

if grep -F 'Deployment Complete' scripts/orchestrate.sh SKILL.md references/deployment-workflow.md >/dev/null; then
  echo "delivery output must not call S7 green the final deployment completion state" >&2
  exit 1
fi

if grep -F 'Service URL' scripts/orchestrate.sh SKILL.md references/deployment-workflow.md >/dev/null; then
  echo "new deployment delivery should give the App domain and init code, not a service URL/initialization URL" >&2
  exit 1
fi

if grep -F 'Destroy      :' scripts/orchestrate.sh SKILL.md >/dev/null; then
  echo "new deployment delivery should not present destroy as a user-copied command; ask the agent to destroy instead" >&2
  exit 1
fi

if grep -R 'destroy command' SKILL.md references/user-journey.md references/deployment-lessons.md >/dev/null; then
  echo "new deployment delivery docs should describe asking the agent to destroy, not delivering a destroy command" >&2
  exit 1
fi

grep -q 'Root access keys are allowed when the operator explicitly chooses them' SKILL.md

if grep -RE '_find_route53_zone.*does NOT create|never creates hosted zone|hosted zone must exist before S3_PROVISION|Do not rely on the script to create the zone' SKILL.md references README.md README_zh.md >/dev/null; then
  echo "published docs must not preserve stale Route53 hosted-zone manual-create guidance" >&2
  exit 1
fi

if grep -R 'IM passwords\|login password\|login form\|登录密码\|IM 地址' SKILL.md references scripts README.md README_zh.md >/dev/null; then
  echo "published docs/scripts must call the user-facing field an initialization code, not a login password" >&2
  exit 1
fi

grep -q 'eight-digit app initialization code' SKILL.md
grep -q 'S7 green is not the final product-complete state' SKILL.md
grep -q 'non-polluting' SKILL.md
grep -q 'direxio-mcp@latest' SKILL.md
grep -q 'direxio-connent@latest' SKILL.md
grep -q 'DirexioDeployer' SKILL.md
grep -q 'AdministratorAccess' SKILL.md
grep -qi 'root access keys are allowed' SKILL.md
grep -q 'Root access key (default fastest path)' SKILL.md
grep -q 'Dedicated IAM deployment user' SKILL.md
grep -q 'highly privileged, must be saved securely' SKILL.md
grep -q 'safer because it avoids root keys' SKILL.md
grep -q 'Destroy uses the same AWS identity boundary as deployment' SKILL.md
grep -q 'Destroy allows root AWS access-key identity' references/deployment-workflow.md
grep -q 'Recovery summary' SKILL.md
grep -q 'operation-report.json' SKILL.md
grep -q 'destroy.evidence' SKILL.md
grep -q 'user_confirmation_details' SKILL.md
grep -q 'confirmation evidence is redacted' SKILL.md
grep -q 'eight-or-more digit numeric strings' SKILL.md
grep -q 'eight-or-more digit numeric strings' references/deployment-workflow.md
grep -q 'credentials.status' SKILL.md
grep -q 'mcp.status' SKILL.md
grep -q 'credentials.status=refresh_pending' references/deployment-workflow.md
grep -q 'mcp.status=refresh_pending' references/deployment-workflow.md
grep -q 'stops only the matching service-scoped direxio-connect daemon' references/deployment-workflow.md
grep -q 'possible_remaining_billable_resources' SKILL.md
grep -q 'EBS root volume' SKILL.md
grep -q 'destroy.evidence' references/deployment-workflow.md
grep -q 'scripts/orchestrate.sh report new_deploy' SKILL.md
grep -q 'scripts/update.sh' SKILL.md
grep -q 'scripts/reset-app-data.sh' SKILL.md
grep -q 'clears old user-confirmation/runtime-check evidence' SKILL.md
grep -q 'connect_install_status=refresh_pending' SKILL.md
grep -q 'stops only the matching service-scoped direxio-connect daemon' SKILL.md
grep -q 'Local refresh:' SKILL.md
grep -q 'rerun the deployment workflow to refresh S4-S7' SKILL.md
grep -q 'refresh_pending' references/token-refresh.md
grep -q 'user_confirmations.*runtime_checks' references/token-refresh.md
grep -q 'stops only the matching service-scoped direxio-connect daemon' references/token-refresh.md
grep -q '重新生成本地 credentials/MCP snippets' references/token-refresh.md
grep -q '默认自动重新安装/重启 direxio-connect 和 direxio-mcp' references/token-refresh.md
grep -q 'DIREXIO_RESET_APP_DATA_CONFIRM=1' SKILL.md
grep -q 'scripts/aws-credentials.sh import-csv' SKILL.md
grep -q 'scripts/aws-credentials.sh verify' SKILL.md
grep -q 'scripts/pricing-estimate.sh' SKILL.md
grep -q 'pricing-estimate.sh --state' references/deployment-workflow.md
grep -q 'cost_estimate' SKILL.md
grep -q 'cost_estimate' references/deployment-workflow.md
grep -q 'aws freetier get-account-plan-state --output json' SKILL.md
grep -q 'aws freetier get-account-plan-state --output json' references/deployment-workflow.md
grep -q '100 USD initial credits' SKILL.md
grep -q '100 USD initial credits' references/deployment-workflow.md
grep -q 'Read https://github.com/YingSuiAI/direxio-deployer README and follow its npm install rule' README.md
grep -q '请阅读 https://github.com/YingSuiAI/direxio-deployer 的 README，并按其中 npm 安装规则安装 skill' README_zh.md
grep -q 'should run the npm install commands below' README.md
grep -q '应执行下方 npm 安装命令' README_zh.md
grep -q 'do not use a generic GitHub skill installer' SKILL.md
grep -q 'Read https://github.com/YingSuiAI/direxio-deployer README and follow its npm install rule' references/agent-targets.md
grep -q 'EC2-VPC Elastic IP quota' SKILL.md
grep -q 'EC2-VPC Elastic IP quota' references/deployment-workflow.md
grep -q 'orchestrate.sh confirm app_initialization' SKILL.md
grep -q 'orchestrate.sh confirm agent_mcp_runtime' SKILL.md
grep -q 'DIREXIO_CONFIRM_RUNTIME_PROBE=1' SKILL.md
grep -q 'runtime_checks.summary.status' SKILL.md
grep -q 'confirm` command requires `DIREXIO_CONFIRM_EVIDENCE`' SKILL.md
grep -q 'at least 12 characters' SKILL.md
grep -q 'orchestrate.sh verify connect_daemon' SKILL.md
grep -q 'orchestrate.sh verify mcp_doctor' SKILL.md
grep -q 'orchestrate.sh verify mcp_smoke' SKILL.md
grep -q 'orchestrate.sh verify mcp_tools' SKILL.md
grep -q 'orchestrate.sh verify runtime' SKILL.md
grep -q 'orchestrate.sh confirm app_initialization' references/deployment-workflow.md
grep -q 'DIREXIO_CONFIRM_RUNTIME_PROBE=1' references/deployment-workflow.md
grep -q 'All `confirm` commands require `DIREXIO_CONFIRM_EVIDENCE`' references/deployment-workflow.md
grep -q 'at least 12 characters' references/deployment-workflow.md
grep -q 'orchestrate.sh verify connect_daemon' references/deployment-workflow.md
grep -q 'orchestrate.sh verify mcp_doctor' references/deployment-workflow.md
grep -q 'orchestrate.sh verify mcp_smoke' references/deployment-workflow.md
grep -q 'orchestrate.sh verify mcp_tools' references/deployment-workflow.md
grep -q 'orchestrate.sh verify runtime' references/deployment-workflow.md
grep -q 'DIREXIO_CONFIRM_DNS_OVERWRITE=1' SKILL.md
grep -q 'DIREXIO_CONFIRM_DNS_OVERWRITE=1' references/deployment-workflow.md
grep -q 'authoritative DNS' SKILL.md
grep -q 'AWS Budget' SKILL.md
grep -q 'AWS Budget' references/deployment-workflow.md
grep -q 'AWS Billing Console' SKILL.md
grep -q 'Current MVP deployment path is EC2-only' SKILL.md
grep -q 'Lightsail requires a separate deploy_mode=lightsail implementation before it can be offered' SKILL.md
grep -q 'rotate/remove root access keys if used' SKILL.md
grep -q 'temporary IAM key' scripts/orchestrate.sh

for requirement_id in \
  DEPLOY-P0-001 \
  DEPLOY-P0-002 \
  DEPLOY-P0-003 \
  DEPLOY-P0-004 \
  DEPLOY-P0-005 \
  DEPLOY-P1-001 \
  DEPLOY-P1-002 \
  DEPLOY-P1-003 \
  DEPLOY-P1-004 \
  DEPLOY-P1-005 \
  DEPLOY-P2-001 \
  DEPLOY-P2-002 \
  DEPLOY-P2-003 \
  DEPLOY-P2-004; do
  grep -q "$requirement_id" references/deployment-optimization-audit.md
done

grep -q 'Deployer-side implemented' references/deployment-optimization-audit.md
grep -q 'Runtime evidence still required' references/deployment-optimization-audit.md
grep -q 'Current best plan' references/deployment-optimization-audit.md
grep -q '~/.direxio/nodes/<service_id>/' references/deployment-optimization-audit.md
grep -q 'verify runtime is an internal non-polluting check' references/deployment-optimization-audit.md
grep -q 'user App initialization and real chat evidence' references/deployment-optimization-audit.md
grep -q 'update/reset are now first-class scripts' references/deployment-optimization-audit.md
grep -q 'Local refresh' references/deployment-optimization-audit.md
grep -q 'clears old credentials, user confirmations, runtime checks, bridge install' references/deployment-optimization-audit.md
grep -q 'stops only the matching service-scoped direxio-connect daemon' references/deployment-optimization-audit.md
grep -q 'Lightsail remains deferred' references/deployment-optimization-audit.md

if grep -RE 'DOMAIN_MODE=lightsail|DEPLOY_MODE=lightsail|choose between EC2 and Lightsail|Lightsail automatic deployment is supported' SKILL.md README.md README_zh.md references scripts >/dev/null; then
  echo "current docs/scripts must not offer Lightsail as an implemented automatic deployment path" >&2
  exit 1
fi

echo "skill structure ok"
