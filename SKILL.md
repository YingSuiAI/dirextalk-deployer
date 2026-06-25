---
name: direxio-deployer
description: Deploy, resume, verify, destroy, and locally wire a production P2P-IM Matrix server on AWS for Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, and other agent runtimes. Use when installing or updating this skill itself; if a current project or workspace exists, prefer the runtime-specific project-local Git clone path from references/agent-targets.md and use global skill directories only when no project target exists or the user explicitly asks for global installation.
---

# Direxio Deployer

This skill is the agent-facing deployment runbook for a production Direxio message server. It combines user confirmation, local tool checks, AWS provisioning, DNS waiting, service bootstrap, credential delivery, local agent wiring, verification, and teardown.

Agents should treat this repository root as the execution engine. The runnable entrypoints are:

```text
scripts/orchestrate.sh
scripts/destroy.sh
```

## Skill Freshness Gate

Before following this local Skill for deployment, repair, verification,
teardown, or runtime wiring, make one freshness attempt against the canonical
source:

```text
https://github.com/YingSuiAI/direxio-deployer/blob/main/SKILL.md
```

If this Skill is running from a Git clone whose origin is
`YingSuiAI/direxio-deployer`, fetch `origin main` and compare the local HEAD
with `origin/main`. Fast-forward only when it is safe and does not overwrite
local edits. If the clone has local changes, do not discard them; report the
divergence and continue from the local copy unless the user approves a specific
update action.

If this Skill is not running from that Git clone, read the canonical `SKILL.md`
URL once and use it as the latest deployment guidance when reachable. If GitHub
or the private repository is unreachable, say so briefly and continue with this
local copy.

Do not fall back to older P2P-IM skill repositories, copied skill bundles, or
`Public-skills-and-mcp` unless the user explicitly asks for one of those
repositories. Never print or commit AWS credentials, IM passwords, agent tokens,
or local credential files while refreshing the Skill.

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

2. **Access key file.**
   - Ask: "Do you already have an AWS access key CSV file for deployment?"
   - If yes, ask only for the local file path.
   - If no, guide them through creating one with specific step-by-step
     instructions. Do NOT say "go create one" — tell them exactly what to
     click. Example for a root access key:
     1. Open `https://console.aws.amazon.com/iam/` and sign in as root user.
     2. Click the account name (top-right) → **Security credentials**.
     3. Scroll to **Access keys (access key ID and secret access key)**.
     4. Click **Create access key**.
     5. In the dialog, select **Root user access key** → acknowledge the
        warning → **Create access key**.
     6. Click **Download .csv file** to save the credentials file.
     7. Return the local file path to the agent.
   - For a dedicated IAM deployment user (recommended over root):
     1. User opens `https://console.aws.amazon.com/iam/` → **Users** →
        **Create user** with name like `p2p-matrix`.
     2. Attach the policy from `references/iam-policy.json` (or `AdministratorAccess` for simplicity).
     3. **Create user** → select the user → **Security credentials** →
        **Create access key** → **Command Line Interface (CLI)** →
        download the CSV.
   - Prefer a dedicated deployment user or role over root access keys. If the
     user insists on root keys, warn: "Root keys have unrestricted access to
     your entire AWS account. Use them only if you understand the risk."
   - If they need a permission policy, point to `references/iam-policy.json`.
     Do not explain the policy line by line unless asked.
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
     4. Return with the domain name, such as `im.example.com` or
        `example.com`.
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
     may create or update the domain's A record.
   - If another provider, use `DOMAIN_MODE=user` by default. Later, when the
     script emits the fixed IP, ask the user to create exactly:

     ```text
     <DOMAIN>  A  <PUBLIC_IP>
     ```

   - **Route53 delegation from another provider** — If the user prefers Route53
     even though the domain is registered elsewhere (Alibaba, GoDaddy,
     Cloudflare, etc.), there is a pre-deployment step before orchestrate.sh:

     1. Create the Route53 hosted zone:
        ```bash
        aws route53 create-hosted-zone --name <DOMAIN> --caller-reference "deploy-$(date -u +%Y%m%d%H%M%S)"
        ```
     2. Extract the 4 NS nameservers from the created zone.
     3. Give them to the user with clear instructions to update the domain's
        NS records at their current DNS provider (e.g. Alibaba Cloud DNS
        console → "修改DNS").
     4. Wait for the user to confirm they made the change.
     5. **Then** proceed to run orchestrate.sh with `DOMAIN_MODE=route53`,
        which will find the now-existing hosted zone and upsert the A record.
        The script's `_find_route53_zone()` function looks up existing zones
        only — it does NOT create one.

   - **Important:** Route53 A record upsert happens during S3_PROVISION, before
     DNS propagation checks. The user must delegate NS FIRST so the hosted zone
     exists before the script runs. Do not run orchestrate.sh before the NS
     delegation is submitted and routed.

