---
name: dirextalk-deployer
description: Deploy, resume, verify, destroy, and locally wire a production Dirextalk message server on AWS for any local agent runtime supported by dirextalk-connect. Use when installing or updating this skill itself; install the versioned npm package `dirextalk-deployer` and use its CLI to place the skill in the runtime-specific global path from references/agent-targets.md unless the user explicitly asks for a project-local installation.
---

# Dirextalk Deployer

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
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill refresh --agent <runtime>
```

Use project scope only when the user explicitly asks for repository-local
installation:

```bash
dirextalk-deployer skill refresh --agent <runtime> --scope project --project <project-root>
```

If npm is unavailable, report that freshness could not be checked and continue
with the local copy. If the user asks to install from `YingSuiAI/dirextalk-deployer`,
do not use a generic GitHub skill installer; read the README and follow the npm
install rule. Use a Git clone only for deployer development or local patching.

## Platform Law

Classify every path by consumer before writing it to `state.json`,
`credentials.json`, `dirextalk-connect/config.toml`, docs, or printed commands:

- Remote server paths are Linux paths consumed on EC2, such as `/var/dirextalk-message-server`.
- Deployer execution paths may be POSIX paths inside Bash phases.
- Local bridge paths are consumed by `dirextalk-connect` and local agent
  processes. On Windows they must be Windows-compatible paths.
- Documentation paths must be portable examples using `$HOME`, `%USERPROFILE%`,
  `$env:USERPROFILE`, `<service_id>`, or `<domain>`.

Windows users run `.\scripts\orchestrate.ps1` and `.\scripts\destroy.ps1` from
Windows PowerShell. These wrappers may use Git Bash internally, but must set
`DIREXTALK_LOCAL_PATH_STYLE=windows`. POSIX users run `bash scripts/orchestrate.sh`
and `bash scripts/destroy.sh`. Do not tell Windows users to use WSL unless they
explicitly choose WSL as the host runtime.
The Windows wrappers accept a working Git for Windows or MSYS2 Bash from
`PATH`; `DIREXTALK_BASH_COMMAND` selects a custom executable. They reject the
implicit Windows WSL aliases so local path ownership cannot change silently.

## Prerequisites And Confirmation

Do not deploy until the user has an active AWS account, a real long-lived
domain, AWS credentials, DNS authority, and billing acknowledgement.

For first-time users, guide them step by step. Do not front-load the whole
cloud setup checklist. Ask only the next blocking question, wait for the user's
answer or completion, then continue to the next step.

Default tone for new users:

- Use product language such as account, domain, access key file, DNS provider,
  server, fixed IP, and monthly AWS cost.
- Avoid technical labels such as EC2, EIP, IAM policy, security group, EBS,
  Matrix `server_name`, Route53 hosted zone, federation identity, or TURN unless
  the user asks what they mean or the term appears in an AWS screen they must
  operate.
- When a technical term is unavoidable, explain it in one short sentence before
  asking the user to act.
- Never give a long architecture explanation during onboarding unless the user
  explicitly asks why the step is needed.

Step-by-step onboarding flow:

1. **AWS account.**
   - Shortcut: if the user already provided valid AWS credentials, such as a
     configured profile or a CSV that passed `aws sts get-caller-identity`, skip
     browser sign-in and email questions. The agent already has AWS access.
   - Ask: "Do you already have an AWS account you can log into?"
   - If yes, continue to the access key step.
   - If no, ask the user to open
     `https://signin.aws.amazon.com/signup?request_type=register`, register in
     their browser, complete payment/phone verification and Basic support
     selection if AWS asks, then stop until they say the account is ready.
   - Never ask for, collect, paste, log, or store payment card details, root
     password, MFA code, email verification code, or phone verification code.

