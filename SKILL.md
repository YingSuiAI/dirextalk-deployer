---
name: direxio-deployer
description: Deploy, resume, verify, destroy, and locally wire a production Direxio message server on AWS for any local agent runtime supported by direxio-connect. Use when installing or updating this skill itself; install the versioned npm package `direxio-deployer` and use its CLI to place the skill in the runtime-specific global path from references/agent-targets.md unless the user explicitly asks for a project-local installation.
---

# Direxio Deployer

This skill is the compact agent-facing entrypoint. Treat this repository root
as the execution engine and read the referenced docs only when that phase needs
detail.

Entrypoints:

```text
scripts/orchestrate.sh
scripts/orchestrate.ps1
scripts/destroy.sh
scripts/destroy.ps1
scripts/update.sh
scripts/reset-app-data.sh
```

## Freshness Gate

Before deployment, repair, verification, teardown, runtime wiring, or skill
installation, make one freshness attempt:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill refresh --agent <runtime>
```

Use project scope only when the user explicitly asks for repository-local
installation:

```bash
direxio-deployer skill refresh --agent <runtime> --scope project --project <project-root>
```

If npm is unavailable, report that freshness could not be checked and continue
with the local copy. If the user asks to install from `YingSuiAI/direxio-deployer`,
do not use a generic GitHub skill installer; read the README and follow the npm
install rule. Use a Git clone only for deployer development or local patching.

## Platform Law

Classify every path by consumer before writing it to `state.json`,
`credentials.json`, `env`, `direxio-connect/config.toml`, docs, or printed commands:

- Remote server paths are Linux paths consumed on EC2, such as `/var/direxio-message-server`.
- Deployer execution paths may be POSIX paths inside Bash phases.
- Local bridge paths are consumed by `direxio-connect` and local agent
  processes. On Windows they must be Windows-compatible paths.
- Documentation paths must be portable examples using `$HOME`, `%USERPROFILE%`,
  `$env:USERPROFILE`, `<service_id>`, or `<domain>`.

Windows users run `.\scripts\orchestrate.ps1` and `.\scripts\destroy.ps1` from
Windows PowerShell. These wrappers may use Git Bash internally, but must set
`DIREXIO_LOCAL_PATH_STYLE=windows`. POSIX users run `bash scripts/orchestrate.sh`
and `bash scripts/destroy.sh`. Do not tell Windows users to use WSL unless they
explicitly choose WSL as the host runtime.

## Prerequisites And Confirmation

Do not deploy until the user has an active AWS account, a real long-lived
domain, AWS credentials, DNS authority, and billing acknowledgement.

Credential choices for first-time users:

- **Root access key (default fastest path):** simpler for first deployment, but
  highly privileged, must be saved securely, never pasted into chat, and deleted
  or rotated after use.
- **Dedicated IAM deployment user:** safer because it avoids root keys. Create a
  temporary `DirexioDeployer` user with `AdministratorAccess`, then delete or
  disable it after deployment.

Root access keys are allowed when the operator explicitly chooses them. Report
only redacted identity details, such as account, `root=true|false`, and a
redacted ARN. Prefer the helpers:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer <region>
bash scripts/aws-credentials.sh verify direxio-deployer
```

Before final deployment confirmation:

```bash
aws freetier get-account-plan-state --output json
bash scripts/pricing-estimate.sh --region <aws-region> --cloud-provider lightsail --domain-mode <user|route53>
bash scripts/pricing-estimate.sh --state ~/.direxio/nodes/<service_id>/state.json --write-state
```

Record and report `cost_estimate`. Mention that AWS may advertise `100 USD initial credits`, but coverage is account-specific and must be verified in AWS Billing Console. Recommend an AWS Budget. Check EC2-VPC Elastic IP quota before
mutating AWS resources.

Required deployment env:

```bash
DOMAIN=<final-domain>
DOMAIN_MODE=user
CONFIRM_DOMAIN_BINDING=1
MESSAGE_SERVER_IMAGE=direxio/message-server:latest
DIREXIO_CLOUD_PROVIDER=lightsail
```

