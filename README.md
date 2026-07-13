# Dirextalk Deployer

[简体中文](README_zh.md)

`dirextalk-deployer` deploys a production Dirextalk message server and wires the local agent room through Dirextalk's Matrix bridge. The supported local bridge is `dirextalk-connect`, installed per service from the npm package `dirextalk-connect@latest` by default or built from `YingSuiAI/dirextalk-connect`. MCP capability is declared separately from bridge-agent support; S6 writes the canonical remote HTTP MCP description and never assumes that every bridge agent can consume it.

## Contents

- `SKILL.md`: Agent entrypoint, confirmation rules, deployment/destroy flow, and delivery format.
- `scripts/`: State machine, AWS Lightsail/EC2/DNS/user-data/verification/destroy scripts.
- `references/`: Tooling, deployment resume flow, dirextalk-connect wiring, state machine, architecture, troubleshooting, and recovery notes.
- `agents/`: Runtime metadata and recognition notes for agent hosts.

## Before Deployment

- Prepare an AWS account, an AWS access key CSV or profile, and a real long-lived domain or subdomain. The deployer automatically uses Route53 when the current AWS account has a matching public hosted zone; otherwise it asks for an external A record only after allocating the fixed public IP.
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
- **Do you already have a domain or subdomain you control?** If not, register or prepare one first. Do not ask where its DNS is managed: the deployer checks the current AWS account for a matching public Route53 hosted zone. When none exists, it continues with external DNS and prints the required A record after the fixed public IP is allocated.

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
  --domain-mode route53
```

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
CONFIRM_DOMAIN_BINDING=1 \
bash scripts/orchestrate.sh
```

