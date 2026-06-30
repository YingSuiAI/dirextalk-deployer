# Direxio Deployer

[简体中文](README_zh.md)

`direxio-deployer` deploys a production Direxio message server and wires the local agent room through Direxio's Matrix bridge. The supported local bridge is `direxio-connect`, installed from the npm package `direxio-connent@latest` by default or built from `YingSuiAI/direxio-connect`. S6 also writes service-scoped MCP snippets for MCP-capable hosts such as Codex, OpenClaw, and Hermes.

## Contents

- `SKILL.md`: Agent entrypoint, confirmation rules, deployment/destroy flow, and delivery format.
- `scripts/`: State machine, AWS/EC2/DNS/cloud-init/verification/destroy scripts.
- `references/`: Tooling, deployment resume flow, cc-connect wiring, state machine, architecture, troubleshooting, and recovery notes.
- `agents/`: Runtime metadata and recognition notes for agent hosts.

## Before Deployment

- Prepare an AWS account, an AWS access key CSV or profile, and a real long-lived domain or subdomain.
- AWS resources created by this deployer can bill until they are destroyed.
- Use `SKILL.md` as the agent-facing runbook. It contains the detailed deployment rules, confirmation gates, runtime wiring behavior, and recovery procedures.

## Skill Installation And Updates

Install the deployer skill from npm, then place it into the current agent runtime's skill directory. Project-local installs are preferred because they keep the deployment skill scoped to the workspace that uses it.

POSIX shells:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex --scope project --project .
```

Windows PowerShell:

```powershell
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex --scope project --project .
```

Update the installed skill with the same host runtime:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill update --agent codex --scope project --project .
```

Use the matching agent name for your runtime: `codex`, `claudecode`, `gemini`, `cursor`, `copilot`, `openclaw`, `hermes`, `opencode`, `qoder`, `reasonix`, or another target listed in `references/agent-targets.md`. Use `--scope global` only when you intentionally want a host-level skill install:

```bash
direxio-deployer skill install --agent codex --scope global
```

The installer writes `.direxio-skill-install.json` into the target directory and refuses to overwrite unmanaged existing content unless `--force` is provided. To pin a version, install that package version first:

```bash
npm install -g direxio-deployer@0.1.0
direxio-deployer skill update --agent codex --scope project --project .
```

The CLI is implemented in Node and uses native paths for the host it runs on. On Windows it writes Windows-compatible paths; on Linux, macOS, Git Bash, or WSL it writes paths for that runtime.

## Minimal Command

Import and verify an AWS deployment profile from an AWS CSV. A temporary
`DirexioDeployer` IAM user is recommended, but root access keys are allowed
when the operator explicitly chooses them:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer us-east-1
export AWS_PROFILE=direxio-deployer
bash scripts/aws-credentials.sh verify direxio-deployer
```

Run from the repository root:

```bash
bash scripts/pricing-estimate.sh \
  --region us-east-1 \
  --instance-type t3.small \
  --disk-gb 8 \
  --domain-mode user
```

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

On Windows, use the PowerShell entrypoint so the deployer selects Git Bash for the cloud phases while writing Windows-compatible local `direxio-connect` paths:

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:DOMAIN_MODE = "user"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:INSTANCE_TYPE = "t3.small"
$env:MESSAGE_SERVER_IMAGE = "direxio/message-server:latest"
.\scripts\orchestrate.ps1
```

Recommendation-only local bridge wiring:

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

Automatic local bridge install:

```bash
DIREXIO_AGENT_INSTALL=auto \
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_CC_CONNECT_AGENT=claudecode \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

Supported install modes: `recommended` and `cc-connect`.
If `DIREXIO_AGENT_PLATFORM=auto` cannot identify a single supported runtime, set `DIREXIO_CC_CONNECT_AGENT` explicitly. For OpenClaw or Hermes defaults, force the host runtime with `DIREXIO_AGENT_PLATFORM=openclaw` or `DIREXIO_AGENT_PLATFORM=hermes`; setting only `DIREXIO_CC_CONNECT_AGENT=acp` selects generic ACP and requires manual options. For OpenClaw Gateway ACP, set `DIREXIO_OPENCLAW_ACP_URL`, `DIREXIO_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXIO_OPENCLAW_ACP_SESSION` from the current OpenClaw runtime after pairing. Use `DIREXIO_OPENCLAW_ACP_ARGS_TOML` only when you need to provide the complete OpenClaw ACP args array yourself. Use `DIREXIO_HERMES_ACP_ARGS_TOML` for the child Hermes args; S6 prefixes the `hermes-acp-adapter -- <hermes-command>` wrapper automatically.

Check status:

```bash
bash scripts/orchestrate.sh status
DOMAIN=<domain> bash scripts/orchestrate.sh status
```

Destroy recorded resources:

```bash
DOMAIN=<domain> bash scripts/destroy.sh
```

On Windows, use the PowerShell destroy entrypoint:

```powershell
$env:DOMAIN = "<domain>"
.\scripts\destroy.ps1
```

Destroy stops and uninstalls the local `direxio-connect` daemon only when its reported `WorkDir`
matches the current service's `~/.direxio/nodes/<service_id>/cc-connect`
directory, then removes that service directory.

Update an existing node without deleting data:

```bash
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=direxio/message-server:latest bash scripts/update.sh
P2P_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

Reset application data while preserving EC2, DNS, fixed IP, and Caddy TLS:

```bash
DIREXIO_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
P2P_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

## Local Bridge

S6 writes these service-scoped files under `~/.direxio/nodes/<service_id>/`:

```text
credentials.json
env
cc-connect/config.toml
cc-connect/data/
cc-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

Manual install:

```bash
npm install -g direxio-connent@latest
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --service-name <service_id> --force
direxio-connect daemon status --service-name <service_id>
```

MCP install and check:

```bash
npm install -g direxio-mcp@latest
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json direxio-mcp doctor --json
```

Use `mcp/codex.toml` for Codex and `mcp/hermes.mcp.json` for Hermes. For OpenClaw, read `mcp/openclaw.md` and run the generated `openclaw mcp set` command against `mcp/openclaw-server.json`; do not paste MCP JSON into `~/.openclaw/openclaw.json`.

Voice input is supported when an STT provider key is available. Set `DIREXIO_SPEECH_API_KEY` or provider-specific variables such as `DIREXIO_SPEECH_QWEN_API_KEY`; S6 will then write `[speech] enabled = true` into `cc-connect/config.toml`.

Homebrew documentation should use:

```bash
brew install direxio-connect
```

Source builds use:

```bash
git clone https://github.com/YingSuiAI/direxio-connect.git
cd connect
make build AGENTS=<cc-connect-agent> PLATFORMS_INCLUDE=matrix
```

## Validation

```bash
bash tests/skill_structure_test.sh
bash tests/default_paths_test.sh
bash tests/s6_wire_local_test.sh
bash tests/destroy_local_bridge_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```
