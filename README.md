# Dirextalk Deployer

[简体中文](README_zh.md)

`dirextalk-deployer` deploys a production Dirextalk message server and wires the local agent room through Dirextalk's Matrix bridge. The supported local bridge is `dirextalk-connect`, installed per service from the npm package `dirextalk-connect@latest` by default or built from `YingSuiAI/dirextalk-connect`. S6 also writes service-scoped MCP snippets that connect MCP-capable supported runtimes directly to the deployed message server's HTTP MCP endpoint.

## Contents

- `SKILL.md`: Agent entrypoint, confirmation rules, deployment/destroy flow, and delivery format.
- `scripts/`: State machine, AWS Lightsail/EC2/DNS/user-data/verification/destroy scripts.
- `references/`: Tooling, deployment resume flow, dirextalk-connect wiring, state machine, architecture, troubleshooting, and recovery notes.
- `agents/`: Runtime metadata and recognition notes for agent hosts.

## Before Deployment

- Prepare an AWS account, an AWS access key CSV or profile, and a real long-lived domain or subdomain. If you do not have these yet, answer two setup questions first: do you already have an AWS account, and do you already own a domain or subdomain you can manage in DNS?
- AWS resources created by this deployer can bill until they are destroyed. New deployments prefer the Lightsail $12/month Linux bundle by default. Users who have not used Lightsail generally receive three months of free Lightsail usage. New AWS customer accounts generally receive 100-200 USD in free credits. AWS official real-time policy prevails. If no region is configured, the deployer recommends a default AWS region from the local timezone and uses it in non-interactive runs; set `AWS_DEFAULT_REGION`, `AWS_REGION`, AWS profile region, or `DIREXTALK_DEFAULT_REGION` to override. S1 checks Lightsail bundle and availability-zone availability before confirmation; for manual zone checks, use `aws lightsail get-regions --include-availability-zones --output json` because plain `get-regions` can omit zone details. If Lightsail has no usable resource in the selected region, S1 does not automatically switch to EC2; it records an EC2 estimate and waits for the operator to choose another Lightsail-capable region/zone or explicitly set `DIREXTALK_CLOUD_PROVIDER=ec2`. EC2 uses a 50 GiB gp3 root EBS volume by default.
- Use `SKILL.md` as the agent-facing runbook. It contains the detailed deployment rules, confirmation gates, runtime wiring behavior, and recovery procedures.

## Skill Installation And Updates

Install the deployer skill from npm, then place it into the current agent runtime's skill directory. The default install is global for the selected agent runtime. Use a project-local install only when you explicitly want the skill copied into a specific repository or workspace.

The GitHub repository keeps tests for maintainers and CI, but the published npm package and installed skill copy exclude `tests/` to keep user installs small.

For normal users, the GitHub repository is documentation and source code, not the skill installation path. Do not clone `YingSuiAI/dirextalk-deployer` just to install or use the skill. Clone this repository only for deployer development, local patching, or an explicitly requested project-local install.

If you want Codex to install and deploy in one instruction, do not say "install skills <GitHub URL>" or "install this GitHub repo as a skill". That can trigger GitHub skill installation, repository cloning, or a project-local copy instead of the npm-managed installer. Use a short instruction that gives the repository address for reading only and tells the agent to follow the README's npm install rule:

```text
Read https://github.com/YingSuiAI/dirextalk-deployer README and follow its npm install rule, then deploy Dirextalk with domain __DOMAIN__.
```

After reading this instruction, the agent should run the npm install commands below; it should not switch to a GitHub skill installer.

If Codex already lists `dirextalk-deployer` in its available skills, ask it to use that installed skill directly. If it does not, install or refresh it first:

POSIX shells:

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
```

Windows PowerShell:

```powershell
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
```

Update the installed skill with the same host runtime:

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill update --agent codex
```

Use the matching agent name for your runtime: `codex`, `claudecode`, `gemini`, `cursor`, `copilot`, `openclaw`, `hermes`, `opencode`, `qoder`, `reasonix`, or another target listed in `references/agent-targets.md`. Add `--scope project --project <path>` only when you intentionally want a repository-local skill install:

```bash
dirextalk-deployer skill install --agent codex --scope project --project .
```

