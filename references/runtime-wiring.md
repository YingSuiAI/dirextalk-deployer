# Runtime Wiring

After deployment, ops writes:

```text
~/.direxio/nodes/<service_id>/credentials.json
~/.direxio/nodes/<service_id>/env
```

`service_id` is derived from the deployed service domain, for example `__DOMAIN__` or `__SERVICE_ID__`.

Expected shape:

```json
{
  "profiles": {
    "default": {
      "password": "<login-password>",
      "access_token": "<access-token>",
      "agent_room_id": "__ROOM_ID__",
      "direxio_domain": "https://__DOMAIN__",
      "direxio_agent_token": "<token>",
      "direxio_agent_room_id": "__ROOM_ID__",
      "direxio_agent_node_id": "__AGENT_NODE_ID__"
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
DIREXIO_DOMAIN=https://__DOMAIN__
DIREXIO_AGENT_TOKEN=<agent_token>
DIREXIO_AGENT_ROOM_ID=__ROOM_ID__
DIREXIO_AGENT_NODE_ID=__AGENT_NODE_ID__
```

`DIREXIO_*` is the only local integration contract for current MCP and plugin wiring. S6 does not write shell profiles, Windows user environment variables, or root-level compatibility env files; callers should source the service-specific env file explicitly.

## MCP Server

Use `@direxio/local-mcp` as a stdio MCP server:

```json
{
  "command": "npx",
  "args": ["-y", "-p", "@direxio/local-mcp@latest", "direxio-mcp"],
  "env": {
    "DIREXIO_DOMAIN": "https://__DOMAIN__",
    "DIREXIO_AGENT_TOKEN": "<agent-token>",
    "DIREXIO_AGENT_ROOM_ID": "__ROOM_ID__",
    "DIREXIO_AGENT_NODE_ID": "__AGENT_NODE_ID__"
  }
}
```

Current published local MCP wiring reads direct `DIREXIO_*` environment
variables. Do not generate a credential-file-only MCP payload unless the
installed `@direxio/local-mcp` version explicitly documents that contract. If an
agent config should not contain the token, use a small launcher wrapper that
loads the service-scoped credentials/env file and then exports the same direct
`DIREXIO_*` variables before executing the MCP server.

For Windows-native agents, prefer `%USERPROFILE%\.direxio\nodes\<service_id>`
and `%USERPROFILE%\.codex` style paths in templates and scripts. Deployment
docs may show `%USERPROFILE%` or `$env:USERPROFILE`; they must not publish a
specific operator's home directory.

## Gateway Native Send

`direxio-agent-gateway` can send without MCP. It calls `/_p2p/command` action `mcp.messages.send` directly:

```bash
source ~/.direxio/nodes/<service_id>/env
npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "$DIREXIO_AGENT_ROOM_ID" --message "hello"
```

MCP is for active tools mounted into an agent. Gateway passive replies and manual `send` do not depend on `@direxio/local-mcp`.

## Hermes Passive App-Agent Gateway

When S6 detects `DIREXIO_AGENT_PLATFORM=hermes`, it writes a per-node helper under:

```text
~/.direxio/nodes/<service_id>/hermes-gateway/
```

The helper contains:

- `p2p_handler.cjs`: reads an incoming room prompt from stdin and calls `hermes -z <prompt>`.
- `start_gateway.sh`: loads Hermes model-provider environment variables, loads the node's Direxio env file, sets `DIREXIO_GATEWAY_ADAPTER=generic-cli`, and starts `direxio-agent-gateway`.

Use:

```bash
hermes -z "Reply with only: ok"
bash ~/.direxio/nodes/<service_id>/hermes-gateway/start_gateway.sh
```

Do not set `DIREXIO_GATEWAY_COMMAND=node` without `DIREXIO_GATEWAY_ARGS` pointing at the generated handler. A bare `node` process treats the natural-language prompt as JavaScript and fails with errors such as `SyntaxError: Unexpected identifier 'are'`.

## OpenClaw Passive App-Agent Gateway

When S6 detects `DIREXIO_AGENT_PLATFORM=openclaw`, it writes a per-node helper under:

```text
~/.direxio/nodes/<service_id>/openclaw-gateway/
```

The helper contains:

- `p2p_handler.cjs`: reads an incoming room prompt from stdin and calls `openclaw agent --agent main --session-key agent:main:main --message <prompt>`.
- `start_gateway.sh`: loads OpenClaw and Direxio environment files, adds common OpenClaw CLI locations to `PATH`, sets `DIREXIO_GATEWAY_ADAPTER=generic-cli`, and starts `direxio-agent-gateway`.