Normal deployment resolves the latest published stable GitHub Release, verifies
its manifest checksum, and records an immutable version, image digest, image
reference, and manifest digest in `state.json`. The host updater is a separate
[`dirextalk-updater`](https://github.com/YingSuiAI/dirextalk-updater) Release:
the supported Ubuntu 22.04 or 24.04 x86_64 host downloads the deployer-pinned updater asset and
verifies the deployer-pinned SHA-256 before atomic installation. The local
machine does not need Go, and S3 never copies an updater binary over SSH.
The deployer-side Node selector validates every `upgrade_from` entry with the
pinned mature `semver` package and rejects constraints that include the target.
Its accepted/rejected corpus covers the constraint forms used by the canonical
Go validators; the independent updater and message-server Release CI remain
authoritative for cross-version compatibility evidence.

One pre-updater node can be adopted only through the explicit, fixed d1
contract. Run `scripts/adopt-legacy-node.sh --dry-run <state.json>` with
`DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server`
and `DIREXTALK_LEGACY_ADOPT_SSH_USER=root`. After reviewing the read-only
v0.15.2 image/digest, health, Compose, and host-Caddy evidence, set the exact
confirmation printed by the command and rerun without `--dry-run`. It never
pulls or starts a different image: it creates the updater-owned immutable
Compose view, copies live P2P state, installs the pinned updater, and adds only
the public updater jobs route to validated host Caddy. Other legacy topologies
and existing formal release state are rejected.

`DIREXTALK_CLOUD_PROVIDER=lightsail` is optional because Lightsail is the default. To use the retained EC2 path instead, add `DIREXTALK_CLOUD_PROVIDER=ec2`. EC2 accepts `INSTANCE_TYPE=t3.small` or a larger explicit type and still uses a 50 GiB gp3 root EBS volume by default. If Lightsail is the default and S1 finds no usable Lightsail bundle or availability zone in the selected region, S1 records an EC2 cost estimate but does not automatically switch to EC2; choose another Lightsail-capable region/zone or explicitly rerun with `DIREXTALK_CLOUD_PROVIDER=ec2`. If no region is configured, non-interactive runs use the local-timezone recommendation; override it with `DIREXTALK_DEFAULT_REGION` or the standard AWS region settings. Let S1 auto-detect Lightsail availability unless you are debugging AWS directly; the safe manual command is `aws lightsail get-regions --include-availability-zones --output json`.

On Windows, use the PowerShell entrypoint so the deployer selects Git Bash for the cloud phases while writing Windows-compatible local `dirextalk-connect` paths:

The wrapper accepts Git for Windows or MSYS2 Bash from `PATH`; for a custom installation, set `DIREXTALK_BASH_COMMAND` to the working Bash executable. It does not silently select the Windows WSL alias.

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:DIREXTALK_CLOUD_PROVIDER = "lightsail"
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
If `DIREXTALK_AGENT_PLATFORM=auto` cannot identify a single supported runtime, set `DIREXTALK_CONNECT_AGENT` explicitly. S6 writes `mode = "yolo"` by default for generated agent options; an explicit `mode` in `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` or `DIREXTALK_CURSOR_MODE` still overrides it. On Windows, Cursor wiring uses Cursor Agent CLI at `%LOCALAPPDATA%\cursor-agent\agent.cmd`; OpenCode wiring searches `opencode` on PATH and the global `opencode-ai` npm package, or accepts `DIREXTALK_OPENCODE_COMMAND`. If `agent.cmd status` is not logged in, run `agent.cmd login` once, then rerun the deployer. An active OpenClaw or Hermes host owns MCP even when it launches Codex or another child; only explicit `DIREXTALK_AGENT_PLATFORM=<child>` bypasses host auto-detection. OpenClaw Gateway ACP defaults to `["acp", "--session", "agent:main:main"]` and auto-detects its Gateway. Explicit settings require all of `DIREXTALK_OPENCLAW_ACP_URL`, `DIREXTALK_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXTALK_OPENCLAW_ACP_SESSION`. Fully replaceable OpenClaw args and generic host command overrides are rejected. `DIREXTALK_HERMES_ACP_ARGS_TOML` may add child Hermes args while S6 preserves the required adapter/profile prefix.

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
DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=dirextalk/message-server:<debug-tag> bash scripts/update.sh
```

This is an explicit debug/legacy override, not the normal production upgrade
path. Image refresh restarts the remote service only. It leaves local credentials,
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
dirextalk-connect/config.toml
dirextalk-connect/data/
dirextalk-connect/matrix-session.json
mcp/README.md
mcp/openclaw.md
mcp/hermes.md
```

POSIX Bash manual install:

```bash
npm install --prefix ~/.dirextalk/nodes/<service_id>/dirextalk-connect dirextalk-connect@latest
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon status --service-name <service_id>
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon logs --service-name <service_id> -n 120
```

Windows PowerShell manual install:

```powershell
$serviceDir = Join-Path $env:USERPROFILE '.dirextalk\nodes\<service_id>'
$runtimeDir = Join-Path $serviceDir 'dirextalk-connect'
$connect = Join-Path $runtimeDir 'dirextalk-connect.cmd'
npm install --prefix $runtimeDir dirextalk-connect@latest
& $connect daemon install --config (Join-Path $runtimeDir 'config.toml') --service-name '<service_id>' --force
& $connect daemon status --service-name '<service_id>'
& $connect daemon logs --service-name '<service_id>' -n 120
```

With the default `DIREXTALK_AGENT_INSTALL=auto`, S6 waits for daemon status
`Running` and a recent `dirextalk-connect is running` log before marking local
wiring done. Agent startup errors in the logs, such as a missing Cursor Agent
CLI, login/auth/trust failures, ACP startup failure, or agent offline state,
fail S6 instead of reporting deployment success.

MCP is not installed as a local CLI during S6. The canonical config connects to
`https://<domain>/mcp` using the service agent token. No local MCP CLI, daemon,
proxy, or listening port is required. S6 records one of `session`, `project`,
`host-managed`, `conditional`, or `unsupported`; an undeclared runtime fails closed.

The capability registry matches dirextalk-connect and follows the effective
connect agent, while the detected host runtime selects reviewable artifacts.
ACP, Claude Code, Codex, Copilot, Gemini, Kimi, OpenCode, and Qoder are
`session`; Antigravity, Cursor, and iFlow are `host-managed`; Devin, Pi,
Reasonix, and tmux are `unsupported`. Detected OpenClaw and Hermes hosts are
always `host-managed` and require the ACP bridge; a non-ACP connect override is
rejected. Their native registries own MCP while connect bridges conversation.
Unsupported and unknown selections fail closed. The vocabulary retains `project` and `conditional`, but
no current backend uses them. S6 never generates a generic JSON fallback.

Host-managed selection retains its guidance artifact but omits the canonical
MCP URL/token fields from `dirextalk-connect/config.toml`. In `auto` mode, S6
waits before starting the bridge until the operator enrolls the host and reruns
with `DIREXTALK_MCP_HOST_READY=1`. OpenClaw must then pass the secret-free
`openclaw mcp probe <server-name> --json` check before the bridge starts;
`OPENCLAW_CONFIG_PATH` and optional `DIREXTALK_OPENCLAW_PROFILE` select an
isolated native registry/profile. Other host-managed backends without an
official probe remain operator-confirmed and require later runtime verification.
Hermes uses a service-scoped HERMES_HOME/profile, writes `mcp/hermes.md` instead
of JSON, and must pass `hermes -p <profile> mcp test <server-name>` in that same
scope before bridge startup.
S6 never runs `mcp set`, mutates global host config, generates a bearer-token
server JSON, or places the token in process arguments.

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
