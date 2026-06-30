---
name: direxio-deployer
description: Deploy, resume, verify, destroy, and locally wire a production P2P-IM Matrix server on AWS for any connent/connect-supported local agent runtime. Use when installing or updating this skill itself; install the versioned npm package `direxio-deployer` and use its CLI to place the skill in the runtime-specific global path from references/agent-targets.md unless the user explicitly asks for a project-local installation.
---

# Direxio Deployer

This skill is the agent-facing deployment runbook for a production Direxio message server. It combines user confirmation, local tool checks, AWS provisioning, DNS waiting, service bootstrap, credential delivery, local agent wiring, verification, and teardown.

Agents should treat this repository root as the execution engine. The runnable entrypoints are:

```text
scripts/orchestrate.sh
scripts/orchestrate.ps1
scripts/destroy.sh
scripts/destroy.ps1
```

## Skill Freshness Gate

Before following this local Skill for deployment, repair, verification,
teardown, runtime wiring, or skill installation, make one freshness attempt
against the versioned npm package:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill refresh --agent <runtime>
```

Use the current runtime name for `<runtime>` when known, such as `codex`,
`claudecode`, `gemini`, `cursor`, `openclaw`, or `hermes`. Use project scope
only when the user explicitly asks for a repository-local install or provides
a project root for that purpose:

```bash
direxio-deployer skill refresh --agent <runtime> --scope project --project <project-root>
```

`direxio-deployer skill refresh` checks the latest npm version, updates the
global CLI when npm reports a newer package, and refreshes the managed skill
copy in the selected runtime directory. If npm is unavailable, offline, or not
authenticated, report that freshness could not be checked and continue with
this local copy.

If this Skill is running from a Git clone whose origin is
`YingSuiAI/direxio-deployer`, Git may be used as a developer fallback: fetch
`origin main` and compare the local HEAD with `origin/main`. Fast-forward only
when it is safe and does not overwrite local edits. If the clone has local
changes, do not discard them; report the divergence and continue from the local
copy unless the user approves a specific update action.

Do not fall back to older P2P-IM skill repositories or unmanaged copied skill bundles unless the user explicitly asks for one of those repositories. Never print or commit AWS credentials, initialization codes, agent tokens, or local credential files while refreshing the Skill.

## Cloud Account And Domain Onboarding

Before running any deployment command or creating paid cloud resources, make
sure the user has the three real-world prerequisites: an active AWS account, a
stable domain, and AWS credentials that the agent can use without seeing or
printing secrets.

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
   - **Shortcut:** If the user already provided valid AWS credentials (a
     configured profile or a CSV that passed `aws sts get-caller-identity`),
     skip the browser sign-in and email questions entirely. The agent already
     has AWS access.
   - Ask: "Do you already have an AWS account you can log into?"
   - If yes, continue to the access key step.
   - If no, ask the user to open
     `https://signin.aws.amazon.com/signup?request_type=register` and register
     in their browser, then stop until they say the account is ready.
   - Do not explain AWS resource details at this stage unless asked.
   - Never ask for, collect, paste, log, or store payment card details, root
     password, MFA code, email verification code, or phone verification code.
   - **After credentials are configured and verified** (`aws sts
     get-caller-identity` succeeds), do NOT ask "what is your AWS email" or
     attempt browser sign-in. Use the CLI for all AWS operations — DNS checks,
     Route53 zone inspection, EC2 provisioning.

2. **AWS access key or profile.**
   - Ask: "Do you already have an AWS access key CSV file or AWS profile for
     deployment?"
   - If yes, ask only for the local CSV path or profile name, then verify it
     with `aws sts get-caller-identity`.
   - If no, default to a temporary IAM administrator user for MVP deployment.
     Explain in one sentence: "This temporary user lets the deployment tool
     create and later destroy this Direxio node; delete or disable it after
     deployment."
   - Root access keys are allowed when the operator explicitly chooses them.
     Prefer a temporary `DirexioDeployer` IAM user for routine deployments, but
     do not block deployment only because `aws sts get-caller-identity` returns
     an ARN ending in `:root`. Warn once that root credentials are highly
     privileged and should be rotated or removed when no longer needed, then
     continue if the user accepts that risk.
   - Guide only one or two clicks at a time:
     1. Open `https://console.aws.amazon.com/iam/home#/users/create`.
     2. Create a user named `DirexioDeployer-YYYYMMDD` or `DirexioDeployer`.
     3. Attach the AWS managed policy `AdministratorAccess`. State plainly
        that this is a temporary MVP deployment permission, not the long-term
        least-privilege target.
     4. Open the new user's `Security credentials`.
     5. In `Access keys`, choose `Create access key`.
     6. Select `Command Line Interface (CLI)`, confirm the warning, then
        continue.
     7. Choose `Create access key`, download the `.csv` file, and provide only
        the local file path.
   - After credentials are configured, run `aws sts get-caller-identity`,
     report only the account, whether the identity is root, and the redacted
     ARN.
   - Prefer the repository helper for CSV import and redacted verification:
     ```bash
     bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer <region>
     export AWS_PROFILE=direxio-deployer
     bash scripts/aws-credentials.sh verify direxio-deployer
     ```
     The helper verifies the CSV credentials with STS before writing them,
     writes only to the local AWS credentials/config files with mode `0600`,
     and prints only a redacted ARN plus `root=true|false`.
   - For long-term hardening after MVP deployment, the operator may replace
     `AdministratorAccess` with a narrower policy such as
     `references/iam-policy.json`, but do not make a nontechnical first-time
     user debug least-privilege IAM before the first deployment.
   - **Reading the CSV file:** On some platforms, terminal output-level
     redaction may truncate credential values (e.g. `AKIAQ6...W47B` instead of
     the full key). In that case, use Python to read the raw CSV bytes and
     configure AWS CLI — see `references/windows-deployment-notes.md` for the
     exact code snippet.
   - The agent may read the local CSV path, but must never print the Access Key
     ID together with the Secret Access Key, and must never write secrets into
     the repository, skill files, logs, or chat output.