2. **AWS access key or profile.**
   - Ask: "Do you already have an AWS access key CSV file or AWS profile for
     deployment?"
   - If yes, ask only for the local CSV path or profile name, then verify it.
   - If no, offer two credential paths and ask the user to choose:
     1. **Root access key (default fastest path):** simpler to create for a
        first deployment because it uses the account owner identity directly.
        Explain that it is highly privileged, must be saved securely, must never
        be pasted into chat or committed, and should be rotated or deleted after
        deployment.
     2. **Dedicated IAM deployment user:** safer because it avoids root keys,
        but requires more AWS console steps. Explain in one sentence: "This
        temporary user lets the deployment tool create and later destroy this
        Dirextalk node; delete or disable it after deployment."
   - Root access keys are allowed when the operator explicitly chooses them.
     Do not block deployment only because STS returns a root ARN; report
     `root=true`, repeat the security warning once, and continue if the user
     accepts that risk.
   - Prefer the repository helper for CSV import and redacted verification:
     ```bash
     bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer <region>
     export AWS_PROFILE=dirextalk-deployer
     bash scripts/aws-credentials.sh verify dirextalk-deployer
     ```
   - The agent may read the local CSV path, but must never print the Access Key
     ID together with the Secret Access Key, and must never write secrets into
     the repository, skill files, logs, or chat output.

3. **Domain.**
   - Ask: "Do you already own a long-lived domain or subdomain you want to use
     for this Dirextalk node?"
   - If yes, ask for the domain.
   - If no, first check whether the AWS account already has Route53 registered
     domains when AWS CLI access is available:
     ```bash
     aws route53domains list-domains --profile <profile>
     ```
     If domains exist, present only the domain names and ask whether to use one.
     If none exist, ask the user to buy or prepare a domain, then stop until
     they have it.
   - Do not ask where DNS is managed. After AWS credentials are available, the
     deployer checks for the longest matching public Route53 hosted zone in the
     current AWS account. If one exists it manages the A record automatically;
     otherwise it continues with external DNS and asks for the A record only
     after the fixed public IP exists.
   - Explain only this much by default: "Use a real long-term domain because
     changing it later means creating a new chat server identity."
   - Do not use localhost, raw IP addresses, wildcard domains, disposable
     domains, temporary `sslip.io`, or other throwaway names for production.

4. **DNS control.**
   - Let S2 query public Route53 hosted zones before asking any DNS-management
     question. A matching zone selects `DOMAIN_MODE=route53`; no matching zone
     selects `DOMAIN_MODE=user` without blocking infrastructure creation.
   - If Route53 listing fails, stop with an AWS credential/IAM error. Never
     misclassify an API failure as externally managed DNS.
   - For external DNS, wait until the script emits the fixed IP, then ask the
     user to create exactly:
     ```text
     <DOMAIN>  A  <PUBLIC_IP>
     ```
   - If the user prefers Route53 while the domain is registered elsewhere, the
     hosted zone and NS delegation must be prepared explicitly first. The user
     or a provider-specific DNS connector must delegate those NS records at the
     current registrar before authoritative DNS can resolve.

5. **Billing confirmation.**
   - Give a short billing warning before the first mutating AWS command: "This
     will create paid AWS resources for the server. They keep billing until
     destroyed."
   - Provide an upfront monthly estimate for the selected region and cloud
     provider before asking for final approval. Use the pricing helper output;
     do not invent a fixed quote from memory.
   - Tell the operator that new AWS customer accounts generally receive
     `100-200 USD` in free credits, and that users who have not used Lightsail
     generally receive three months of free Lightsail usage. Coverage is
     account-specific; recommend an AWS Budget and AWS Billing Console review,
     and say AWS official real-time policy prevails.
   - Check EC2-VPC Elastic IP quota before mutating AWS resources. For explicit
     EC2, also check default VPC, EC2 vCPU quota, and AMI availability.

Credential choices for first-time users:

- **Root access key (default fastest path):** simpler for first deployment, but
  highly privileged, must be saved securely, never pasted into chat, and deleted
  or rotated after use.
- **Dedicated IAM deployment user:** safer because it avoids root keys. Create a
  temporary `DirextalkDeployer` user with `AdministratorAccess`, then delete or
  disable it after deployment.

