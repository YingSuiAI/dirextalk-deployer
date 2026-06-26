# Direxio Deployer

[简体中文](README_zh.md)

`direxio-deployer` is a runtime-neutral agent skill for deploying a production Direxio message server. Claude Code, Codex/OpenAI, Gemini, Cursor, GitHub Copilot, OpenClaw, Hermes, and other shell-capable agents can use the same repository to deploy, resume, verify, destroy, and wire a server.

It combines deployment confirmation, cross-platform tooling checks, AWS infrastructure orchestration, DNS waiting, message-server bootstrap, credential delivery, local Direxio MCP/plugin environment setup, runtime-specific target recording, and final verification.

## Contents

- `SKILL.md`: Agent entrypoint, confirmation rules, deployment/destroy flow, and delivery format.
- `scripts/`: State machine, AWS/EC2/DNS/cloud-init/verification/destroy scripts.
- `references/`: Tooling, deployment resume flow, agent target paths, runtime wiring, state machine, architecture, troubleshooting, and recovery notes.
- `agents/`: Runtime metadata and recognition notes for agent hosts.

## Skill Installation

When installing this skill inside an existing project or workspace, prefer a runtime-specific project-local Git clone. For example, Codex uses `PROJECT_ROOT/.codex/skills/direxio-deployer`, Claude Code uses `PROJECT_ROOT/.claude/skills/direxio-deployer`, and Cursor uses `PROJECT_ROOT/.cursor/skills/direxio-deployer`. Do not use copy-based installation for project-local installs because it drops `.git` and prevents normal `git pull`, commit inspection, and local patch tracking.

See `references/agent-targets.md` for the full runtime matrix, global fallbacks, and MCP/plugin configuration targets. Use global skill directories only when no project target exists or the user explicitly asks for a global install.

## Deployment Rules

- Deploy only to a real, long-lived domain.
- Matrix `server_name` is identity; changing it later is effectively a new homeserver.
- AWS resources cost money; the user must explicitly confirm before deployment.
- User-managed DNS mode pauses after Elastic IP creation until the user updates the A record.
- The backend image is `direxio/message-server`; Matrix and P2P APIs share port 8008.
- The backend uses `password` for IM login; local credentials retain `access_token` and agent-specific `agent_token`.
- Public multi-node channel routing is client-provided through target `_p2p` base URLs; the deployer no longer writes a fixed remote-node table.
- After deployment, S6 persists `DIREXIO_DOMAIN`, `DIREXIO_AGENT_TOKEN`, `DIREXIO_AGENT_ROOM_ID`, and `DIREXIO_AGENT_NODE_ID` under the domain-derived `~/.direxio/nodes/<service_id>/`, then records `@direxio/local-mcp`, `@direxio/agent-plugins`, runtime-specific skill clone paths, and node-scoped MCP/config payload targets.
- Post-deploy agent installation is controlled by `DIREXIO_AGENT_INSTALL=skip|recommend|auto`; the default is `recommend`. Only `auto` attempts to run `npx -y -p @direxio/agent-plugins@latest direxio-agent-install --node-id <agent_node_id> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --write`. Gateway mode restarts only the matching node gateway.
- The gateway has native `mcp.messages.send` support through `/_p2p/command`; it does not require `@direxio/local-mcp` for room replies.
- OpenClaw deployments also get a node-scoped `~/.direxio/nodes/<service_id>/openclaw-gateway/start_gateway.sh` helper so passive App-agent replies use `openclaw agent` through a handler instead of a missing packaged OpenClaw plugin.
- Hermes deployments also get a node-scoped `~/.direxio/nodes/<service_id>/hermes-gateway/start_gateway.sh` helper so passive App-agent replies use `hermes -z` through a handler instead of a bare `node` process.

## Minimal Command

Run from the repository root:

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

Recommendation-only post-deploy agent wiring:

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

Automatic post-deploy install/write for the detected agent:

```bash
DIREXIO_AGENT_INSTALL=auto \
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

Supported platforms: `auto`, `codex`, `claude-code`, `gemini`, `cursor`, `copilot`, `openclaw`, `hermes`, `generic`.

Supported install modes: `recommended`, `mcp`, `native`, `gateway`. OpenClaw and Hermes default to `native`; Codex defaults to `gateway`; runtimes without managed local long processes use `mcp`.

Check status:

```bash
bash scripts/orchestrate.sh status
```

Destroy recorded resources:

```bash
bash scripts/destroy.sh
```

## Agent Recognition

Agents should read `SKILL.md` first. Use this skill when the user asks to deploy, resume, debug, verify, destroy, refresh agent credentials, or install Direxio MCP/plugin access.

After deployment, S6 detects the current runtime, such as Codex, Claude Code, Gemini, Cursor, GitHub Copilot, OpenClaw, or Hermes. After S7 passes, the executing agent must ask before automatically installing/configuring Direxio plugin and MCP access for the detected runtime. Non-interactive deployment can opt in with `DIREXIO_AGENT_INSTALL=auto`.

OpenClaw and Hermes should prefer native long-process integration. For OpenClaw passive App-agent replies, run the generated `openclaw-gateway/start_gateway.sh` after `openclaw agent --message "Reply with only: ok"` succeeds. For Hermes passive App-agent replies, run the generated `hermes-gateway/start_gateway.sh` after `hermes -z "Reply with only: ok"` succeeds. Claude Code, Cursor, Gemini, and GitHub Copilot use MCP-only unless the user provides a local command for an external gateway. S6 records `agent_skill_install_path`, `agent_global_skill_install_path`, `agent_mcp_config_path`, and `agent_install_target_summary`; agents must follow those fields and `references/agent-targets.md` instead of defaulting to Codex paths.

Gateway native send test:

```bash
source ~/.direxio/nodes/<service_id>/env
npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "$DIREXIO_AGENT_ROOM_ID" --message "hello"
```

## Validation

```bash
bash tests/skill_structure_test.sh
bash tests/s6_wire_local_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```