5. **Billing confirmation.**
   - Give a short billing warning before the first mutating AWS command:
     "This will create paid AWS resources for the server. They keep billing
     until destroyed."
   - **Provide an upfront monthly cost estimate** based on the selected
     region and instance type, so the user can decide whether to proceed.
     Default estimate (t3.small, us-east-1, ~730 hours/month):

     | Resource | Monthly Cost |
     |---|---:|
     | EC2 t3.small (Linux) | ~$15 |
     | EBS gp3 (8 GB) | ~$0.60 |
     | Elastic IP (when attached) | free |
     | Route53 hosted zone | ~$0.50 |
     | Outbound data (first 100 GB) | free |
     | **Total** | **~$16-17/month** |

     If the user chose a **non-us-east-1 region**, adjust the EC2 rate
      or add a note that prices may vary by region. For t3.small in other
      regions, add roughly +10-30%. To get exact on-demand rates, use:

     ```bash
     aws pricing get-products --service-code AmazonEC2 \
       --filters "Type=TERM_MATCH,Field=instanceType,Value=t3.small" \
                "Type=TERM_MATCH,Field=location,Value=<Region Name>" \
                "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
                "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
                "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       --max-results 1
     ```

     Replace `<Region Name>` with the AWS Pricing API region name
     (e.g. `Asia Pacific (Tokyo)`, `Europe (Frankfurt)`). The on-demand
     hourly rate times 730 gives the approximate monthly CPU cost.
   - If the user asks what is billed, mention EC2/server, fixed IP, storage,
     DNS, network traffic, and call relay traffic.

Required first-time deployment confirmation:

```text
I confirm that I have an active AWS account, a real long-lived domain, and an AWS access key CSV or AWS profile for this deployment. I understand this can create billable AWS resources and that they keep billing until destroyed.
```

If any prerequisite is missing, stop deployment and guide the user through that
specific step before running `scripts/orchestrate.sh`.

## Skill And Runtime Targets

When the user asks to install or update this skill itself, or asks to wire Direxio into a local agent runtime, read `references/agent-targets.md` first. It is the source of truth for Codex, Claude Code, Gemini, Cursor, GitHub Copilot, OpenClaw, Hermes, generic, and unknown targets.

For this skill repository itself, first determine whether the current working directory belongs to a project or workspace. Treat an explicit workspace root, project files, or an existing agent-specific directory such as `.codex/`, `.claude/`, `.gemini/`, `.cursor/`, `.github/copilot/`, `.openclaw/`, or `.hermes/` as a project target.

If a project target exists, install or update this skill as a Git clone at the runtime-specific project-local path from `references/agent-targets.md`. Create the parent directory if needed. Do not use copy-based skill installation for a project-local install because it drops `.git` and prevents normal tracking, `git pull`, and commit inspection. Use global runtime skill directories only when the user explicitly asks for a global install or no project target exists. If a global copy was created by mistake, remove it and replace it with the project-local clone.

## Agent Recognition

Use this skill when the user asks to deploy, resume, verify, destroy, repair, or wire a P2P-IM Matrix server. The instructions are runtime-neutral and can be followed by Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, or another agent that can run shell commands and read files.

For local agent integration after deployment, S6 writes service-specific credentials and environment files under `~/.direxio/nodes/<service_id>/`, where `service_id` is derived from the deployed domain. It does not write root-level compatibility credentials, shell profiles, or Windows user environment variables.

