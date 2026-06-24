# Agent Targets

Use this file whenever installing or updating this skill itself, or when wiring Direxio MCP/plugin access after S6. Do not assume Codex paths apply to other agent runtimes.

## Project-Local Skill Clones

Prefer a project-local Git clone when a project or workspace exists. Create the parent directory if needed and run `git clone`, not a copy-based installer, so `.git` remains available for `git pull`, commit inspection, and local patches.

| Runtime | Project-local skill clone | Global fallback only when explicitly requested or no project exists |
| --- | --- | --- |
| Codex | `PROJECT_ROOT/.codex/skills/direxio-deployer` | `${CODEX_HOME:-$HOME/.codex}/skills/direxio-deployer` |
| Claude Code | `PROJECT_ROOT/.claude/skills/direxio-deployer` | `${CLAUDE_HOME:-$HOME/.claude}/skills/direxio-deployer` |
| Gemini | `PROJECT_ROOT/.gemini/skills/direxio-deployer` | `${GEMINI_HOME:-$HOME/.gemini}/skills/direxio-deployer` |
| Cursor | `PROJECT_ROOT/.cursor/skills/direxio-deployer` | `${CURSOR_HOME:-$HOME/.cursor}/skills/direxio-deployer` |
| GitHub Copilot | `PROJECT_ROOT/.github/copilot/skills/direxio-deployer` | `$HOME/.github/copilot/skills/direxio-deployer` |
| OpenClaw | `PROJECT_ROOT/.openclaw/skills/direxio-deployer` | `${OPENCLAW_HOME:-$HOME/.openclaw}/skills/direxio-deployer` |
| Hermes | `PROJECT_ROOT/.hermes/skills/direxio-deployer` | `${HERMES_HOME:-$HOME/.hermes}/skills/direxio-deployer` |
| Generic or unknown | `PROJECT_ROOT/.agent/skills/direxio-deployer` | `$HOME/.agent/skills/direxio-deployer` |

These skill clone paths are project-tracking locations for agent handoff and reproducibility. If a runtime has its own official discovery or plugin import flow, follow that runtime's native flow after cloning.

## Deployment Wiring Targets

S6 writes service-specific credentials to `~/.direxio/nodes/<service_id>/credentials.json` and `~/.direxio/nodes/<service_id>/env`, where `service_id` is derived from the deployed domain such as `im.example.com`. Runtime-specific MCP/plugin payloads are node-scoped by `<agent_node_id>` and written only when `DIREXIO_AGENT_INSTALL=auto`; otherwise S6 records and prints the target paths for explicit post-deploy approval.

| Runtime | Recommended mode | Generated MCP/config payload | Project config target or native step |
| --- | --- | --- | --- |
| Codex | `gateway` | `${CODEX_HOME:-$HOME/.codex}/direxio-agent/nodes/<agent_node_id>/mcp.json` | Use `@direxio/agent-plugins` Codex gateway with `codex-app-server` plus MCP payload. In WSL, Windows Codex uses `/mnt/c/Users/<user>/.codex`. |
| Claude Code | `mcp` | `$HOME/.claude/direxio-agent/nodes/<agent_node_id>/mcp.json` | Use `platforms/claude-code/direxio-agent`, for example `claude --plugin-dir ./platforms/claude-code/direxio-agent`. |
| Gemini | `mcp` | `$HOME/.gemini/direxio/nodes/<agent_node_id>/settings.json` | Merge `platforms/gemini/settings.json` into Gemini settings. |
| Cursor | `mcp` | `${XDG_CONFIG_HOME:-$HOME/.config}/direxio-agent/nodes/<agent_node_id>/cursor.mcp.json` | Copy or merge into `PROJECT_ROOT/.cursor/mcp.json`. |
| GitHub Copilot | `mcp` | `${XDG_CONFIG_HOME:-$HOME/.config}/direxio-agent/nodes/<agent_node_id>/copilot.mcp.json` | Use read-only MCP by default at `PROJECT_ROOT/.github/copilot/mcp.json`; use full-chat only with repository owner approval. |
| OpenClaw | `native` | `$HOME/.openclaw/direxio/nodes/<agent_node_id>/mcp.json` | Run `openclaw plugins install ./platforms/openclaw`; mount MCP payload in OpenClaw's MCP registry. |
| Hermes | `native` | `$HOME/.hermes/direxio/nodes/<agent_node_id>/mcp.json` | Merge into `~/.hermes/config.yaml` and use a Hermes-native long process for passive listening. |
| Generic or unknown | `mcp` | `${XDG_CONFIG_HOME:-$HOME/.config}/direxio-agent/nodes/<agent_node_id>/mcp.json` | Mount MCP manually; use `DIREXIO_GATEWAY_COMMAND` only when an agent CLI reads stdin and writes stdout. |

## Installation Policy

- `DIREXIO_AGENT_INSTALL=skip`: write credentials/env only.
- `DIREXIO_AGENT_INSTALL=recommend`: write credentials/env, record target paths, and print commands without mutating agent config.
- `DIREXIO_AGENT_INSTALL=auto`: run `npx -y -p @direxio/agent-plugins@latest direxio-agent-install --platform <runtime> --mode <mode> --node-id <agent_node_id> --workspace <agent_workspace> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --write`. Gateway mode restarts only the matching node gateway and leaves other nodes alone.

Use `DIREXIO_AGENT_PLATFORM=<runtime>` to override detection, and `DIREXIO_AGENT_INSTALL_MODE=mcp|native|gateway` only when the user chooses a non-default runtime mode.