3. **Domain.**
   - Ask: "Do you already own a domain or subdomain you want to use for this
     Direxio node?"
   - If yes, ask for the domain.
   - If no, **before asking them to buy one**, first check whether they already
     own domains registered in the same AWS account:
     ```bash
     aws route53domains list-domains --profile <profile>
     ```
     If the account has domains, present the list and ask if they want to use
     one of them. This avoids unnecessary purchases when the user forgot what
     they own.
   - If no domains exist in the account either, ask them to buy or prepare one
     first, then stop until they have it.
   - When guiding domain purchase, keep it concrete and short:
     1. Open one official registrar URL in the browser.
     2. Search for a domain name.
     3. Buy the domain.
     4. Return with the domain name. In examples and templates, represent it
        as `__DOMAIN__`.
   - Use plain official URLs instead of complex Markdown links. Do not invent
     deep links or wrap one URL inside another.
   - Suggested official registrar URLs:
     - AWS Route53 domain registration: `https://console.aws.amazon.com/route53/domains/home#/DomainSearch`
     - Alibaba Cloud domain registration: `https://wanwang.aliyun.com/domain/`
     - Cloudflare domain registration: `https://dash.cloudflare.com/`
     - GoDaddy domain registration: `https://www.godaddy.com/domains`
   - Explain only this much by default: "Use a real long-term domain because
     changing it later means creating a new chat server identity."
   - Do not use localhost, raw IP addresses, wildcard domains, disposable
     domains, temporary `sslip.io`, or other throwaway names for production.

4. **DNS control.**
   - Ask: "Is this domain managed in AWS Route53, or somewhere else like
     Cloudflare, GoDaddy, or Alibaba Cloud?"
   - If AWS Route53, use `DOMAIN_MODE=route53` only after the user confirms AWS
     may create or update the domain's hosted zone and A record. S3 will reuse
     a matching hosted zone or create one, record the hosted zone id and NS
     nameservers in state, then upsert the A record. If an existing A record
     points to a different IP, S3 must stop with `waiting_user` and record the
     old and pending values; continue only after the user confirms overwrite:
     `DIREXIO_CONFIRM_DNS_OVERWRITE=1`.
   - If another provider exposes an API and the user grants that provider's DNS
     authorization, prefer provider automation. If no provider automation is
     available, use `DOMAIN_MODE=user` as a fallback and treat it as a waiting
     external-action state, not a finished deployment. Later, when the script
     emits the fixed IP, ask the user to create exactly:

     ```text
     <DOMAIN>  A  <PUBLIC_IP>
     ```

   - **Route53 delegation from another provider** — If the user prefers Route53
     even though the domain is registered elsewhere (Alibaba, GoDaddy,
     Cloudflare, etc.), S3 can create the Route53 hosted zone and record its
     NS nameservers. The user or a provider-specific DNS connector must still
     delegate those NS records at the current registrar before authoritative
     DNS can resolve. Do not continue past DNS verification until authoritative
     DNS points to the new public IP.

5. **Billing confirmation.**
   - Give a short billing warning before the first mutating AWS command:
     "This will create paid AWS resources for the server. They keep billing
     until destroyed."
   - When AWS CLI is available after credentials are verified, make a best
     effort Free Tier account-plan check:
     ```bash
     aws freetier get-account-plan-state --output json
     ```
     If it returns `accountPlanRemainingCredits`, mention the remaining credit
     amount and expiration without treating it as a guarantee. If the command
     is unavailable or fails, use the fixed wording: "AWS currently advertises
     100 USD initial credits for new customer accounts, plus possible
     additional credits after completing Free Tier activities. These credits
     may cover a small trial deployment, but coverage is account-specific and
     must be verified in AWS Billing Console."
   - **Provide an upfront monthly cost estimate** based on the selected
     region and instance type, so the user can decide whether to proceed.
     `scripts/orchestrate.sh` records `cost_estimate` in state before the
     first mutating AWS phase, and S3 refreshes it after the final EC2
     instance type is selected. For a manual preflight estimate before state
     exists, run:

     ```bash
     bash scripts/pricing-estimate.sh \
       --region <aws-region> \
       --instance-type t3.small \
       --disk-gb 8 \
       --domain-mode <user|route53>
     ```

     For an existing service state, refresh and persist the estimate with:

     ```bash
     bash scripts/pricing-estimate.sh --state ~/.direxio/nodes/<service_id>/state.json --write-state
     ```

     The helper queries AWS Price List when available and falls back to
     conservative values with an explicit `pricing_status=fallback` warning.
     Default estimate scope is EC2 `t3.small`, 8 GB gp3, and ~730 hours/month:

     | Resource | Monthly Cost |
     |---|---:|
     | EC2 t3.small (Linux) | query current regional On-Demand rate |
     | EBS gp3 (8 GB) | calculate from current regional gp3 rate |
     | Public IPv4 / Elastic IP | billed hourly by AWS, even when attached |
     | Route53 hosted zone | included when `DOMAIN_MODE=route53` |
     | Outbound data and TURN relay traffic | depends on actual usage |
     | **Total** | **sum the current regional rates before asking for approval** |

     Do not present a fixed final quote from this file. Present the current
     helper output, identify whether it is `queried` or `fallback`, and say
     that it excludes data transfer, TURN relay traffic, domain registration,
     taxes, and AWS credits. Tell the user to verify any AWS credits in AWS
     Billing Console; the AWS Billing Console is the source of truth because
     credits only apply when the account, plan, region, and service usage are
     eligible. Recommend setting an AWS Budget or billing alert before leaving
     the node running.
   - **Before asking for the final deployment confirmation**, run the S1
     preflight or equivalent AWS CLI checks for the selected region so hard
     capacity blockers are known up front. In particular, check EC2-VPC Elastic IP quota because each deployment needs one fixed public IP:

     ```bash
     aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value' --output text
     aws ec2 describe-addresses --query 'length(Addresses[?Domain==`vpc`])' --output text
     ```

     If allocated Elastic IPs are already greater than or equal to quota, stop
     before confirmation and tell the user to release an unused Elastic IP,
     request quota, or choose another region. Do not wait until S3 allocation
     fails on the live deployment path.
   - If the user asks what is billed, mention EC2/server, fixed public IPv4 or
     Elastic IP, storage, DNS, network traffic, and call relay traffic.