```bash
DIREXIO_DOMAIN=https://<DOMAIN>
DIREXIO_AGENT_TOKEN=<agent_token>
DIREXIO_AGENT_ROOM_ID=<agent_room_id>
DIREXIO_AGENT_NODE_ID=<agent_node_id>
```

The current integration targets are `@direxio/local-mcp` for stdio MCP and `@direxio/agent-plugins` for runtime-specific plugins and gateway binaries.
The gateway in `direxio-agent-plugins` has native send support: it calls `/_p2p/command` action `mcp.messages.send` directly and does not require MCP to send room replies.

Post-deploy agent wiring is controlled by:

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_AGENT_INSTALL=recommend
DIREXIO_AGENT_INSTALL_MODE=recommended
```

`DIREXIO_AGENT_INSTALL` may be `skip`, `recommend`, or `auto`. Only `auto` attempts to run `npx -y -p @direxio/agent-plugins@latest direxio-agent-install --node-id <agent_node_id> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --write`; the default `recommend` records and prints the command without mutating agent config. Gateway installs restart only the process for the same node id; other local Direxio nodes keep running.

## Core Rule

Deploy only to a real, long-lived domain. Matrix `server_name` is identity; changing it later is effectively a new homeserver with new accounts, rooms, federation identity, TURN realm, and client configuration.

Do not deploy until the user explicitly confirms:

```bash
DOMAIN=<final-domain>
DOMAIN_MODE=user
CONFIRM_DOMAIN_BINDING=1
```

Use `DOMAIN_MODE=route53` when the user confirms AWS may manage the domain's
A record through Route53. The domain must have a Route53 hosted zone already
existing (either pre-created by the agent or inherited from prior setup). If
the domain is registered at another provider, the agent must pre-create the
hosted zone, extract NS records, and guide the user to delegate DNS *before*
running orchestrate.sh (see Step 4). Never use temporary `sslip.io`,
IP-derived, localhost, wildcard, or disposable domains.

## Deployment Flow

1. Complete the Cloud Account And Domain Onboarding gate above for first-time users or whenever AWS credentials, domain ownership, or DNS authority are unclear.
2. Read `references/tooling.md`; inspect the user OS and install or prepare missing `bash`, `aws`, `jq`, `ssh`, `scp`, and `curl` only after approval.
3. Inspect DNS, AWS credentials, region defaults, local tooling, and existing deployment state before asking the user anything that can be discovered automatically.
   **Multi-domain state check:** Before finalising the domain, scan for existing
   nodes across all domains to avoid deploying the same domain twice or
   colliding with an active node:

   ```bash
   # Check local deploy state for any active/in-progress deployment
   ls ~/.direxio/nodes/ 2>/dev/null && cat ~/.direxio/deploy/state.json 2>/dev/null | jq '{phase, phases}'

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
   first. If the domain was deployed multiple times recently, warn about
   Let's Encrypt rate limits (max 5 certificates per domain per 7 days).
4. Present one complete deployment configuration and request one consolidated confirmation covering the final domain and irreversible binding, DNS mode, AWS region and billing, credentials source, instance type, message-server image, required installs, and existing-state action.
5. Apply the approved existing-state action for `${P2P_WORKDIR:-$HOME/.direxio/deploy}/state.json`: continue, destroy, or use a new workdir.
6. Run `scripts/orchestrate.sh` with the confirmed environment. Let the state machine own AWS calls, state, polling, cloud-init, token/password handling, verification, and destroy behavior.
   **⚠️ Runtime detection pitfall:** S6 detects the agent runtime by checking directories in a fixed order — `~/.codex` is checked before `~/.hermes`. If `~/.codex` exists from past tool use, the script may mis-detect `codex` even when Hermes is running. **Fix:** pass `DIREXIO_AGENT_PLATFORM=hermes` explicitly when deploying from a Hermes session. Also see `references/windows-deployment-notes.md`.
   **⚠️ Route53 pre-requisite for domains at other registrars:** The script's `_find_route53_zone()` looks up existing hosted zones only — it does NOT create one. If the domain is registered at Alibaba, GoDaddy, Cloudflare, etc. and the user chose Route53 management, the agent must pre-create the hosted zone (see Step 4 DNS control) BEFORE running orchestrate.sh. Do not rely on the script to create the zone.
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
   For `DOMAIN_MODE=route53` where NS delegation was just changed (third-party
   registrar → Route53), DNS propagation of the new nameservers is required
   before the script can verify the A record. The Route53 hosted zone must be
   pre-created and delegated before step 6.