Root access keys are allowed when the operator explicitly chooses them. Report
only redacted identity details, such as account, `root=true|false`, and a
redacted ARN. Prefer the helpers:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer <region>
bash scripts/aws-credentials.sh verify dirextalk-deployer
```

Before final deployment confirmation:

```bash
aws lightsail get-regions --include-availability-zones --output json
bash scripts/pricing-estimate.sh --region <aws-region> --cloud-provider lightsail --domain-mode route53
bash scripts/pricing-estimate.sh --state ~/.dirextalk/nodes/<service_id>/state.json --write-state
```

Record and report `cost_estimate` and billing reminders. Tell the operator that new AWS customer accounts generally receive `100-200 USD` in free credits, and that users who have not used Lightsail generally receive three months of free Lightsail usage. Coverage is account-specific; recommend an AWS Budget, AWS Billing Console review, and say AWS official real-time policy prevails. Check EC2-VPC Elastic IP quota before mutating AWS resources.

Required first-time deployment confirmation. Fill in the concrete domain,
profile, region, and cloud provider. Include the AWS credit/Lightsail trial
sentence immediately before the confirmation line:

```text
Please confirm before I deploy. New AWS customer accounts generally receive 100-200 USD in free credits, and users who have not used Lightsail generally receive three months of free Lightsail usage. Credits and trials are account-specific, actual coverage must be verified in AWS Billing Console, and AWS official real-time policy prevails.