Required first-time deployment confirmation. Fill in the concrete domain,
profile, and region, and include the Free Tier sentence immediately before the
confirmation line:

```text
Please confirm before I deploy. AWS new customer accounts may have Free Tier credits, currently advertised as 100 USD initial credits plus possible additional credits; these credits may cover a small trial deployment, but actual coverage must be verified in AWS Billing Console.

Reply with this exact sentence:
I confirm that I have an active AWS account, the long-lived domain <domain>, and authorize the current <profile-or-identity> AWS profile in <region> to create the Direxio service. I understand this can create billable AWS resources, credits are not guaranteed to cover all usage, and resources keep billing until destroyed.
```

If any prerequisite is missing, stop deployment and guide the user through that
specific step before running `scripts/orchestrate.sh`.

## Deployment Mode Boundary

Current MVP deployment path is EC2-only. The supported production path creates
an EC2 instance, gp3 root volume, public IPv4/Elastic IP, security group, key
pair, Route53 DNS record when authorized, Caddy/TLS, message-server bootstrap,
local `direxio-connect`, and service-scoped MCP snippets.

The default instance type is EC2 `t3.small` on x86/amd64. Do not put ordinary
users into a cloud product selection flow. Recommend the closest appropriate
AWS region, calculate the current regional estimate, explain billing, and then
run the EC2 path after confirmation. Use `INSTANCE_TYPE` only when the operator
explicitly chooses a larger EC2 size.

Lightsail is a future deployment mode, not a current automatic option. Lightsail requires a separate deploy_mode=lightsail implementation before it can be offered: separate instance creation, Static IP, firewall, SSH/init handling, DNS, state recording, destroy evidence, pricing, and tests. Do not describe it as available through the current EC2 state machine.

## Skill And Runtime Targets

When the user asks to install or update this skill itself, or asks to wire Direxio into a local agent runtime, read `references/agent-targets.md` first. It is the source of truth for connent/connect agent targets, legacy host-runtime aliases, generic targets, and unknown targets.

If the user says "install skills" and includes the GitHub repository URL
`YingSuiAI/direxio-deployer`, do not use a generic GitHub skill installer for
normal deployment use. First install the npm package and then run
`direxio-deployer skill install --agent <runtime>`. Use a Git clone only when the user explicitly asks for
deployer development or local patching.

Install or update this skill with the versioned npm CLI at the runtime-specific
global path from `references/agent-targets.md`:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent <runtime>
direxio-deployer skill update --agent <runtime>
```

The installer writes `.direxio-skill-install.json` into the target directory
and refuses to overwrite unmanaged existing content unless the operator
explicitly uses `--force`. Use project-local runtime skill directories only
when the user explicitly asks to install into a repository or workspace:

```bash
direxio-deployer skill install --agent <runtime> --scope project --project <project-root>
```

Use a Git clone only for development or local patching of this deployer, not as the normal end-user installation path.

## Agent Recognition

Use this skill when the user asks to deploy, resume, verify, destroy, repair, or wire a P2P-IM Matrix server. The instructions are runtime-neutral and can be followed by any agent that can run shell commands and read files. The local bridge target must be one of the connent/connect agents unless the user explicitly supplies compatible custom TOML. OpenClaw and Hermes are host runtimes that S6 wires through the generic connent/connect `acp` agent.

For local agent integration after deployment, S6 writes service-specific credentials and environment files under `~/.direxio/nodes/<service_id>/`, where `service_id` is derived from the deployed domain. It also writes MCP client snippets under `~/.direxio/nodes/<service_id>/mcp/` for MCP-capable hosts such as Codex, OpenClaw, and Hermes. It does not write root-level compatibility credentials, shell profiles, Windows user environment variables, or mutate each host's global MCP config.

```bash
DIREXIO_DOMAIN=https://<DOMAIN>
DIREXIO_AGENT_TOKEN=<agent_token>
DIREXIO_AGENT_ROOM_ID=<agent_room_id>
DIREXIO_AGENT_NODE_ID=<agent_node_id>
```

Post-deploy agent wiring is controlled by:

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_CC_CONNECT_AGENT=<optional connect agent>
DIREXIO_OPENCLAW_ACP_URL=<optional explicit OpenClaw gateway URL>
DIREXIO_OPENCLAW_ACP_TOKEN_FILE=<optional explicit OpenClaw gateway token file>
DIREXIO_OPENCLAW_ACP_SESSION=<optional OpenClaw ACP session; defaults to agent:main:main>
DIREXIO_AGENT_INSTALL=recommend
DIREXIO_AGENT_INSTALL_MODE=recommended
```

The only supported local conversation bridge is `direxio-connect`, installed from `direxio-connent@latest` by default or built from `https://github.com/YingSuiAI/direxio-connect.git`. S6 creates a Matrix session for `@agent:<server>`, writes `~/.direxio/nodes/<service_id>/cc-connect/config.toml`, and restricts the bridge to the real `agent_room_id`.

The local MCP tool surface is `direxio-mcp`, installed from `direxio-mcp@latest` by default. S6 writes `mcp/codex.toml`, `mcp/openclaw.md`, `mcp/openclaw-server.json`, `mcp/hermes.mcp.json`, `mcp/mcp-servers.json`, and `mcp/env`; these artifacts point to `credentials.json` by `DIREXIO_CREDENTIALS_FILE`. OpenClaw must be configured through the generated `openclaw mcp set` command in `mcp/openclaw.md`; do not paste MCP JSON into `~/.openclaw/openclaw.json`. Keep this separate from cc-connect: cc-connect must use its direct Matrix config and must not use `DIREXIO_CREDENTIALS_FILE`.