Use:

```bash
openclaw agent --message "Reply with only: ok"
bash ~/.direxio/nodes/<service_id>/openclaw-gateway/start_gateway.sh
```

Set `OPENCLAW_AGENT_ID`, `OPENCLAW_SESSION_KEY`, `OPENCLAW_AGENT_MODEL`, or `OPENCLAW_COMMAND` before starting the helper when the default `main` agent/session should not be used. The default session key is `agent:main:main`, matching the local App-agent session used by OpenClaw's main agent.

## Windows-Native Codex Gateway

Windows-native Codex should start gateway from Windows PowerShell, not WSL, when
the current Codex app is a Windows process. Use environment-derived paths:

```powershell
$env:HOME = $env:USERPROFILE
$env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex'
$env:XDG_CONFIG_HOME = Join-Path $env:USERPROFILE '.config'
$codexBin = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Filter codex.exe -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
if ($codexBin) { $env:DIREXIO_CODEX_COMMAND = $codexBin }
```

Set `DIREXIO_CODEX_COMMAND` when `codex` resolves to a restricted WindowsApps
alias or any path that cannot be spawned by the gateway process.

## Install Parameters

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_AGENT_INSTALL=skip|recommend|auto
DIREXIO_AGENT_INSTALL_MODE=recommended|mcp|native|gateway
```

`DIREXIO_AGENT_NODE_ID` is accepted only when it is scoped to the current
deployment domain, so stale environment from a previous node cannot silently
reuse the wrong identity. Set `DIREXIO_AGENT_NODE_ID_FORCE=1` only when an
operator intentionally wants a custom node id that does not contain the current
domain.

Defaults:

- `DIREXIO_AGENT_PLATFORM=auto` detects Codex, Claude Code, Gemini, Cursor, Copilot, OpenClaw, Hermes, or falls back to `unknown`.
- Active runtime signals are evaluated before historical config directories:
  runtime-specific process environment markers, current `PATH`/`PWD`
  fingerprints, and current process names win over stale `~/.codex`,
  `~/.hermes`, `~/.claude`, and similar directories. Generic API key variables
  such as model-provider credentials are not treated as active runtime markers.
- `DIREXIO_AGENT_INSTALL=recommend` prints and records the command only.
- `DIREXIO_AGENT_INSTALL=auto` runs `npx -y -p @direxio/agent-plugins@latest direxio-agent-install --platform <runtime> --mode <mode> --node-id <agent_node_id> --workspace <agent_workspace> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --write`.
- `DIREXIO_AGENT_INSTALL_MODE=recommended` maps OpenClaw/Hermes to `native`, Codex/generic to `gateway`, and non-long-process platforms to `mcp`.

Platform guidance:

- OpenClaw: use the generated `openclaw-gateway/start_gateway.sh` helper for native passive replies, and mount MCP only for active Direxio tools.
- Hermes: use the generated `hermes-gateway/start_gateway.sh` helper for native passive replies, and mount MCP only for active Direxio tools.
- Codex: prefer gateway with `codex-app-server`; when Codex runs from Windows and the deployer is invoked through WSL, infer the Windows Codex home from active `.codex/tmp` paths or set `CODEX_HOME=/mnt/c/Users/<user>/.codex` explicitly. Do not treat a project-local `PROJECT_ROOT/.codex/skills` clone as the Codex user config home.
- Claude Code, Cursor, Gemini, and Copilot: use MCP-only unless the user supplies a local prompt command for `generic-cli`.
- Cursor repository target: copy or merge the generated MCP payload into `PROJECT_ROOT/.cursor/mcp.json`.
- Copilot repository target: use read-only MCP by default at `PROJECT_ROOT/.github/copilot/mcp.json`; enable write-capable tools only with repository owner approval.
- Gemini target: merge the generated settings payload into Gemini settings.

## Plugin Install Prompt

After S7 succeeds, ask the user whether to configure the detected runtime automatically:

```text
Detected <runtime>. Do you want me to automatically install/configure the Direxio plugin and MCP service for this agent using the persisted DIREXIO_* environment and the recorded runtime target paths?
```

Only proceed after the user agrees or after `DIREXIO_AGENT_INSTALL=auto` was set before deployment. Use the runtime-specific plugin under `@direxio/agent-plugins` when it exists, the MCP server configuration above, and the generated OpenClaw/Hermes gateway helpers when passive replies are needed.