The installer writes `.dirextalk-skill-install.json` into the target directory and refuses to overwrite unmanaged existing content unless `--force` is provided. Use `@latest` for normal installs and updates:

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill update --agent codex
```

The CLI is implemented in Node and uses native paths for the host it runs on. On Windows it writes Windows-compatible paths; on Linux, macOS, Git Bash, or WSL it writes paths for that runtime.

## Minimal Command

Before importing credentials, answer:

- **Do you already have an AWS account?** If not, register at AWS, complete email/phone verification, add a billing card, choose the Basic support plan, wait for activation, then create an AWS Budget or billing alert.
- **Do you already have a domain or subdomain you control?** If not, register a domain or choose a subdomain at your DNS provider. Use `DOMAIN_MODE=route53` only when AWS Route53 will manage DNS; otherwise use `DOMAIN_MODE=user` and create the A record when the deployer prints the fixed public IP.

Import and verify an AWS deployment profile from an AWS CSV. Root access keys
are the fastest first-deploy path but are highly privileged; save the CSV
securely and rotate or delete the key after deployment. A temporary
`DirextalkDeployer` IAM user is safer but takes more AWS console steps:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer us-east-1
export AWS_PROFILE=dirextalk-deployer
bash scripts/aws-credentials.sh verify dirextalk-deployer
```

Run from the repository root:

```bash
bash scripts/pricing-estimate.sh \
  --region us-east-1 \
  --cloud-provider lightsail \
  --domain-mode user
```

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
MESSAGE_SERVER_IMAGE=dirextalk/message-server:latest \
bash scripts/orchestrate.sh
```

`DIREXTALK_CLOUD_PROVIDER=lightsail` is optional because Lightsail is the default. To use the retained EC2 path instead, add `DIREXTALK_CLOUD_PROVIDER=ec2`. EC2 accepts `INSTANCE_TYPE=t3.small` or a larger explicit type and still uses a 50 GiB gp3 root EBS volume by default. If Lightsail is the default and S1 finds no usable Lightsail bundle or availability zone in the selected region, S1 records an EC2 cost estimate but does not automatically switch to EC2; choose another Lightsail-capable region/zone or explicitly rerun with `DIREXTALK_CLOUD_PROVIDER=ec2`. If no region is configured, non-interactive runs use the local-timezone recommendation; override it with `DIREXTALK_DEFAULT_REGION` or the standard AWS region settings. Let S1 auto-detect Lightsail availability unless you are debugging AWS directly; the safe manual command is `aws lightsail get-regions --include-availability-zones --output json`.

On Windows, use the PowerShell entrypoint so the deployer selects Git Bash for the cloud phases while writing Windows-compatible local `dirextalk-connect` paths:

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:DOMAIN_MODE = "user"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:DIREXTALK_CLOUD_PROVIDER = "lightsail"
$env:MESSAGE_SERVER_IMAGE = "dirextalk/message-server:latest"
.\scripts\orchestrate.ps1
```

Recommendation-only local bridge and MCP wiring:

```bash
DIREXTALK_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

Automatic local bridge and MCP install is the default. Set runtime selectors only when auto-detection is ambiguous:

```bash
DIREXTALK_AGENT_PLATFORM=auto \
DIREXTALK_CONNECT_AGENT=claudecode \
DIREXTALK_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

Supported install modes: `recommended` and `dirextalk-connect`.
If `DIREXTALK_AGENT_PLATFORM=auto` cannot identify a single supported runtime, set `DIREXTALK_CONNECT_AGENT` explicitly. S6 writes `mode = "yolo"` by default for generated agent options; an explicit `mode` in `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` or `DIREXTALK_CURSOR_MODE` still overrides it. On Windows, Cursor wiring uses Cursor Agent CLI at `%LOCALAPPDATA%\cursor-agent\agent.cmd`; OpenCode wiring searches `opencode` on PATH and the global `opencode-ai` npm package, or accepts `DIREXTALK_OPENCODE_COMMAND`. If `agent.cmd status` is not logged in, run `agent.cmd login` once, then rerun the deployer to refresh config and restart the daemon. For OpenClaw or Hermes defaults, force the host runtime with `DIREXTALK_AGENT_PLATFORM=openclaw` or `DIREXTALK_AGENT_PLATFORM=hermes`; setting only `DIREXTALK_CONNECT_AGENT=acp` selects generic ACP and requires manual options. OpenClaw Gateway ACP defaults to `["acp", "--session", "agent:main:main"]` and lets `openclaw acp` auto-detect the Gateway from `~/.openclaw/openclaw.json`. To force explicit Gateway settings, set all of `DIREXTALK_OPENCLAW_ACP_URL`, `DIREXTALK_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXTALK_OPENCLAW_ACP_SESSION` from the current OpenClaw runtime after pairing. Use `DIREXTALK_OPENCLAW_ACP_ARGS_TOML` only when you need to provide the complete OpenClaw ACP args array yourself. Use `DIREXTALK_HERMES_ACP_ARGS_TOML` for the child Hermes args; S6 prefixes the `hermes-acp-adapter -- <hermes-command>` wrapper automatically.

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

