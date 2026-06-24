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

Use `DOMAIN_MODE=route53` only when the domain is in Route53 and the user confirms AWS may manage the A record. Never use temporary `sslip.io`, IP-derived, localhost, wildcard, or disposable domains.

## Deployment Flow

1. Read `references/tooling.md`; inspect the user OS and install or prepare missing `bash`, `aws`, `jq`, `ssh`, `scp`, and `curl` only after approval.
2. Inspect DNS, AWS credentials, region defaults, local tooling, and existing deployment state before asking the user anything that can be discovered automatically.
3. Present one complete deployment configuration and request one consolidated confirmation covering the final domain and irreversible binding, DNS mode, AWS region and billing, credentials source, instance type, message-server image, required installs, and existing-state action.
4. Apply the approved existing-state action for `${P2P_WORKDIR:-$HOME/.direxio/deploy}/state.json`: continue, destroy, or use a new workdir.
5. Run `scripts/orchestrate.sh` with the confirmed environment. Let the state machine own AWS calls, state, polling, cloud-init, token/password handling, verification, and destroy behavior.
6. For `DOMAIN_MODE=user`, pause when the script emits an Elastic IP and ask the user to set:

```text
<DOMAIN>  A  <PUBLIC_IP>
```

7. After authoritative DNS resolves, rerun the same command with `DNS_READY=1`.
8. After S7 passes, read `references/runtime-wiring.md` and `references/agent-targets.md`, then report the URL, `password`, agent token status, `agent_room_id`, persistent Direxio MCP/plugin env status, runtime-specific target paths, resources, SSH command, state path, and destroy command.
9. Detect the current agent runtime from S6 state (`agent_runtime`) and the active environment. If `DIREXIO_AGENT_INSTALL=auto` was explicitly set, S6 may run the detected install command. Otherwise ask the user whether to automatically install/configure the Direxio plugin and MCP service for that runtime. Do not mutate Codex, Claude Code, Gemini, Cursor, Copilot, OpenClaw, Hermes, or other agent config without explicit post-deploy confirmation or `DIREXIO_AGENT_INSTALL=auto`.

## Destroy Flow

Use `scripts/destroy.sh` for teardown. After AWS resources are terminated and released, destroy removes the corresponding local deploy workdir under `~/.direxio` so stale state cannot block or mislead the next deployment. It leaves unrelated node credential directories intact.

If an operator needs to preserve local state files for debugging, run destroy with `P2P_KEEP_WORKDIR=1` and explicitly report that the stale workdir remains.

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
