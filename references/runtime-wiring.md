# Runtime Wiring

After deployment, ops writes:

```text
~/.direxio/nodes/<service_id>/credentials.json
~/.direxio/nodes/<service_id>/env
```

`service_id` is derived from the deployed service domain, for example `im.example.com` or `im.example.com-8443`.

Expected shape:

```json
{
  "profiles": {
    "default": {
      "password": "<login-password>",
      "access_token": "<access-token>",
      "agent_room_id": "!agent:im.example.com",
      "direxio_domain": "https://im.example.com",
      "direxio_agent_token": "<token>",
      "direxio_agent_room_id": "!agent:im.example.com",
      "direxio_agent_node_id": "codex-im-example-com-<hash>"
    }
  }
}
```

Use the client login `password` for the IM UI. Use `agent_token` only for Direxio MCP/plugin access.

## Integration Targets

```text
MCP package : @direxio/local-mcp
Agent plugins package : @direxio/agent-plugins
```

Read `references/agent-targets.md` for the runtime-specific skill clone paths, MCP/config payload paths, and native plugin targets. Do not assume Codex paths apply to Claude Code, Gemini, Cursor, Copilot, OpenClaw, Hermes, or generic agents.

S6 does not install plugins or mutate an agent's MCP config unless `DIREXIO_AGENT_INSTALL=auto` is set. It detects the current runtime and records enough state for the executing agent to ask for explicit post-deploy approval before configuring Codex, Claude Code, Gemini, Cursor, Copilot, OpenClaw, Hermes, or another runtime.
Set `DIREXIO_AGENT_INSTALL=auto` to explicitly authorize non-interactive installation; otherwise S6 defaults to `recommend`.

S6 records these runtime target fields in `state.json`:

```text
agent_runtime
agent_install_policy
agent_install_mode
agent_install_command
agent_node_id
agent_service_id
agent_service_dir
agent_credentials_file
agent_env_file
agent_workspace
agent_skill_install_path
agent_global_skill_install_path
agent_mcp_config_path
agent_install_target_summary
```

## Persistent Agent Environment

S6 persists these user environment variables from deployment outputs:

```bash
DIREXIO_DOMAIN=https://im.example.com
DIREXIO_AGENT_TOKEN=<agent_token>
DIREXIO_AGENT_ROOM_ID=!agent:im.example.com
DIREXIO_AGENT_NODE_ID=codex-im-example-com-<hash>
```

`DIREXIO_*` is the only local integration contract for current MCP and plugin wiring. S6 does not write shell profiles, Windows user environment variables, or root-level compatibility env files; callers should source the service-specific env file explicitly.

## MCP Server

Use `@direxio/local-mcp` as a stdio MCP server:

```json
{
  "command": "npx",
  "args": ["-y", "@direxio/local-mcp@latest"],
  "env": {
    "DIREXIO_CREDENTIALS_FILE": "/home/me/.direxio/nodes/im.example.com/credentials.json",
    "DIREXIO_AGENT_NODE_ID": "codex-im-example-com-<hash>"
  }
}
```

## Gateway Native Send

`direxio-agent-gateway` can send without MCP. It calls `/_p2p/command` action `mcp.messages.send` directly:

```bash
source ~/.direxio/nodes/<service_id>/env
npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "$DIREXIO_AGENT_ROOM_ID" --message "hello"
```

MCP is for active tools mounted into an agent. Gateway passive replies and manual `send` do not depend on `@direxio/local-mcp`.

## Install Parameters

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_AGENT_INSTALL=skip|recommend|auto
DIREXIO_AGENT_INSTALL_MODE=recommended|mcp|native|gateway
```

Defaults:

- `DIREXIO_AGENT_PLATFORM=auto` detects Codex, Claude Code, Gemini, Cursor, Copilot, OpenClaw, Hermes, or falls back to `unknown`.
- `DIREXIO_AGENT_INSTALL=recommend` prints and records the command only.
- `DIREXIO_AGENT_INSTALL=auto` runs `npx -y -p @direxio/agent-plugins@latest direxio-agent-install --platform <runtime> --mode <mode> --node-id <agent_node_id> --workspace <agent_workspace> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --write`.
- `DIREXIO_AGENT_INSTALL_MODE=recommended` maps OpenClaw/Hermes to `native`, Codex/generic to `gateway`, and non-long-process platforms to `mcp`.

Platform guidance:

- OpenClaw and Hermes: prefer native long-process integration using `/_p2p/events` and `mcp.messages.send`.
- Codex: prefer gateway with `codex-app-server`; when Codex runs from Windows under WSL, `CODEX_HOME=/mnt/c/.../.codex` is the MCP/config target.
- Claude Code, Cursor, Gemini, and Copilot: use MCP-only unless the user supplies a local prompt command for `generic-cli`.
- Cursor repository target: copy or merge the generated MCP payload into `PROJECT_ROOT/.cursor/mcp.json`.
- Copilot repository target: use read-only MCP by default at `PROJECT_ROOT/.github/copilot/mcp.json`; enable write-capable tools only with repository owner approval.
- Gemini target: merge the generated settings payload into Gemini settings.

## Plugin Install Prompt

After S7 succeeds, ask the user whether to configure the detected runtime automatically:

```text
Detected <runtime>. Do you want me to automatically install/configure the Direxio plugin and MCP service for this agent using the persisted DIREXIO_* environment and the recorded runtime target paths?
```

Only proceed after the user agrees or after `DIREXIO_AGENT_INSTALL=auto` was set before deployment. Use the runtime-specific plugin under `@direxio/agent-plugins`, the MCP server configuration above, and the native gateway-send contract when passive replies are needed.