Use `DOMAIN_MODE=route53` only when the user authorizes AWS to manage the A
record. If an existing A record points elsewhere, require
`DIREXIO_CONFIRM_DNS_OVERWRITE=1`. If Route53 delegation is needed, wait for
authoritative DNS before continuing.

Default cloud provider is Lightsail. S1 queries Free Tier usage, Lightsail bundle availability, and Lightsail availability zones before provisioning. The default Lightsail zone is `<region>a`; if it is unavailable, S1/S3 select another available Lightsail zone. If Lightsail has no usable bundle or availability zone in the selected region and the operator did not explicitly force Lightsail, S1 records EC2 as the selected/recommended provider before provisioning. EC2 remains supported explicitly with `DIREXIO_CLOUD_PROVIDER=ec2`; then S1 checks default VPC, EC2 vCPU quota, EC2-VPC Elastic IP quota, AMI availability, and S3 uses a 50 GiB gp3 root EBS volume.

## Local Runtime Wiring

Read `references/agent-targets.md` before installing/updating this skill or
wiring a runtime. Supported connect agents are:

```text
acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux
```

The supported local bridge is `direxio-connect`, installed from
`direxio-connent@latest` by default or built from
`https://github.com/YingSuiAI/direxio-connect.git`. The MCP tool surface is
`direxio-mcp@latest`.

S6 writes service-scoped files under `~/.direxio/nodes/<service_id>/`:

```text
credentials.json
env
direxio-connect/config.toml
mcp/
```

The direxio-connect config must use a direct Matrix config, create the Matrix session
through `agent.matrix_session.create` with `agent_token`, require `@agent:<server>`,
and restrict sync/replies to the real `agent_room_id`. It must not use
`DIREXIO_CREDENTIALS_FILE`; MCP owns that variable.

