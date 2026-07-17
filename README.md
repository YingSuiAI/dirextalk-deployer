# Dirextalk Deployer

Deploy a private Dirextalk message server on your own AWS account, then wire a
local coding agent into the server's agent room.

`dirextalk-deployer` is both:

- an agent skill, installed from npm into Codex, Claude Code, Cursor, Gemini,
  OpenClaw, Hermes, and other supported local agent runtimes;
- a portable deployment engine, implemented as resumable Bash state-machine
  scripts for AWS, DNS, TLS, server bootstrap, local bridge wiring, MCP
  registration, verification, and destroy.

The repository is open source so operators and agent hosts can audit exactly
what happens before any cloud resource is created.

Visit [dirextalk.ai](https://dirextalk.ai/) for the product website.

## What It Deploys

The default deployment creates one self-owned Dirextalk node:

```text
your domain
  -> AWS Lightsail or EC2 fixed public IP
  -> Caddy TLS endpoint
  -> Dirextalk message-server
  -> PostgreSQL
  -> coturn
```

After the server is healthy, the deployer can also write local, service-scoped
artifacts under `~/.dirextalk/nodes/<service_id>/`:

```text
credentials.json
dirextalk-connect/config.toml
dirextalk-connect/matrix-session.json
mcp/README.md
mcp/openclaw.md
mcp/hermes.md
```

`dirextalk-connect` bridges the real Dirextalk `agent_room_id` to the selected
local agent runtime. MCP-capable runtimes use the deployed server's HTTP MCP
endpoint, `https://<domain>/mcp`; the deployer does not install a local MCP
daemon, proxy, or listening port.

## Communication Architecture

This deployer provisions the user-owned Personal Node in the Dirextalk
communication architecture. It does not deploy the central Dirextalk Platform
service or the mobile app.

The architecture keeps private communication inside user-owned service nodes:

- Each personal network has one owner and one private service node. The node
  runs the Dirextalk server surface for Matrix messaging, Portal APIs, MCP,
  TURN, and the Native Agent runtime.
- The Dirextalk app connects to its owner's node over HTTPS, Matrix sync, and
  WebSocket paths for chat, channels, and account-local state.
- Local coding agents connect through `dirextalk-connect` and the deployed HTTP
  MCP endpoint. The bridge is local to the operator's machine; it is not a
  central Dirextalk-hosted agent service.
- Cross-user messages are federated directly between personal nodes over HTTPS.
  Each node keeps its own domain identity and stores its own private message
  state.
- Voice and video use a direct WebRTC media path when possible. If direct media
  is not possible, TURN fallback goes through the relevant personal nodes.
- The Dirextalk Platform handles activation, app distribution, public channel
  discovery metadata, and opt-in promotion only. It is not the place where
  private messages are stored or user profiles are built.

## Choose The Right Entry Point

| Use case | Recommended path |
| --- | --- |
| I want a browser deployment flow only. | Use the [web deployment console](https://deployer.dirextalk.ai/). It deploys and destroys cloud backend resources, but does not wire a local agent. |
| I want Codex or another agent to deploy and wire my local agent room. | Install this npm skill with `dirextalk-deployer skill install --agent <runtime>`. |
| I maintain or audit the deployer itself. | Clone this repository, run the tests, and work against the scripts directly. |

The web deployment console provisions, resumes, verifies, and destroys backend
resources, but does **not** install or configure `dirextalk-connect` or link any agent on your local machine.

For normal users, GitHub is documentation and source code. Do not clone this
repository just to install the skill.

## Safety Model

Read this before running a deployment:

- You need an AWS account, AWS credentials, and a real long-lived domain or
  subdomain.
- Cloud resources can bill until destroyed. New deployments prefer the Lightsail
  $12/month Linux bundle by default plus any DNS/domain/data-transfer costs.
  Current AWS public pages describe
  [three months of free Lightsail usage](https://aws.amazon.com/free/compute/lightsail/)
  for eligible Lightsail trials and
  [100-200 USD in credits](https://aws.amazon.com/free/) for new AWS customers;
  AWS official real-time policy prevails. Check the AWS Billing Console before
  relying on credits or trials.
- The domain becomes the Matrix `server_name`. Changing it later is effectively
  creating a new homeserver identity.
- The deployer stores generated secrets outside the repository, normally under
  `~/.dirextalk/nodes/<service_id>/`, with restrictive permissions when the
  host supports them.
- Do not paste AWS secrets, Matrix access tokens, `agent_token`, the app
  initialization code, SSH private keys, or generated credential files into
  chat, issues, pull requests, or logs.
- Use one host environment for one service directory. Do not switch the same
  service directory between native Windows Git Bash and WSL.

## Supported Hosts

Lifecycle commands are Bash commands on every platform.

- Linux, macOS, and native WSL: run Bash directly.
- Native Windows: install Git for Windows and run lifecycle commands from Git
  Bash. PowerShell wrappers are not part of the supported lifecycle path.

Native Windows Git Bash preflight:

```bash
case "$(uname -s)" in
  MINGW*)
    git_root=$(git --exec-path 2>/dev/null | sed 's#/mingw64/libexec/git-core$##')
    command -v git >/dev/null &&
      command -v cygpath >/dev/null &&
      git --version | grep -q '\.windows\.' &&
      [ -n "$git_root" ] &&
      [ "$(cygpath -m "${EXEPATH:-}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s/bin' "$git_root" | tr '[:upper:]' '[:lower:]')" ]
    ;;
  Linux*|Darwin*) true ;;
  *) false ;;
esac
```

If that command fails on Windows, install Git for Windows from
<https://git-scm.com/download/win>, reopen Git Bash, and retry.

## Install The Agent Skill

Install the npm package globally, then copy the skill into the target agent's
skill directory:

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
```

Use the runtime that matches your agent host:

```text
acp antigravity claudecode codex copilot cursor devin gemini hermes iflow kimi opencode openclaw pi qoder reasonix tmux
```

Common aliases such as `claude`, `claude-code`, `open-code`, `qodercli`, and
`agy` are accepted by the installer.

Refresh an existing install:

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill refresh --agent codex
```

Project-local installs are for development and audits only:

```bash
dirextalk-deployer skill install --agent codex --scope project --project .
```

If you want to ask Codex to install and deploy in one instruction, use this
shape:

```text
Read https://github.com/YingSuiAI/dirextalk-deployer README and follow its npm install rule, then deploy Dirextalk with domain __DOMAIN__.
```

Do not ask an agent to "install this GitHub repo as a skill"; that can trigger a
repository clone or project-local copy instead of the npm-managed installer.
After reading this instruction, the agent should run the npm install commands below and should not switch to a GitHub skill installer.

## Prepare AWS Credentials

Import an AWS access-key CSV into a named profile:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer us-east-1
export AWS_PROFILE=dirextalk-deployer
bash scripts/aws-credentials.sh verify dirextalk-deployer
```

Root access keys are allowed for a first deployment when the operator chooses
that path, but they are highly privileged. Store the CSV securely and rotate or
delete the key after deployment. A temporary IAM user such as
`DirextalkDeployer` is safer but requires more AWS console setup.

## Estimate Cost

Run the estimator before creating resources:

```bash
bash scripts/pricing-estimate.sh \
  --region us-east-1 \
  --cloud-provider lightsail \
  --domain-mode route53
```

Lightsail is the default cloud provider. Explicit EC2 deployments remain
available with `DIREXTALK_CLOUD_PROVIDER=ec2`; EC2 uses a 50 GiB gp3 root volume
by default and checks the required VPC, AMI, vCPU, and Elastic IP conditions.
If Lightsail has no usable bundle or availability zone in the selected region,
S1 records an EC2 estimate but does not automatically switch to EC2; choose
another Lightsail-capable region/zone or rerun with
`DIREXTALK_CLOUD_PROVIDER=ec2`.
For manual Lightsail region checks, use
`aws lightsail get-regions --include-availability-zones --output json`.

## Deploy Or Resume

Run from a cloned repository when maintaining or auditing the deployer:

```bash
export AWS_PROFILE=dirextalk-deployer
export AWS_DEFAULT_REGION=us-east-1
export DOMAIN=__DOMAIN__
export CONFIRM_DOMAIN_BINDING=1
bash scripts/orchestrate.sh
```

The state machine is resumable. If it stops for DNS propagation, AWS quota,
local runtime setup, or another explicit action, fix that blocker and run the
same command again.

If no AWS region is configured, the deployer recommends one from local timezone
signals and records that recommendation. Override it with `AWS_DEFAULT_REGION`,
`AWS_REGION`, AWS profile configuration, or `DIREXTALK_DEFAULT_REGION`.

### DNS Behavior

The deployer requires a real long-lived domain.

- If the AWS account has a matching public Route53 hosted zone, the deployer
  automatically uses Route53 to create or update the A record.
- If no matching hosted zone exists, the deployer allocates the fixed public IP
  and waits for the operator to create an external DNS A record.
- Existing Route53 A records are protected by explicit confirmation.
- Temporary IP, localhost, wildcard, and disposable resolver domains are not
  accepted for production deployment.

## Inspect Status

List local service states:

```bash
bash scripts/orchestrate.sh status
```

Inspect one service:

```bash
DOMAIN=<domain> bash scripts/orchestrate.sh status
```

Status output explains the current phase, likely billing impact, resume safety,
next action, and stop-loss destroy command.

## Destroy Resources

Destroy the cloud resources recorded in the service state:

```bash
DOMAIN=<domain> bash scripts/destroy.sh
```

Destroy attempts to remove deployer-created compute resources, fixed IP
resources, security groups, key pairs, matching Route53 A records, local service
files, and the scoped `dirextalk-connect` daemon when its `WorkDir` matches the
current service. Domain registrations, third-party DNS records, and
user-created hosted zones remain outside automatic destroy.

## Update Or Reset A Node

Normal production upgrades are handled by the remote host updater installed
during provisioning. The updater is an independently released
[`dirextalk-updater`](https://github.com/YingSuiAI/dirextalk-updater) binary
downloaded on the cloud host from the deployer-pinned release, commit, and
SHA-256.

Debug or legacy image override:

```bash
DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=dirextalk/message-server:<debug-tag> bash scripts/update.sh
```

Reset application data while keeping cloud infrastructure, DNS, fixed IP, and
Caddy TLS storage:

```bash
DIREXTALK_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
DIREXTALK_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

Reset clears server-side application data, old user confirmations, runtime
checks, and local credential proofs. Rerun the state machine afterward to refresh
S4-S7 and local wiring.

## Adopt One Legacy Node

Pre-updater d1 adoption is intentionally separate from normal resume:

```bash
DIREXTALK_LEGACY_ADOPT_SOURCE_DIR=/root/dirextalk/dirextalk-message-server \
DIREXTALK_LEGACY_ADOPT_SSH_USER=root \
bash scripts/adopt-legacy-node.sh --dry-run <state.json>
```

Only rerun without `--dry-run` after reviewing the fixed v0.15.2 image/digest,
health, Compose, and host-Caddy evidence, then setting the exact confirmation
printed by the dry run. The adoption path does not pull or start a different
message-server image.

## Local Bridge And MCP

S6 wires the local agent only after server bootstrap credentials are available.
It requires:

- a real `agent_room_id`, not a legacy `!agent:<domain>` pseudo id;
- a Matrix session for `@agent:<server>`, created with `agent_token`;
- a `dirextalk-connect` daemon that reports `Running` and has a recent
  `dirextalk-connect is running` log marker when `DIREXTALK_AGENT_INSTALL=auto`.

Recommendation-only local wiring:

```bash
DIREXTALK_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

Skip install and write only credentials/config artifacts:

```bash
DIREXTALK_AGENT_INSTALL=skip bash scripts/orchestrate.sh
```

Set an explicit bridge agent when auto-detection is ambiguous:

```bash
DIREXTALK_CONNECT_AGENT=claudecode bash scripts/orchestrate.sh
```

Valid bridge-agent values are:

```text
acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux
```

MCP capability is declared separately from bridge support:

- ACP, Claude Code, Codex, Copilot, Gemini, Kimi, OpenCode, and Qoder are
  session MCP consumers.
- OpenClaw and Hermes are host-managed MCP consumers with native registration
  and probe requirements.
- Antigravity, Cursor, and iFlow are host-managed but may require explicit
  operator confirmation when no safe native adapter exists.
- Devin, Pi, Reasonix, tmux, unsupported, and unknown selections fail closed for
  MCP instead of receiving a generic JSON fallback.

## Repository Layout

```text
SKILL.md          Agent-facing runbook and confirmation rules
agents/           Runtime metadata for agent hosts
bin/              npm CLI for skill install/update/refresh
references/       Detailed runbooks and architecture notes
scripts/          Deployment, destroy, update, reset, JSON, AWS, DNS, and S6 logic
tests/            Portable focused test suite selected by scripts/run-tests.mjs
```

## Validation

For ordinary development, run the affected test selector:

```bash
npm test
git diff --check
```

Pre-publish gate:

```bash
npm run test:release
```

Broader manual lanes:

```bash
npm run test:quick
npm run test:stage
npm run test:full
```

`npm test` selects tests from uncommitted files and commits ahead of
`origin/main`. Override discovery only when needed:

```bash
DIREXTALK_TEST_BASE=<ref> npm test
DIREXTALK_TEST_CHANGED_FILES=$'scripts/orchestrate.sh\nscripts/phases/s6_wire_local.sh' npm test
```

On Windows, npm test commands may be started from PowerShell, Command Prompt, or
Git Bash; the launcher finds Git for Windows Bash and runs the Bash-only suite
there. Deployment lifecycle commands themselves still run from Git Bash.

## Contributing

- Keep user-facing behavior synchronized across `README.md`, `SKILL.md`,
  `AGENTS.md`, `agents/README.md`, `agents/openai.yaml`, and relevant
  `references/*` files.
- Keep detailed edge cases in `references/`; keep this README focused on
  installation, safety, lifecycle, and maintainer validation.
- Do not commit generated credentials, local state, SSH keys, logs, service
  directories, binaries, `.codegraph/`, or machine-specific artifacts.
- Preserve portable path handling. Remote server paths are Linux paths; local
  bridge paths must match the consumer runtime, especially on native Windows.

## License

MIT. See [LICENSE](LICENSE).