Destroy stops and uninstalls the local `dirextalk-connect` daemon only when its reported `WorkDir`
matches the current service's `~/.dirextalk/nodes/<service_id>/dirextalk-connect`
directory, then removes that service directory.

Update an existing node without deleting data:

```bash
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=dirextalk/message-server:latest bash scripts/update.sh
```

Image refresh restarts the remote service only. It leaves local credentials,
`dirextalk-connect`, MCP artifacts, user confirmations, and runtime checks intact.

Reset application data while preserving EC2, DNS, fixed IP, and Caddy TLS:

```bash
DIREXTALK_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
DIREXTALK_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

Application data reset clears server-side app volumes, so the follow-up
orchestrate run regenerates local credentials/MCP artifacts and automatically
reinstalls/restarts `dirextalk-connect` unless explicitly overridden with
`DIREXTALK_AGENT_INSTALL=recommend` or `skip`. MCP uses the server HTTP endpoint
and does not install a local MCP CLI.

## Local Bridge

S6 writes these service-scoped files under `~/.dirextalk/nodes/<service_id>/`:

```text
credentials.json
env
dirextalk-connect/config.toml
dirextalk-connect/data/
dirextalk-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

Manual install:

```bash
npm install --prefix ~/.dirextalk/nodes/<service_id>/dirextalk-connect dirextalk-connect@latest
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon status --service-name <service_id>
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon logs --service-name <service_id> -n 120
```

With the default `DIREXTALK_AGENT_INSTALL=auto`, S6 waits for daemon status
`Running` and a recent `dirextalk-connect is running` log before marking local
wiring done. Agent startup errors in the logs, such as a missing Cursor Agent
CLI, login/auth/trust failures, ACP startup failure, or agent offline state,
fail S6 instead of reporting deployment success.

MCP is not installed as a local CLI during S6. Generated MCP client snippets
connect directly to the deployed message server's HTTP MCP endpoint at
`https://<domain>/mcp` using the service agent token. No local MCP CLI, daemon,
proxy, or listening port is required.

S6 writes only the MCP snippet for the detected runtime: `mcp/codex.toml` for Codex, `mcp/cursor.mcp.json` for Cursor, `mcp/openclaw.md` plus `mcp/openclaw-server.json` for OpenClaw, `mcp/hermes.mcp.json` for Hermes, or `mcp/mcp-servers.json` for other MCP-capable supported runtimes. Cursor can read MCP servers from `.cursor/mcp.json` or `~/.cursor/mcp.json`, but S6 does not write those files by default because they contain a bearer token for this service; after adding the snippet, restart Cursor or reload/enable the server in Cursor MCP settings. For OpenClaw, read `mcp/openclaw.md` and run the generated `openclaw mcp set` command against `mcp/openclaw-server.json`; do not paste MCP JSON into `~/.openclaw/openclaw.json`.

Voice input is supported when an STT provider key is available. Set `DIREXTALK_SPEECH_API_KEY` or provider-specific variables such as `DIREXTALK_SPEECH_QWEN_API_KEY`; S6 will then write `[speech] enabled = true` into `dirextalk-connect/config.toml`.

Homebrew documentation should use:

```bash
brew install dirextalk-connect
```

Source builds use:

```bash
git clone https://github.com/YingSuiAI/dirextalk-connect.git
cd connect
make build AGENTS=<dirextalk-connect-agent> PLATFORMS_INCLUDE=matrix
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