`DIREXIO_CC_CONNECT_AGENT` is the preferred explicit selector. Supported values match connent/connect: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`. Detected OpenClaw and Hermes runtimes map to `cc_connect_agent=acp`; they are not native connect agent types. OpenClaw uses `cmd = "openclaw"` with args `["acp", "--session", "agent:main:main"]` by default, letting `openclaw acp` auto-discover the Gateway from `~/.openclaw/openclaw.json`. If the operator needs to force explicit Gateway settings, S6 requires all three real values from the current OpenClaw runtime after pairing: `DIREXIO_OPENCLAW_ACP_URL`, `DIREXIO_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXIO_OPENCLAW_ACP_SESSION`; do not guess these values or reuse old chat output. Hermes uses `cmd = "direxio-connect"` with `args = ["hermes-acp-adapter", "--", "hermes", "acp"]` so the Direxio compatibility layer can suppress Hermes reasoning text before it reaches the Matrix room. Use `DIREXIO_CC_CONNECT_AGENT_CMD`, `DIREXIO_<AGENT>_COMMAND`, and when needed `DIREXIO_CC_CONNECT_AGENT_OPTIONS_TOML` for agent-specific launch details. OpenClaw and Hermes also accept `DIREXIO_OPENCLAW_COMMAND`, `DIREXIO_HERMES_COMMAND`, `DIREXIO_HERMES_ACP_ADAPTER_COMMAND`, `DIREXIO_OPENCLAW_ACP_ARGS_TOML`, and `DIREXIO_HERMES_ACP_ARGS_TOML`; Hermes custom args are child Hermes args and S6 prefixes the adapter wrapper automatically.

`DIREXIO_AGENT_PLATFORM` describes the host runtime following the skill, while `DIREXIO_CC_CONNECT_AGENT` describes the local agent backend that `direxio-connect` should launch. Host runtimes such as Hermes or OpenClaw are not native cc-connect backend types; S6 maps them to the generic ACP backend by default and records `cc_connect_agent=acp`. Override `DIREXIO_CC_CONNECT_AGENT` only when the operator intentionally wants a different local backend.

`DIREXIO_AGENT_INSTALL` may be `skip`, `recommend`, or `auto`. Only `auto` attempts to run `npm install -g direxio-connent@latest` and `direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --service-name <service_id> --force`; the default `recommend` records and prints the command without mutating local daemon state. An automatic install is reported as installed only when `direxio-connect daemon status --service-name <service_id>` returns `Status: Running` and recent daemon logs do not show ACP session initialization failure; otherwise S6 records `agent_install_status=install_failed`. S6 calls `agent.matrix_session.create` with `agent_token` and retries transient HTTP 000/404/408/409/425/429/5xx responses before failing, because the Matrix action can become reachable after `/healthz`; defaults are 12 attempts with exponential backoff capped by `DIREXIO_MATRIX_SESSION_RETRY_MAX_INTERVAL`.

Voice input is supported through `direxio-connect` speech-to-text. When `DIREXIO_SPEECH_API_KEY` or a provider-specific key such as `DIREXIO_SPEECH_QWEN_API_KEY`, `OPENAI_API_KEY`, `GROQ_API_KEY`, `DASHSCOPE_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY` is present, S6 writes `[speech] enabled = true` into the generated config. Without an STT key, do not claim voice input is enabled.

## Product Completion Gates

S7 green is not the final product-complete state. S7 proves the deployed server
passed automated infrastructure and API checks; it does not prove the user has
initialized the App or that the current agent runtime has discovered and used
the local MCP tools.

For a new deployment, the product completion state requires all of these gates:

1. The user receives the app domain and the eight-digit app initialization code.
   The backend stores this value in the `password` field; user-facing delivery
   must call it an initialization code, not a password.
2. The user can enter the domain and eight-digit app initialization code in the
   App, enter the initialization flow, and complete initialization.
3. The local `direxio-connect` bridge is wired to the real `agent_room_id` for
   the selected service under `~/.direxio/nodes/<service_id>/`.
4. MCP snippets for the selected service exist under
   `~/.direxio/nodes/<service_id>/mcp/`, and `direxio-mcp doctor --json`
   succeeds with `DIREXIO_CREDENTIALS_FILE` pointing at that service's
   `credentials.json`.
5. Agent/MCP validation is non-polluting by default: prefer `direxio-mcp
   doctor`, tool discovery, read-only backend calls, and runtime/channel probes.
   Do not auto-send a normal chat message as a deployment test. If the user
   wants a real chat experience check, ask the user to send the test message
   from the App or agent chat box.

Delivery reports must separate automated gates from user-confirmed gates. If
the App initialization or real chat experience has not yet been confirmed, say
that explicitly instead of declaring the whole product deployment complete.
After S6 writes MCP snippets, record the non-polluting MCP doctor evidence with:

```bash
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify runtime
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify connect_daemon
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify mcp_doctor
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify mcp_tools
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh verify mcp_smoke
```

Use `verify runtime` as the normal aggregate check. It runs MCP doctor, MCP
`tools/list`, and read-only backend smoke. It also runs the service-scoped
connect daemon check when the daemon was expected to be installed; when S6
recorded `agent_install_status=recommend` or `skip`, the aggregate marks
`runtime_checks.connect_daemon.status=manual_pending` and does not fail the
summary for that explicit operator action. The individual commands are useful
when diagnosing one layer. These commands write `runtime_checks.connect_daemon`,
`runtime_checks.mcp_doctor`, `runtime_checks.mcp_tools`, and
`runtime_checks.mcp_smoke` into `state.json` and the operation report.
`connect_daemon` verifies that `direxio-connect daemon status --service-name
<service_id>` is `Running` and that its `WorkDir` matches this service's
`~/.direxio/nodes/<service_id>/cc-connect` directory, so another node's daemon
cannot be mistaken for the current deployment. `mcp_tools` starts the
configured MCP stdio server and records MCP `tools/list` discovery.
`mcp_smoke` uses the current `agent_token` and `agent_room_id` to call the
read-only backend action `mcp.messages.list` with `limit=1`; it must not send a
chat message. These checks do not by themselves confirm the full
`agent_mcp_runtime` product gate; the selected runtime or channel probe is
still required before confirming that gate.
When the user later confirms a manual gate, write that confirmation back to the
service state before regenerating the operation report:

```bash
DIREXIO_CONFIRM_EVIDENCE="user completed app initialization" \
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm app_initialization

