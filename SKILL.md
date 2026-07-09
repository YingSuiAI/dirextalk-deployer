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
`credentials.json`, `env`, `dirextalk-connect/config.toml`, docs, or printed commands:

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
   - Default new users to Route53 registration and `DOMAIN_MODE=route53` so the
     deployer can create the hosted zone and A record. Use `DOMAIN_MODE=user`
     only when an external DNS provider must keep managing the domain and the
     operator will create the final A record.
   - Explain only this much by default: "Use a real long-term domain because
     changing it later means creating a new chat server identity."
   - Do not use localhost, raw IP addresses, wildcard domains, disposable
     domains, temporary `sslip.io`, or other throwaway names for production.

4. **DNS control.**
   - Ask: "Is this domain managed in AWS Route53, or somewhere else like
     Cloudflare, GoDaddy, or Alibaba Cloud?"
   - If AWS Route53, use `DOMAIN_MODE=route53` only after the user confirms AWS
     may create or update the domain's hosted zone and A record.
   - If another provider manages DNS and no provider automation is available,
     use `DOMAIN_MODE=user` as a waiting external-action state. Later, when the
     script emits the fixed IP, ask the user to create exactly:
     ```text
     <DOMAIN>  A  <PUBLIC_IP>
     ```
   - If the user prefers Route53 while the domain is registered elsewhere, S3
     can create the Route53 hosted zone and record NS nameservers. The user or a
     provider-specific DNS connector must still delegate those NS records at the
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
DOMAIN_MODE=route53
CONFIRM_DOMAIN_BINDING=1
MESSAGE_SERVER_IMAGE=dirextalk/message-server:latest
DIREXTALK_CLOUD_PROVIDER=lightsail
```

Default to `DOMAIN_MODE=route53` for new users and for domains whose DNS can be
managed by AWS. Use `DOMAIN_MODE=user` only for externally managed DNS. If an
existing Route53 A record points elsewhere, require
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
env
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
binary/command overrides are set. S6 writes only the MCP snippet selected for the
detected runtime: Codex, Cursor, OpenClaw, and Hermes have dedicated snippets;
other MCP-capable supported runtimes use the generic `mcp-servers.json`.
Generated MCP snippets point directly to the deployed message server's HTTP MCP
endpoint with the service agent token; MCP does not need a local CLI, daemon,
proxy, or listening port. S6 installs the
service-scoped `dirextalk-connect` daemon and records it as installed only after
`daemon status` reports Running and recent logs show `dirextalk-connect is
running`; logs that show agent CLI missing, login/trust failures, ACP startup
failures, or agent offline state fail S6 so deploy does not report success
prematurely. `recommend` writes files and prints commands only; `skip` writes
credentials/env and configs only. OpenClaw
and Hermes map to the generic ACP backend by default. Generated agent options
write `mode = "yolo"` by default unless an explicit `mode` is supplied.
On Windows, Cursor wiring uses `%LOCALAPPDATA%\cursor-agent\agent.cmd`. If
Cursor Agent CLI is not logged in, the operator must run `agent.cmd login`
once; rerunning the deployer refreshes config and restarts the service-scoped
daemon. Explicit `DIREXTALK_CURSOR_COMMAND`, `DIREXTALK_CURSOR_AGENT_COMMAND`,
`DIREXTALK_OPENCODE_COMMAND`, `DIREXTALK_CONNECT_AGENT_CMD`,
`DIREXTALK_CURSOR_MODE`, and
`DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` overrides still win.

State/report fields include `mcp_config_dir`, `mcp_selected_config_type`,
`mcp_selected_config`, selected runtime-specific fields such as
`mcp_codex_config`, `mcp_cursor_config`, `mcp_openclaw_config`,
`mcp_hermes_config`, or `mcp_json_config`, `mcp_transport`, `mcp_endpoint_url`,
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