Key selectors:

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_CONNECT_AGENT=<optional connect agent>
DIREXIO_AGENT_INSTALL=auto
DIREXIO_AGENT_INSTALL_MODE=recommended
```

`DIREXIO_AGENT_INSTALL=auto` installs `direxio-connent@latest`, installs the
service-scoped `direxio-connect` daemon, installs `direxio-mcp@latest`, and
installs the service-scoped `direxio-mcp` daemon used by Hermes through
`direxio-mcp proxy --url <local-daemon-url>`.
S6 only records the daemon as installed after `daemon status` reports Running
and recent logs show `direxio-connect is running`; logs that show agent CLI
missing, login/trust failures, ACP startup failures, or agent offline state fail
S6 so deploy does not report success prematurely. `recommend` writes files and
prints commands only; `skip` writes credentials/env and configs only. OpenClaw
and Hermes map to the generic ACP backend by default.
On Windows, Cursor wiring uses `%LOCALAPPDATA%\cursor-agent\agent.cmd` and
writes `mode = "yolo"` by default. If Cursor Agent CLI is not logged in, the
operator must run `agent.cmd login` once; rerunning the deployer refreshes
config and restarts the service-scoped daemon. Explicit `DIREXIO_CURSOR_COMMAND`,
`DIREXIO_CURSOR_AGENT_COMMAND`, `DIREXIO_CONNECT_AGENT_CMD`, and
`DIREXIO_CONNECT_AGENT_OPTIONS_TOML` overrides still win.

State/report fields include `mcp_config_dir`, `mcp_codex_config`,
`mcp_cursor_config`, `mcp_openclaw_config`, `mcp_hermes_config`,
`mcp_json_config`, `mcp_daemon_url`, `mcp_daemon_status_command`,
`credentials.status`, and `mcp.status`.
Cursor MCP artifacts are generated as JSON for `.cursor/mcp.json` or
`~/.cursor/mcp.json`, but the deployer does not write those locations by
default because they contain machine-local credential paths. Cursor may require
a full restart or MCP settings reload/enable after the operator adds the
generated snippet.

## Product Gates

S7 green is not the final product-complete state. A new deployment is complete
only after:

1. The user receives the App domain and eight-digit app initialization code.
2. The user confirms App initialization.
3. direxio-connect is wired to the real `agent_room_id`.
4. MCP snippets exist and `direxio-mcp doctor --json` succeeds.
5. Agent/MCP validation is non-polluting; prefer read-only checks and do not
   auto-send a normal chat message.

Runtime verification commands:

```bash
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify connect_daemon
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify mcp_doctor
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify mcp_smoke
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify mcp_tools
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify runtime
```

Manual confirmation commands:

```bash
DIREXIO_CONFIRM_EVIDENCE="user completed app initialization" DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm app_initialization
DIREXIO_CONFIRM_RUNTIME_PROBE=1 DIREXIO_CONFIRM_EVIDENCE="MCP doctor/tool discovery and runtime probe confirmed" DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm agent_mcp_runtime
```

Every `confirm` command requires `DIREXIO_CONFIRM_EVIDENCE`; evidence must be
concrete and at least 12 characters. For `agent_mcp_runtime`, first require
`runtime_checks.summary.status=passed`, then set `DIREXIO_CONFIRM_RUNTIME_PROBE=1`
only after a real runtime/channel probe sees the service-scoped MCP tools.

## Status, Reports, And Delivery

When blocked or failed, run `bash scripts/orchestrate.sh status` for the current
service and reflect the Recovery summary:

- Where it is blocked.
- Billing impact.
- Resume safety.
- Local refresh: if refresh is pending, rerun the deployment workflow to refresh S4-S7, local credentials, MCP snippets, automatic installs, and runtime checks.
- Next action.
- Stop-loss.

Operation reports are written as redacted `operation-report.json` artifacts.
`scripts/orchestrate.sh report new_deploy` can regenerate a new deployment
report. Reports must not include AWS secrets, access tokens, agent tokens,
Matrix session tokens, or the eight-digit app initialization code. Because user
evidence can contain secrets, confirmation evidence is redacted, including
eight-or-more digit numeric strings.

Reports include `user_confirmation_details`, `destroy.evidence`,
`credentials.status`, `mcp.status`, `possible_remaining_billable_resources`,
AWS resource IDs, EBS root volume evidence, the default 50 GiB gp3 root EBS
volume size, billing reminders, and `cost_estimate`.

Delivery must include App domain, eight-digit app initialization code, product
gate status, `agent_room_id`, service directory, direxio-connect config, MCP config
paths, Matrix bridge user/device, AWS region, cloud provider, cloud instance/public IP, SSH path,
state path, report path, stop-billing reminder, and security reminder to delete
or disable temporary credentials and rotate/remove root access keys if used.

## Update, Reset, And Destroy

Use `scripts/update.sh` for image-only refresh. It preserves infrastructure,
TLS storage, local credentials, confirmations, runtime checks, direxio-connect daemon
state, and MCP artifacts unless verification proves credentials were regenerated.

Use `scripts/reset-app-data.sh` only with `DIREXIO_RESET_APP_DATA_CONFIRM=1`.
It preserves the cloud instance, fixed public IP/static IP or Elastic IP, DNS, and Caddy TLS storage, clears
application data, clears old user-confirmation/runtime-check evidence, sets
`connect_install_status=refresh_pending`, marks local refresh pending, and stops only the matching service-scoped direxio-connect daemon. The follow-up
orchestrate run regenerates credentials and MCP snippets.

Destroy uses `scripts/destroy.sh` on POSIX and `.\scripts\destroy.ps1` on
Windows PowerShell. Destroy uses the same AWS identity boundary as deployment.
Root AWS access-key identity is allowed when the operator explicitly chose it.
Destroy stops and uninstalls only the service-scoped daemon whose WorkDir
matches `~/.direxio/nodes/<service_id>/direxio-connect`, then removes recorded AWS
resources and writes `destroy.evidence`. If `possible_remaining_billable_resources`
is present, AWS Console/Billing is the source of truth and cleanup must continue.

## References

- Tool setup: `references/tooling.md`
- Agent targets: `references/agent-targets.md`
- Deployment workflow, confirmations, pricing, and DNS: `references/deployment-workflow.md`
- Runtime wiring: `references/runtime-wiring.md`
- Verification and recovery: `references/verification-recovery.md`
- State machine: `references/state-machine.md`
- Architecture and troubleshooting: `references/architecture.md`, `references/troubleshooting.md`
- Windows notes: `references/windows-deployment-notes.md`
- Token refresh/update/reset: `references/token-refresh.md`