DIREXIO_CONFIRM_EVIDENCE="user sent a message and saw the agent reply" \
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm real_chat

DIREXIO_CONFIRM_RUNTIME_PROBE=1 \
DIREXIO_CONFIRM_EVIDENCE="MCP doctor/tool discovery and runtime probe confirmed" \
DOMAIN=<DOMAIN> bash scripts/orchestrate.sh confirm agent_mcp_runtime
```

Only record a gate after the user or runtime evidence actually proves it. Do
not mark `real_chat` confirmed from a non-polluting internal probe alone. Every
`confirm` command requires `DIREXIO_CONFIRM_EVIDENCE`; do not let the script
write a manual gate with a generic default evidence string. The evidence note
must be concrete and at least 12 characters; avoid placeholders such as `ok`,
`yes`, or `done`.
`agent_mcp_runtime` confirmation is intentionally stricter: first run
`verify runtime` until `runtime_checks.summary.status` is `passed`, then set
`DIREXIO_CONFIRM_RUNTIME_PROBE=1` only after the selected runtime/channel probe
has actually seen the service-scoped MCP tools.

## Core Rule

Deploy only to a real, long-lived domain. Matrix `server_name` is identity; changing it later is effectively a new homeserver with new accounts, rooms, federation identity, TURN realm, and client configuration.

Do not deploy until the user explicitly confirms:

```bash
DOMAIN=<final-domain>
DOMAIN_MODE=user
CONFIRM_DOMAIN_BINDING=1
```

Use `DOMAIN_MODE=route53` when the user confirms AWS may manage the domain's
A record through Route53. S3 reuses a matching hosted zone or creates one and
records `route53_zone_id`, `route53_zone_name`, `route53_name_servers`, and
whether the zone was deployer-created. If the domain is registered at another
provider, the user or provider-specific automation must delegate the recorded
NS nameservers before authoritative DNS can resolve. Never use temporary
`sslip.io`, IP-derived, localhost, wildcard, or disposable domains.

## Deployment Flow

1. Complete the Cloud Account And Domain Onboarding gate above for first-time users or whenever AWS credentials, domain ownership, or DNS authority are unclear.
2. Read `references/tooling.md`; inspect the user OS and install or prepare missing `bash`, `node`, `aws`, `ssh`, `scp`, `curl`, and DNS lookup capability only after approval.
3. Inspect DNS, AWS credentials, region defaults, local tooling, and existing deployment state before asking the user anything that can be discovered automatically.
   **DNS tool preflight:** Before any DNS propagation or Route53 delegation
   check, confirm the environment has at least one working DNS lookup path:
   `dig`, `nslookup`, Windows PowerShell `Resolve-DnsName`, or `getent`.
   Prefer an existing tool. If no DNS lookup tool is available, ask before
   installing the OS package from `references/tooling.md` (`dnsutils`,
   `bind-utils`, or `bind-tools`), or use the platform fallback. Do not treat
   "dig is missing" as DNS failure; fix the missing tool or use a fallback,
   then rerun the same deployment step.
   **Multi-domain state check:** Before finalising the domain, scan for existing
   nodes across all domains to avoid deploying the same domain twice or
   colliding with an active node:

   ```bash
   # Check local deploy state for any active/in-progress deployment
   bash scripts/orchestrate.sh status
   DOMAIN=<DOMAIN> bash scripts/orchestrate.sh status

   # Check Route53 A records to see which domains already have a server
   for zid in $(aws route53 list-hosted-zones --query "HostedZones[].Id" --output text); do
     zone_name=$(aws route53 list-hosted-zones --query "HostedZones[?Id=='$zid'].Name" --output text)
     a_rec=$(aws route53 list-resource-record-sets --hosted-zone-id "$zid" --query "ResourceRecordSets[?Type=='A'].{Name:Name,Value:ResourceRecords[0].Value}" --output json)
     echo "$zone_name -> A=$a_rec"
   done
   ```

   If the chosen domain already has an A record pointing to a different IP,
   or has a local node directory under `~/.direxio/nodes/`, warn the user
   and suggest using a different domain or destroying the existing deployment
   first. If the user intentionally wants this deployment to replace the old A
   record, record the old value and require `DIREXIO_CONFIRM_DNS_OVERWRITE=1`
   before continuing. If the domain was deployed multiple times recently, warn
   about Let's Encrypt rate limits (max 5 certificates per domain per 7 days).
4. Present one complete deployment configuration and request one consolidated confirmation covering the final domain and irreversible binding, DNS mode, AWS region and billing, credentials source, instance type, message-server image, required installs, and existing-state action.
5. Apply the approved existing-state action for `${DIREXIO_HOME:-$HOME/.direxio}/nodes/<service_id>/state.json`: continue, destroy, or use a different domain/service directory.
6. Run `scripts/orchestrate.sh` with the confirmed environment. Let the state machine own AWS calls, state, polling, cloud-init, token/password handling, verification, and destroy behavior.
   **Credential freshness:** The synced `password` and owner `access_token`
   are one-time/volatile values. User login or token exchange can reset them
   on the server. Before reporting the eight-digit app initialization code or using an owner
   `access_token` for owner API calls, or using `agent_token` for
   `agent.matrix_session.create`, rerun the credential sync path or pull the
   latest `/opt/p2p/bootstrap.json` from the server; do not reuse values from
   old chat output, old `state.json`, or stale local `credentials.json`.
   **Runtime detection note:** S6 checks active-process signals before stale
   config directories, so current-session markers, environment variables, and
   process names win over historical runtime directories. If a session still
   appears ambiguous, set `DIREXIO_AGENT_PLATFORM=<runtime>` or
   `DIREXIO_CC_CONNECT_AGENT=<agent>` explicitly before deployment. For
   OpenClaw and Hermes, prefer `DIREXIO_AGENT_PLATFORM=openclaw|hermes` so S6
   keeps the ACP-backed defaults. Also see
   `references/windows-deployment-notes.md`.
   **Route53 delegation note:** If S3 creates a hosted zone for a domain that is
   registered at Alibaba, GoDaddy, Cloudflare, or another non-Route53 registrar,
   report the recorded NS nameservers and wait for registrar delegation or
   provider API automation. The hosted zone and public IPv4 may bill while DNS
   is waiting, and destroy will try to delete deployer-created hosted zones.
   **⚠️ Let's Encrypt certificate rate limit:** A single domain can get at most
   5 certificates per 7 days (504 hours). If the chosen domain has been
   deployed and destroyed repeatedly within the past week, S4 will fail with
   `healthz did not return 200 before timeout` because Caddy cannot issue a new
   cert. Before running, check the domain's recent cert history by inspecting
   Caddy data on an existing EC2 instance, or simply choose a domain that has
   not been deployed recently. See `references/deployment-workflow.md` → "S4
   Bootstrap Timeout / Certificate Rate Limit Recovery" for recovery steps.
7. For `DOMAIN_MODE=user`, pause when the script emits an Elastic IP and ask the user to set:
   ```text
   <DOMAIN>  A  <PUBLIC_IP>
   ```
   This is a fallback when no DNS provider automation is available. For
   `DOMAIN_MODE=route53` where NS delegation was just changed or the hosted
   zone was just created, DNS propagation of the new nameservers is required
   before the script can verify the A record.

8. After authoritative DNS resolves, rerun the same command with `DNS_READY=1`.
9. After S7 passes, read `references/runtime-wiring.md` and `references/agent-targets.md`, then report the app domain, eight-digit app initialization code, automated gate status, user-confirmation gates still pending, agent token status, real `agent_room_id`, persistent Direxio env status, cc-connect config path, MCP config paths, Matrix bridge user/device, resources, SSH command, state path, and stop-billing guidance that tells the user to ask the agent to destroy the node when finished. Do not treat S7 green as final product completion unless App initialization and agent/MCP runtime confirmation are also recorded.
10. Read the selected connect agent from S6 state (`cc_connect_agent`) and report the recorded `agent_install_command` and `agent_install_status`. For OpenClaw or Hermes, also report that the detected host runtime is ACP-backed and `cc_connect_agent` is expected to be `acp`. If `DIREXIO_AGENT_INSTALL=auto` was explicitly set, treat the daemon as installed only when S6 recorded `agent_install_status=installed`; `install_failed` means the daemon command failed, status was not `Running`, or recent logs reported ACP session initialization failure. Otherwise leave installation as an explicit operator action.

## Status And Recovery

When a deployment is waiting or failed, run `bash scripts/orchestrate.sh status`
for the current service before giving advice. The status output includes a
`Recovery summary` that must be reflected in user-facing language:

- Where it is blocked: the current S0-S7 phase and its plain-language meaning.
- Billing impact: whether EC2, public IPv4/EIP, or EBS resources are recorded
  and may still be billing.
- Resume safety: whether rerunning the same command is safe, or whether the
  operator must preserve `state.json` and continue with
  `P2P_EXISTING_STATE_ACTION=continue`.
- Local refresh: if `agent_install_status=refresh_pending`, update/reset
  cleared old credentials, user confirmations, runtime checks, and bridge
  install proof; the next action is to rerun the deployment workflow to refresh S4-S7, local credentials, MCP snippets, and runtime checks.
- Next action: the concrete diagnostic or user action for the current phase.
- Stop-loss: whether no cloud destroy is needed yet, or how to ask the agent to
  run destroy / run `scripts/destroy.sh` on POSIX or `.\scripts\destroy.ps1` on
  Windows PowerShell.

Do not tell a nontechnical user only that a phase failed. Translate the recovery
summary into current status, cost impact, resumability, next action, and
stop-loss. Do not recommend deleting or resetting state after S3 unless the
recorded AWS resources have been destroyed or deliberately preserved.

## Operation Reports

Every operation must produce a short user-facing explanation and, when state is
available, a machine-readable `operation-report.json` with redacted fields.
Reports must never include the eight-digit initialization code, AWS secrets,
`access_token`, `agent_token`, Matrix session access tokens, or full credential
values. Because users may paste an initialization code into confirmation
evidence, report generation also redacts eight-or-more digit numeric strings
from user/runtime evidence text.

Current script support:

- `new_deploy`: `scripts/orchestrate.sh` writes
  `~/.direxio/nodes/<service_id>/operation-report.json` after S7 and also
  supports `bash scripts/orchestrate.sh report new_deploy`.
- `destroy`: `scripts/destroy.sh` writes
  `~/.direxio/reports/<service_id>/operation-report.json`, because the service
  directory under `~/.direxio/nodes/<service_id>/` is normally removed. The
  destroy report must include `destroy.evidence` from AWS read-back checks for
  the EC2 instance, EBS root volume, Elastic IP, security group, key pair,
  Route53 A record, and deployer-created hosted zone.
- `repair_or_verify`, `update`, and `reset_app_data`: `bash
  scripts/orchestrate.sh report <operation>` can generate a redacted report
  from current state.
- User-confirmed gates can be written with `bash scripts/orchestrate.sh confirm
  app_initialization`, `bash scripts/orchestrate.sh confirm real_chat`, and
  `bash scripts/orchestrate.sh confirm agent_mcp_runtime`; regenerate the
  report afterwards.

The report records operation type, status, S0-S7 automated gates, user
confirmation gates, `gates.user_confirmation_details`, service-scoped
credential/config paths, cc-connect/MCP metadata, AWS resource IDs, billing
reminders, `billing.cost_estimate`, destroy read-back evidence when applicable,
`billing.destroy_cleanup_status`, `billing.possible_remaining_billable_resources`,
and secret-redaction evidence. It also records local refresh state:
`credentials.status`, `connect.install_status`, and `mcp.status` must show
`refresh_pending` after update/reset until S5/S6/S7 and runtime verification
write fresh evidence. User confirmation evidence is redacted before it is
written to the operation report, so initialization codes and tokens are not
copied into handoff artifacts.
If a destroy report lists possible remaining billable resources, tell the user
that AWS Console/Billing is the source of truth and continue cleanup instead of
claiming teardown is finished. Use the report as the Agent/maintainer handoff artifact.
The ordinary user explanation should still be shorter and say what the user can
do next.

## Destroy Flow

Use `scripts/destroy.sh` for teardown on POSIX shells and `.\scripts\destroy.ps1` from PowerShell on Windows. The Windows wrapper selects Git for Windows Bash for the Bash state machine, sets Windows-compatible local path mode, and converts explicit Windows state paths before invoking `scripts/destroy.sh`. Destroy first checks `direxio-connect daemon status --service-name <service_id>` and stops plus uninstalls only that named daemon when the reported `WorkDir` matches the current service directory, `~/.direxio/nodes/<service_id>/cc-connect`. After AWS resources are terminated and released, destroy reads AWS back and records `destroy.evidence` before removing the corresponding local service directory under `~/.direxio/nodes/<service_id>`. This prevents stale state, credentials, bridge files, and stale local service registrations from blocking or misleading the next deployment while still preserving a reportable AWS cleanup audit trail. It leaves unrelated node credential directories intact.

Before running destroy, warn the user that this is not merely "turning off the
server." Destroy removes the recorded cloud node and its application data. The
current app account, friends, channels, messages, Agent room/session, and login
state will no longer be usable. If the user later deploys again, even with the
same domain, treat it as a new Direxio node that needs a fresh app
initialization code, new account setup, new friends, and new channels.

For ordinary users, distinguish the available destructive levels before asking
for confirmation:

- Update deployment: keep accounts, friends, channels, messages, DNS, TLS, and
  cloud resources; only refresh the service image and local credentials.
- Reset app data: keep EC2, public IP, DNS, and TLS storage, but delete app
  accounts, friends, channels, messages, and Agent room state.
- Destroy resources: delete the recorded EC2/EBS/EIP/security group/key pair,
  remove the deployer-managed DNS A record, stop the local bridge, and make the
  current app data unavailable.

Require an explicit destructive confirmation before destroy when the user has
not already clearly confirmed this data loss. A suitable confirmation is:

```text
I confirm destroying this Direxio node and understand the current account,
friends, channels, messages, and Agent conversation will be lost; redeploying
later will create a new node/account.
```

Destroy uses the same AWS identity boundary as deployment: root AWS access-key
identity is allowed when the operator explicitly chose root credentials. Prefer
using the same temporary `DirexioDeployer` IAM user/profile for teardown when
that was used for provisioning.

If an operator needs to preserve local state files for debugging, run destroy with `P2P_KEEP_WORKDIR=1` and explicitly report that the stale service directory remains.

### Full reset / "treat me as a brand new user"

When the user asks for a complete fresh start — "destroy everything", "start over from zero", "treat me as a brand new user" — running `scripts/destroy.sh` alone is **not sufficient**. The destroy script only handles infrastructure and local service directory cleanup. The agent should also clear any runtime-supported persistent memory about the old deployment. Specifically:

1. **Run `scripts/destroy.sh` first** (infra teardown).
2. **Clear agent memory entries only through capabilities available in the current runtime.** If the runtime provides an explicit memory-management tool, remove entries referencing the old domain, deployment URLs, credentials, passwords, tokens, node IDs, room IDs, service IDs, AWS account info, cc-connect config paths, and skill install/update history. If no such capability exists, say that memory cleanup cannot be automated in this runtime and avoid inventing tool calls.
3. **Verify runtime-specific memory stores only when they are known and accessible.** Use the current agent's native memory/config mechanism if exposed; otherwise report the limitation.
4. **Then start from Step 1** of the Cloud Account And Domain Onboarding section — ask about AWS account first, don't assume anything carried over.

> ⚠️ Do not skip step 2. Stale credentials (URLs, passwords, tokens) in agent memory can leak into the new deployment's Delivery report or cause the agent to skip onboarding steps by referencing facts that no longer apply. A true fresh start requires both infra cleanup **and** agent memory cleanup.

## Image Refresh And Data Reset

When the user only asks to pull a newer image on an existing EC2 instance, do not destroy cloud resources and do not delete application or TLS storage. Run `scripts/update.sh` against the current state. It SSHes to the existing node, optionally updates `MESSAGE_SERVER_IMAGE`, runs Docker Compose pull/up, reruns `/opt/p2p/init-tokens.sh`, clears stale local secret fields, clears old user-confirmation/runtime-check evidence, marks `agent_install_status=refresh_pending`, stops only the matching service-scoped direxio-connect daemon when its `WorkDir` matches this service, marks S4-S7 pending, and writes a redacted `operation-report.json`.

When the user asks to reset application data on an existing EC2 instance, do not destroy EC2, public IPv4/EIP, DNS, or Caddy TLS storage. Run `scripts/reset-app-data.sh` only after explicit destructive confirmation with `DIREXIO_RESET_APP_DATA_CONFIRM=1`. It clears only the application volumes (`postgres-data`, `message-config`, `message-data`), generates a new backend password/init-code field, restarts the stack, reruns `/opt/p2p/init-tokens.sh`, clears stale local secret fields, clears old user-confirmation/runtime-check evidence, marks `agent_install_status=refresh_pending`, stops only the matching service-scoped direxio-connect daemon when its `WorkDir` matches this service, marks S4-S7 pending, and writes a redacted `operation-report.json`.

Current message-server images require `P2P_PORTAL_PASSWORD` and an explicit `portal.bootstrap`; `init-tokens.sh` owns that cloud-side bootstrap and creates a real Matrix `agent_room_id` when the backend credentials file does not already include one.

Do not delete caddy-data or caddy-config during an image-only refresh. Removing Caddy's ACME storage loses the existing production certificate and can trigger CA duplicate-certificate rate limits. Preserve `caddy-data` and `caddy-config`; clear only `postgres-data message-config message-data` when the requested reset needs a clean homeserver/database.

For repeated test refreshes, rerun `scripts/orchestrate.sh` normally after update/reset. S4-S7 will re-run from state, and S6 only rewrites local credentials and environment files unless `DIREXIO_AGENT_INSTALL=auto` is explicitly set.

## Minimal Invocation

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

Use an `AWS_PROFILE` or temporary `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for the selected AWS identity. Root access keys are allowed when the operator explicitly chooses them; a temporary `DirexioDeployer` IAM user remains the recommended routine path. Do not write AWS secrets, initialization codes, or agent tokens into skill files or the repository.

