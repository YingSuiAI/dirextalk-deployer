# Direxio Deployer

[简体中文](README_zh.md)

`direxio-deployer` deploys a production Direxio message server and wires the local agent room through Direxio's Matrix bridge. The supported local bridge is `direxio-connect`, installed per service from the npm package `direxio-connent@latest` by default or built from `YingSuiAI/direxio-connect`. S6 also writes service-scoped MCP snippets for MCP-capable supported runtimes.

## Contents

- `SKILL.md`: Agent entrypoint, confirmation rules, deployment/destroy flow, and delivery format.
- `scripts/`: State machine, AWS Lightsail/EC2/DNS/user-data/verification/destroy scripts.
- `references/`: Tooling, deployment resume flow, direxio-connect wiring, state machine, architecture, troubleshooting, and recovery notes.
- `agents/`: Runtime metadata and recognition notes for agent hosts.

## Before Deployment

- Prepare an AWS account, an AWS access key CSV or profile, and a real long-lived domain or subdomain.
- AWS resources created by this deployer can bill until they are destroyed. New deployments prefer the Lightsail $12/month Linux bundle by default. Users who have not used Lightsail generally receive three months of free Lightsail usage. New AWS customer accounts generally receive 100-200 USD in free credits. AWS official real-time policy prevails. S1 checks Lightsail bundle and availability-zone availability before confirmation; for manual zone checks, use `aws lightsail get-regions --include-availability-zones --output json` because plain `get-regions` can omit zone details. If Lightsail has no usable resource in the selected region, the recommendation switches to EC2. EC2 remains available with `DIREXIO_CLOUD_PROVIDER=ec2` and uses a 50 GiB gp3 root EBS volume by default.
- Use `SKILL.md` as the agent-facing runbook. It contains the detailed deployment rules, confirmation gates, runtime wiring behavior, and recovery procedures.

## Skill Installation And Updates

Install the deployer skill from npm, then place it into the current agent runtime's skill directory. The default install is global for the selected agent runtime. Use a project-local install only when you explicitly want the skill copied into a specific repository or workspace.

The GitHub repository keeps tests for maintainers and CI, but the published npm package and installed skill copy exclude `tests/` to keep user installs small.

If you want Codex to install and deploy in one instruction, do not say "install skills <GitHub URL>". That triggers GitHub skill installation instead of the npm-managed installer. Use a short instruction that gives the repository address for reading only and tells the agent to follow the README's npm install rule:

```text
Read https://github.com/YingSuiAI/direxio-deployer README and follow its npm install rule, then deploy Direxio with domain __DOMAIN__.
```

After reading this instruction, the agent should run the npm install commands below; it should not switch to a GitHub skill installer.

POSIX shells:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex
```

Windows PowerShell:

```powershell
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex
```

Update the installed skill with the same host runtime:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill update --agent codex
```

Use the matching agent name for your runtime: `codex`, `claudecode`, `gemini`, `cursor`, `copilot`, `openclaw`, `hermes`, `opencode`, `qoder`, `reasonix`, or another target listed in `references/agent-targets.md`. Add `--scope project --project <path>` only when you intentionally want a repository-local skill install:

```bash
direxio-deployer skill install --agent codex --scope project --project .
```

The installer writes `.direxio-skill-install.json` into the target directory and refuses to overwrite unmanaged existing content unless `--force` is provided. Use `@latest` for normal installs and updates:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill update --agent codex
```

The CLI is implemented in Node and uses native paths for the host it runs on. On Windows it writes Windows-compatible paths; on Linux, macOS, Git Bash, or WSL it writes paths for that runtime.

## Minimal Command

Import and verify an AWS deployment profile from an AWS CSV. Root access keys
are the fastest first-deploy path but are highly privileged; save the CSV
securely and rotate or delete the key after deployment. A temporary
`DirexioDeployer` IAM user is safer but takes more AWS console steps:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer us-east-1
export AWS_PROFILE=direxio-deployer
bash scripts/aws-credentials.sh verify direxio-deployer
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
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

`DIREXIO_CLOUD_PROVIDER=lightsail` is optional because Lightsail is the default. To use the retained EC2 path instead, add `DIREXIO_CLOUD_PROVIDER=ec2`. EC2 accepts `INSTANCE_TYPE=t3.small` or a larger explicit type and still uses a 50 GiB gp3 root EBS volume by default. If Lightsail is the default and S1 finds no usable Lightsail bundle or availability zone in the selected region, S1 records EC2 as the selected provider before provisioning. Let S1 auto-detect Lightsail availability unless you are debugging AWS directly; the safe manual command is `aws lightsail get-regions --include-availability-zones --output json`.

On Windows, use the PowerShell entrypoint so the deployer selects Git Bash for the cloud phases while writing Windows-compatible local `direxio-connect` paths:

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:DOMAIN_MODE = "user"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:DIREXIO_CLOUD_PROVIDER = "lightsail"
$env:MESSAGE_SERVER_IMAGE = "direxio/message-server:latest"
.\scripts\orchestrate.ps1
```

Recommendation-only local bridge and MCP wiring:

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

Automatic local bridge and MCP install is the default. Set runtime selectors only when auto-detection is ambiguous:

```bash
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_CONNECT_AGENT=claudecode \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

Supported install modes: `recommended` and `direxio-connect`.
If `DIREXIO_AGENT_PLATFORM=auto` cannot identify a single supported runtime, set `DIREXIO_CONNECT_AGENT` explicitly. S6 writes `mode = "yolo"` by default for generated agent options; an explicit `mode` in `DIREXIO_CONNECT_AGENT_OPTIONS_TOML` or `DIREXIO_CURSOR_MODE` still overrides it. On Windows, Cursor wiring uses Cursor Agent CLI at `%LOCALAPPDATA%\cursor-agent\agent.cmd`. If `agent.cmd status` is not logged in, run `agent.cmd login` once, then rerun the deployer to refresh config and restart the daemon. For OpenClaw or Hermes defaults, force the host runtime with `DIREXIO_AGENT_PLATFORM=openclaw` or `DIREXIO_AGENT_PLATFORM=hermes`; setting only `DIREXIO_CONNECT_AGENT=acp` selects generic ACP and requires manual options. OpenClaw Gateway ACP defaults to `["acp", "--session", "agent:main:main"]` and lets `openclaw acp` auto-detect the Gateway from `~/.openclaw/openclaw.json`. To force explicit Gateway settings, set all of `DIREXIO_OPENCLAW_ACP_URL`, `DIREXIO_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXIO_OPENCLAW_ACP_SESSION` from the current OpenClaw runtime after pairing. Use `DIREXIO_OPENCLAW_ACP_ARGS_TOML` only when you need to provide the complete OpenClaw ACP args array yourself. Use `DIREXIO_HERMES_ACP_ARGS_TOML` for the child Hermes args; S6 prefixes the `hermes-acp-adapter -- <hermes-command>` wrapper automatically.

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
matches the current service's `~/.direxio/nodes/<service_id>/direxio-connect`
directory, then removes that service directory.

Update an existing node without deleting data:

```bash
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=direxio/message-server:latest bash scripts/update.sh
```

Image refresh restarts the remote service only. It leaves local credentials,
`direxio-connect`, MCP artifacts, user confirmations, and runtime checks intact.

Reset application data while preserving EC2, DNS, fixed IP, and Caddy TLS:

```bash
DIREXIO_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
DIREXIO_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

Application data reset clears server-side app volumes, so the follow-up
orchestrate run regenerates local credentials/MCP artifacts and automatically
reinstalls/restarts `direxio-connect` plus `direxio-mcp` unless explicitly
overridden with `DIREXIO_AGENT_INSTALL=recommend` or `skip`.

## Local Bridge

S6 writes these service-scoped files under `~/.direxio/nodes/<service_id>/`:

```text
credentials.json
env
direxio-connect/config.toml
direxio-connect/data/
direxio-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

Manual install:

```bash
npm install --prefix ~/.direxio/nodes/<service_id>/direxio-connect direxio-connent@latest
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/direxio-connect/config.toml --service-name <service_id> --force
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon status --service-name <service_id>
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon logs --service-name <service_id> -n 120
```

With the default `DIREXIO_AGENT_INSTALL=auto`, S6 waits for daemon status
`Running` and a recent `direxio-connect is running` log before marking local
wiring done. Agent startup errors in the logs, such as a missing Cursor Agent
CLI, login/auth/trust failures, ACP startup failure, or agent offline state,
fail S6 instead of reporting deployment success.

MCP is installed into the current service directory during S6 when
`DIREXIO_AGENT_INSTALL=auto`. Generated MCP client snippets launch that
service-scoped `direxio-mcp` binary directly over stdio. S6 also attempts to
install a service-scoped `direxio-mcp` daemon as an optional HTTP proxy
endpoint; if Windows denies scheduled-task creation, the stdio snippets remain
usable.
Manual recovery command:

```bash
npm install --prefix ~/.direxio/nodes/<service_id>/mcp direxio-mcp@latest
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json ~/.direxio/nodes/<service_id>/mcp/direxio-mcp doctor --json
~/.direxio/nodes/<service_id>/mcp/direxio-mcp daemon install --service-name <service_id> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --host 127.0.0.1 --port 19757
~/.direxio/nodes/<service_id>/mcp/direxio-mcp daemon status --service-name <service_id> --json
```

S6 writes only the MCP snippet for the detected runtime: `mcp/codex.toml` for Codex, `mcp/cursor.mcp.json` for Cursor, `mcp/openclaw.md` plus `mcp/openclaw-server.json` for OpenClaw, `mcp/hermes.mcp.json` for Hermes, or `mcp/mcp-servers.json` for other MCP-capable supported runtimes. Generated MCP client snippets run the service-scoped `direxio-mcp` over stdio with `DIREXIO_CREDENTIALS_FILE` set to the service credentials, so clients can start the MCP tool process without a daemon. Cursor can read MCP servers from `.cursor/mcp.json` or `~/.cursor/mcp.json`, but S6 does not write those files by default because they contain machine-local credential paths; after adding the snippet, restart Cursor or reload/enable the server in Cursor MCP settings. For OpenClaw, read `mcp/openclaw.md` and run the generated `openclaw mcp set` command against `mcp/openclaw-server.json`; do not paste MCP JSON into `~/.openclaw/openclaw.json`.

Voice input is supported when an STT provider key is available. Set `DIREXIO_SPEECH_API_KEY` or provider-specific variables such as `DIREXIO_SPEECH_QWEN_API_KEY`; S6 will then write `[speech] enabled = true` into `direxio-connect/config.toml`.

Homebrew documentation should use:

```bash
brew install direxio-connect
```

Source builds use:

```bash
git clone https://github.com/YingSuiAI/direxio-connect.git
cd connect
make build AGENTS=<direxio-connect-agent> PLATFORMS_INCLUDE=matrix
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