8. After authoritative DNS resolves, rerun the same command with `DNS_READY=1`.
9. After S7 passes, read `references/runtime-wiring.md` and `references/agent-targets.md`, then report the URL, `password`, agent token status, `agent_room_id`, persistent Direxio MCP/plugin env status, runtime-specific target paths, resources, SSH command, state path, and destroy command.
10. Detect the current agent runtime from S6 state (`agent_runtime`) and the active environment. If `DIREXIO_AGENT_INSTALL=auto` was explicitly set, S6 may run the detected install command. Otherwise ask the user whether to automatically install/configure the Direxio plugin and MCP service for that runtime. Do not mutate Codex, Claude Code, Gemini, Cursor, Copilot, OpenClaw, Hermes, or other agent config without explicit post-deploy confirmation or `DIREXIO_AGENT_INSTALL=auto`.

## Destroy Flow

Use `scripts/destroy.sh` for teardown. After AWS resources are terminated and released, destroy removes the corresponding local deploy workdir under `~/.direxio` so stale state cannot block or mislead the next deployment. It leaves unrelated node credential directories intact.

If an operator needs to preserve local state files for debugging, run destroy with `P2P_KEEP_WORKDIR=1` and explicitly report that the stale workdir remains.

### Full reset / "treat me as a brand new user"

When the user asks for a complete fresh start — "destroy everything", "start over from zero", "treat me as a brand new user" — running `scripts/destroy.sh` alone is **not sufficient**. The destroy script only handles infrastructure and local workdir cleanup. The agent must also clear its own persistent memory about the old deployment. Specifically:

1. **Run `scripts/destroy.sh` first** (infra teardown).
2. **Clear agent memory entries** for this deployment:
   - `memory(action='remove', target='memory')` — remove all entries referencing the old domain, deployment URLs, credentials, passwords, tokens, node IDs, room IDs, service IDs, AWS account info, MCP config paths, and the skill install/update history.
   - `memory(action='remove', target='user')` — remove any user profile entries that describe the user's cloud/DNS setup from the prior deployment (the new deployment starts fresh with new onboarding).
3. **Verify** that `~/AppData/Local/hermes/memory.json` (Hermes desktop) or `~/.hermes/memory.json` (CLI) no longer carries stale deployment facts.
4. **Then start from Step 1** of the Cloud Account And Domain Onboarding section — ask about AWS account first, don't assume anything carried over.

> ⚠️ Do not skip step 2. Stale credentials (URLs, passwords, tokens) in agent memory can leak into the new deployment's Delivery report or cause the agent to skip onboarding steps by referencing facts that no longer apply. A true fresh start requires both infra cleanup **and** agent memory cleanup.

## Image Refresh And Data Reset

When the user only asks to pull a newer image or reset application data on an existing EC2 instance, do not destroy cloud resources and do not delete TLS storage. Pull the compose images, stop the stack, remove only the application data volumes, restart, rerun `/opt/p2p/init-tokens.sh`, then reset local S5-S7 state so credentials and verification are refreshed.

Do not delete caddy-data or caddy-config during an image-only refresh. Removing Caddy's ACME storage loses the existing production certificate and can trigger CA duplicate-certificate rate limits. Preserve `caddy-data` and `caddy-config`; clear only `postgres-data message-config message-data` when the requested reset needs a clean homeserver/database.

For repeated test refreshes, rerun `scripts/orchestrate.sh` normally. S6 only rewrites local credentials and environment files unless `DIREXIO_AGENT_INSTALL=auto` is explicitly set.