On Windows, prefer `.\scripts\orchestrate.ps1` and `.\scripts\destroy.ps1` from PowerShell. These wrappers select Git for Windows Bash for the Bash phases and write Windows-compatible local `direxio-connect` paths.

## Required Confirmation

Ask once, plainly and in the user's language. The confirmation message must summarize:

- Domain binding: `CONFIRM_DOMAIN_BINDING=1`.
- DNS mode: `user` or `route53`.
- AWS region and billable resources: EC2, Elastic IP, security group, EBS, network egress, TURN traffic.
- Instance type: default `t3.small`.
- Message-server image: default `direxio/message-server:latest`; override with `MESSAGE_SERVER_IMAGE`.
- AWS credentials source, including whether root access keys are being used.
- AWS/domain onboarding status: active AWS account, real long-lived domain, access key CSV or AWS profile, DNS authority, and billing/deletion acknowledgement.
- Existing state action: `continue`, `destroy`, or different `DOMAIN`/service directory.
- Network/system installs: package managers, Node.js, AWS CLI, Git Bash/MSYS2/WSL, Homebrew, apt/dnf/yum/pacman/zypper.

After the user confirms the summary, proceed without re-confirming individual fields. Ask again only when the configuration materially changes, an unapproved destructive action becomes necessary, or an external action such as DNS must be completed by the user.