Reply with this exact sentence:
I confirm that I have an active AWS account, the long-lived domain <domain>, and authorize the current <profile-or-identity> AWS profile in <region> to create the Dirextalk service using <cloud-provider>. I understand this can create billable AWS resources, credits or trials are not guaranteed to cover all usage, and resources keep billing until destroyed.
```

If any prerequisite is missing, stop deployment and guide the user through that
specific step before running `scripts/orchestrate.sh`.

Required deployment env:

```bash
DOMAIN=<final-domain>
CONFIRM_DOMAIN_BINDING=1
DIREXTALK_CLOUD_PROVIDER=lightsail
```

Normal server selection resolves the latest published stable GitHub Release and
persists its immutable digest in deployment state. `MESSAGE_SERVER_IMAGE` is
disabled unless `DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1` explicitly
marks a debug/legacy deployment. The independent `YingSuiAI/dirextalk-updater`
host binary is downloaded only on a verified Ubuntu 22.04 or 24.04 x86_64 server from
the deployer-pinned Release URL and must match the deployer-pinned SHA-256.
The local deployer host does not need Go and does not SCP updater artifacts.
The deployer Node selector uses the pinned mature `semver` dependency to reject
invalid `upgrade_from` ranges and ranges that include the target. Its constraint
corpus mirrors the forms accepted by the canonical Go validators; the updater
and message-server Release CI own cross-version compatibility evidence.

The only legacy host adoption path is `scripts/adopt-legacy-node.sh`. It first
requires a dry-run proof of the fixed d1 v0.15.2 Compose project, approved image
digest, live health, binary version, and systemd Caddy identity. Mutation then
requires the exact printed confirmation. It creates the updater-owned
`/var/dirextalk-message-server` view without pulling or recreating the running
container, installs the pinned updater with `caddy_mode=systemd`, and
transactionally adds only `/_dirextalk/updater/v1/jobs/*` to Caddy. Never use
this command to guess or normalize another legacy topology.

Leave `DOMAIN_MODE` unset for normal deployments. S2 automatically chooses
`route53` only when the current AWS account contains a matching public hosted
zone; otherwise it chooses `user` and gives manual A-record guidance after IP
allocation. Explicit `DOMAIN_MODE=user|route53` remains an advanced automation
override. If an existing Route53 A record points elsewhere, require
`DIREXTALK_CONFIRM_DNS_OVERWRITE=1`. If Route53 delegation is needed, wait for
authoritative DNS before continuing.

Default cloud provider is Lightsail. If no AWS region is configured in state, `AWS_DEFAULT_REGION`/`AWS_REGION`, or the AWS profile, the deployer recommends a default region from the local timezone and uses it in non-interactive runs; `DIREXTALK_DEFAULT_REGION` is the explicit deployer override. S1 queries Lightsail bundle availability and Lightsail availability zones before provisioning, but it does not query AWS Free Tier or credit usage. For manual Lightsail zone checks, use `aws lightsail get-regions --include-availability-zones --output json`; plain `aws lightsail get-regions` can omit availability-zone details. The default Lightsail zone is `<region>a`; if it is unavailable, S1/S3 select another available Lightsail zone in the same region. If Lightsail has no usable bundle or availability zone in the selected region, S1 records an EC2 cost estimate but does not automatically switch to EC2; ask the operator to choose another Lightsail-capable region/zone or explicitly rerun with `DIREXTALK_CLOUD_PROVIDER=ec2` after reviewing the estimate. EC2 remains supported explicitly with `DIREXTALK_CLOUD_PROVIDER=ec2`; then S1 checks default VPC, EC2 vCPU quota, EC2-VPC Elastic IP quota, AMI availability, and S3 uses a 50 GiB gp3 root EBS volume.

## Local Runtime Wiring

Read `references/agent-targets.md` before installing/updating this skill or
wiring a runtime. Supported connect agents are:

```text
acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux
```

The supported local bridge is `dirextalk-connect`, installed from
`dirextalk-connect@latest` by default or built from
`https://github.com/YingSuiAI/dirextalk-connect.git`. The MCP tool surface is
served by the deployed message server's HTTP MCP endpoint.

S6 writes service-scoped files under `~/.dirextalk/nodes/<service_id>/`:

```text
credentials.json
dirextalk-connect/config.toml
mcp/
```

The dirextalk-connect config must use a direct Matrix config, create the Matrix session
through `agent.matrix_session.create` with `agent_token`, require `@agent:<server>`,
and restrict sync/replies to the real `agent_room_id`. It must not use
MCP credential-file environment variables.

Key selectors:

```bash
DIREXTALK_AGENT_PLATFORM=auto
DIREXTALK_CONNECT_AGENT=<optional connect agent>
DIREXTALK_AGENT_INSTALL=auto
DIREXTALK_AGENT_INSTALL_MODE=recommended
```

`DIREXTALK_AGENT_INSTALL=auto` installs `dirextalk-connect@latest` into the
current service directory, not into the npm global prefix, unless explicit
binary/command overrides are set. MCP capability is declared independently from
bridge-agent support and follows the effective connect agent: session (`acp`,
Claude Code, Codex, Copilot, Gemini, Kimi, OpenCode, and Qoder), host-managed
(Antigravity, Cursor, and iFlow), and unsupported (Devin, Pi, Reasonix, and
tmux). Detected OpenClaw and Hermes hosts are always host-managed because their
native registries own MCP. They require the ACP bridge; a non-ACP
`DIREXTALK_CONNECT_AGENT` override fails closed. To bridge directly to Codex,
select `DIREXTALK_AGENT_PLATFORM=codex` instead.
Unsupported and unknown effective agents fail closed. The protocol vocabulary
retains `project` and `conditional`, but no current connect backend uses them.
S6 never generates a generic fallback artifact. Dedicated manual artifacts are
limited to registry entries that name one; no unconsumed MCP env artifact is
generated. MCP does not need a local CLI, daemon, proxy, or listening
port. S6 installs the
service-scoped `dirextalk-connect` daemon and records it as installed only after
`daemon status` reports Running and recent logs show `dirextalk-connect is
running`; logs that show agent CLI missing, login/trust failures, ACP startup
failures, or agent offline state fail S6 so deploy does not report success
prematurely. `recommend` writes files and prints commands only; `skip` writes
credentials and configs only. S6 no longer writes the retired service-level
`env` file. Host-runtime artifacts remain reviewable even when the effective
connect agent differs. For host-managed MCP, S6 omits all canonical MCP fields
from connect agent options and never mutates user-global host config. With
`DIREXTALK_AGENT_INSTALL=auto`, S6 writes the artifact, records
`mcp_install_status=host_action_required`, and waits before bridge startup.
After the operator enrolls the remote endpoint in the host, rerun with
`DIREXTALK_MCP_HOST_READY=1`. OpenClaw must then pass the secret-free official
`openclaw mcp probe <server-name> --json` check before S6 starts the bridge and
records `host_probe_passed`. `OPENCLAW_CONFIG_PATH` is inherited, and
`DIREXTALK_OPENCLAW_PROFILE=<profile>` adds the native `--profile` selector for
service isolation. S6 never runs `mcp set`. Other host-managed backends with no
official probe record `operator_confirmed_host_managed` and still require later
runtime verification. `recommend` and `skip` retain `host_action_required`
until explicitly confirmed. Generated agent options
write `mode = "yolo"` by default unless an explicit `mode` is supplied.
On Windows, Cursor wiring uses `%LOCALAPPDATA%\cursor-agent\agent.cmd`. If
Cursor Agent CLI is not logged in, the operator must run `agent.cmd login`
once; rerunning the deployer refreshes config and restarts the service-scoped
daemon. Explicit `DIREXTALK_CURSOR_COMMAND`, `DIREXTALK_CURSOR_AGENT_COMMAND`,
`DIREXTALK_OPENCODE_COMMAND`, `DIREXTALK_CONNECT_AGENT_CMD`,
`DIREXTALK_CURSOR_MODE`, and `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` overrides
still win except where a host-owned OpenClaw/Hermes scope would be bypassed.
Hermes writes `mcp/hermes.md`, creates an empty per-service HERMES_HOME, and
uses the same profile/home in ACP args/env and the secret-free
`hermes -p <profile> mcp test <server-name>` gate. The operator must first
create/clone that profile and enroll native `mcp_servers`; S6 never writes a
generic Hermes JSON file or touches the real user Hermes home.

State/report fields include `mcp_capability`, `mcp_config_dir`, `mcp_selected_config_type`,
`mcp_selected_config`, token-free host-guidance fields such as
`mcp_openclaw_config` and `mcp_hermes_config`, `mcp_transport`, `mcp_endpoint_url`,
`credentials.status`, and `mcp.status`.
Codex and Cursor do not receive standalone token-bearing MCP artifacts. Session
injection is owned by dirextalk-connect; Cursor remains host-managed.

## Product Gates

S7 green is not the final product-complete state. A new deployment is complete
only after:

1. The user receives the App domain and eight-digit app initialization code.
2. The user confirms App initialization.
3. dirextalk-connect is wired to the real `agent_room_id`.
4. MCP snippets exist and `verify mcp_doctor` succeeds against the server HTTP MCP endpoint.
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
DIREXTALK_CONFIRM_EVIDENCE="user completed app initialization" DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm app_initialization
DIREXTALK_CONFIRM_RUNTIME_PROBE=1 DIREXTALK_CONFIRM_EVIDENCE="MCP doctor/tool discovery and runtime probe confirmed" DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm agent_mcp_runtime
```

Every `confirm` command requires `DIREXTALK_CONFIRM_EVIDENCE`; evidence must be
concrete and at least 12 characters. For `agent_mcp_runtime`, first require
`runtime_checks.summary.status=passed`, then set `DIREXTALK_CONFIRM_RUNTIME_PROBE=1`
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
gate status, `agent_room_id`, service directory, dirextalk-connect config, MCP config
paths, Matrix bridge user/device, AWS region, cloud provider, cloud instance/public IP, SSH path,
state path, report path, AWS credit/Lightsail trial reminder, AWS official policy reminder,
AWS Billing Console verification reminder, stop-billing reminder, and security reminder to delete
or disable temporary credentials and rotate/remove root access keys if used.

## Update, Reset, And Destroy

Use `scripts/update.sh` for image-only refresh. It preserves infrastructure,
TLS storage, local credentials, confirmations, runtime checks, dirextalk-connect daemon
state, and MCP artifacts unless verification proves credentials were regenerated.

Use `scripts/reset-app-data.sh` only with `DIREXTALK_RESET_APP_DATA_CONFIRM=1`.
It preserves the cloud instance, fixed public IP/static IP or Elastic IP, DNS, and Caddy TLS storage, clears
application data, clears old user-confirmation/runtime-check evidence, sets
`connect_install_status=refresh_pending`, marks local refresh pending, and stops only the matching service-scoped dirextalk-connect daemon. The follow-up
orchestrate run regenerates credentials and MCP snippets.

Destroy uses `scripts/destroy.sh` on POSIX and `.\scripts\destroy.ps1` on
Windows PowerShell. Destroy uses the same AWS identity boundary as deployment.
Root AWS access-key identity is allowed when the operator explicitly chose it.
Destroy stops and uninstalls only the service-scoped daemon whose WorkDir
matches `~/.dirextalk/nodes/<service_id>/dirextalk-connect`, then removes recorded AWS
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