## Minimal Invocation

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=im.example.com \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

Use `AWS_PROFILE=p2p-matrix` or temporary `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. Do not write AWS secrets, IM passwords, or agent tokens into skill files or the repository.

## Required Confirmation

Ask once, plainly and in the user's language. The confirmation message must summarize:

- Domain binding: `CONFIRM_DOMAIN_BINDING=1`.
- DNS mode: `user` or `route53`.
- AWS region and billable resources: EC2, Elastic IP, security group, EBS, network egress, TURN traffic.
- Instance type: default `t3.small`.
- Message-server image: default `direxio/message-server:latest`; override with `MESSAGE_SERVER_IMAGE`.
- AWS credentials source and any elevated-risk credential choice such as root access keys.
- AWS/domain onboarding status: active AWS account, real long-lived domain, access key CSV or AWS profile, DNS authority, and billing/deletion acknowledgement.
- Existing state action: `continue`, `destroy`, or new `P2P_WORKDIR`.
- Network/system installs: package managers, AWS CLI, jq, Git Bash/MSYS2/WSL, Homebrew, apt/dnf/yum/pacman/zypper.

After the user confirms the summary, proceed without re-confirming individual fields. Ask again only when the configuration materially changes, an unapproved destructive action becomes necessary, or an external action such as DNS must be completed by the user.

## Delivery

After S7 passes, report:

```text
IM URL       : https://<DOMAIN>
password     : <login password>
agent_node_id: <agent_node_id>
service_id   : <service_id>
service_dir  : ~/.direxio/nodes/<service_id>
agent_token  : written to ~/.direxio/nodes/<service_id>/credentials.json
agent_room_id: written to ~/.direxio/nodes/<service_id>/credentials.json
mcp package  : @direxio/local-mcp
plugins pkg  : @direxio/agent-plugins
env vars      : DIREXIO_DOMAIN, DIREXIO_AGENT_TOKEN, DIREXIO_AGENT_ROOM_ID persisted
install mode  : policy=<skip|recommend|auto> mode=<mcp|native|gateway> status=<...>
mcp config    : <agent_mcp_config_path>
skill clone   : <agent_skill_install_path>
target summary: <agent_install_target_summary>
gateway send  : npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "$DIREXIO_AGENT_ROOM_ID" --message "hello"
AWS region   : <region>
EC2          : <instance-id> (<public-ip>)
SSH          : ssh -i <key-file> ubuntu@<public-ip>
state.json   : <state path>
Destroy      : bash scripts/destroy.sh
```

Mention that AWS resources keep billing until destroyed. User-managed DNS and purchased domains are not removed by destroy. After destroy, report which `~/.direxio` deploy workdir was removed or, if `P2P_KEEP_WORKDIR=1` was used, which one remains.

Then ask one concise follow-up in the user's language:

```text
Detected <runtime>. Do you want me to automatically install/configure the Direxio plugin and MCP service for this agent using the persisted DIREXIO_* environment and the recorded runtime target paths?
```

If the user agrees, use the runtime's native configuration path where available. The MCP server command is always:

```text
command: npx
args: ["-y", "@direxio/local-mcp@latest"]
env: DIREXIO_CREDENTIALS_FILE, DIREXIO_AGENT_NODE_ID
```

For OpenClaw and Hermes, prefer native long-process integration. For Claude Code, Cursor, Gemini, and Copilot, use MCP-only unless the user supplies a local command for an external `generic-cli` gateway.

## References

- Tool setup by OS: `references/tooling.md`
- Agent-specific skill and MCP/plugin targets: `references/agent-targets.md`
- Deployment and resume workflow: `references/deployment-workflow.md`
- Runtime and agent wiring: `references/runtime-wiring.md`
- Verification and recovery: `references/verification-recovery.md`
- State machine details: `references/state-machine.md`
- Architecture and troubleshooting: `references/architecture.md`, `references/troubleshooting.md`
- Windows deployment notes: `references/windows-deployment-notes.md` — bash prerequisites, credential setup, MCP arg format, known background-buffer gotcha, and Route53 DNS tips for Git Bash / Windows 10+.