## Delivery

After S7 passes, report:

```text
App domain   : <DOMAIN>
init code    : <eight-digit app initialization code>
product gate : S7 green; App initialization and real chat confirmation are user-confirmed gates
agent_node_id: <agent_node_id>
service_id   : <service_id>
service_dir  : ~/.direxio/nodes/<service_id>
agent_token  : written to ~/.direxio/nodes/<service_id>/credentials.json
agent_room_id: written to ~/.direxio/nodes/<service_id>/credentials.json
env vars      : DIREXIO_DOMAIN, DIREXIO_AGENT_TOKEN, DIREXIO_AGENT_ROOM_ID, DIREXIO_AGENT_NODE_ID persisted
connect pkg   : direxio-connent@latest
connect agent : <cc_connect_agent>
connect config: <cc_connect_config>
connect user  : <cc_connect_matrix_user>
connect device: <cc_connect_matrix_device>
agent command : <cc_connect_agent_cmd or default PATH lookup>
install mode  : policy=<skip|recommend|auto> mode=<cc-connect> status=<...>
install cmd   : <agent_install_command>
mcp pkg       : direxio-mcp@latest
mcp server    : <mcp_server_name>
mcp config dir: <mcp_config_dir>
mcp codex     : <mcp_codex_config>
mcp openclaw  : <mcp_openclaw_config>
mcp hermes    : <mcp_hermes_config>
mcp install   : <mcp_install_command>
mcp doctor    : <mcp_doctor_command>
skill clone   : <agent_skill_install_path>
AWS region   : <region>
EC2          : <instance-id> (<public-ip>)
SSH          : ssh -i <key-file> ubuntu@<public-ip>
state.json   : <state path>
stop billing : ask the agent to destroy this node when finished
security     : delete or disable any temporary DirexioDeployer access key after deployment; rotate/remove root access keys if used
report       : <operation-report.json path>
```

Mention that AWS resources keep billing until destroyed. User-managed DNS and purchased domains are not removed by destroy. After destroy, report which `~/.direxio/nodes/<service_id>` service directory was removed or, if `P2P_KEEP_WORKDIR=1` was used, which local directory remains.

If `DIREXIO_AGENT_INSTALL=auto` was not used, or if it recorded `install_failed`, give the manual command:

```bash
npm install -g direxio-connent@latest
direxio-connect daemon install --config <cc_connect_config> --service-name <service_id> --force
direxio-connect daemon status --service-name <service_id>
```

For MCP-capable hosts, also give the recorded MCP command and snippet paths:

```bash
npm install -g direxio-mcp@latest
DIREXIO_CREDENTIALS_FILE=<mcp_credentials_file> direxio-mcp doctor --json
```

## References

- Tool setup by OS: `references/tooling.md`
- Agent-specific skill and cc-connect targets: `references/agent-targets.md`
- Deployment and resume workflow: `references/deployment-workflow.md`
- Runtime and agent wiring: `references/runtime-wiring.md`
- Verification and recovery: `references/verification-recovery.md`
- State machine details: `references/state-machine.md`
- Architecture and troubleshooting: `references/architecture.md`, `references/troubleshooting.md`
- Windows deployment notes: `references/windows-deployment-notes.md` — bash prerequisites, credential setup, direxio-connect install checks, background-buffer notes, and Route53 DNS tips for Git Bash / Windows 10+.
