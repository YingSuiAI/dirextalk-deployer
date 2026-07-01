# Agent Targets

Use this file when installing or updating this skill and when reviewing S6 local bridge output. Direxio no longer ships extra chat-platform adapters from this deployer; the only post-deploy local conversation bridge is `direxio-connect`. MCP-capable hosts can also use the generated `direxio-mcp` snippets.

## Npm Skill Installation

Prefer the npm-managed global install for normal users. Install the versioned package, then let the CLI copy the skill bundle into the selected runtime's host-level skill directory:

Do not use a generic "install skills <GitHub URL>" instruction for normal users. That can invoke a host's GitHub skill installer instead of the npm-managed installer. A short user prompt should give the repository URL for reading only and point the agent back to this npm install rule:

```text
Read https://github.com/YingSuiAI/direxio-deployer README and follow its npm install rule, then deploy Direxio with domain __DOMAIN__.
```

POSIX shells:

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex
direxio-deployer skill update --agent codex
```

Windows PowerShell:

```powershell
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex
direxio-deployer skill update --agent codex
```

Use `--scope project --project PROJECT_ROOT` only when the user explicitly asks for a repository-local install. Use a Git clone only for deployer development or local patching, not as the normal end-user installation path. The npm installer writes `.direxio-skill-install.json` and refuses to overwrite unmanaged existing target directories unless `--force` is passed.

| Runtime | Default global skill target | Explicit project-local skill target |
| --- | --- | --- |
| Codex | `${CODEX_HOME:-$HOME/.codex}/skills/direxio-deployer` | `PROJECT_ROOT/.codex/skills/direxio-deployer` |
| Claude Code | `${CLAUDE_HOME:-$HOME/.claude}/skills/direxio-deployer` | `PROJECT_ROOT/.claude/skills/direxio-deployer` |
| Gemini | `${GEMINI_HOME:-$HOME/.gemini}/skills/direxio-deployer` | `PROJECT_ROOT/.gemini/skills/direxio-deployer` |
| Cursor | `${CURSOR_HOME:-$HOME/.cursor}/skills/direxio-deployer` | `PROJECT_ROOT/.cursor/skills/direxio-deployer` |
| GitHub Copilot | `$HOME/.github/copilot/skills/direxio-deployer` | `PROJECT_ROOT/.github/copilot/skills/direxio-deployer` |
| OpenClaw | `${OPENCLAW_HOME:-$HOME/.openclaw}/skills/direxio-deployer` | `PROJECT_ROOT/.openclaw/skills/direxio-deployer` |
| Hermes | `${HERMES_HOME:-$HOME/.hermes}/skills/direxio-deployer` | `PROJECT_ROOT/.hermes/skills/direxio-deployer` |
| ACP-compatible | `$HOME/.agents/skills/direxio-deployer` | `PROJECT_ROOT/.agents/skills/direxio-deployer` |
| Antigravity | `${ANTIGRAVITY_HOME:-$HOME/.antigravity}/skills/direxio-deployer` | `PROJECT_ROOT/.antigravity/skills/direxio-deployer` |
| Devin | `${DEVIN_HOME:-$HOME/.devin}/skills/direxio-deployer` | `PROJECT_ROOT/.devin/skills/direxio-deployer` |
| iFlow | `${IFLOW_HOME:-$HOME/.iflow}/skills/direxio-deployer` | `PROJECT_ROOT/.iflow/skills/direxio-deployer` |
| Kimi | `${KIMI_HOME:-$HOME/.kimi}/skills/direxio-deployer` | `PROJECT_ROOT/.kimi/skills/direxio-deployer` |
| OpenCode | `${OPENCODE_HOME:-$HOME/.opencode}/skills/direxio-deployer` | `PROJECT_ROOT/.opencode/skills/direxio-deployer` |
| Pi | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/skills/direxio-deployer` | `PROJECT_ROOT/.pi/agent/skills/direxio-deployer` |
| Qoder | `${QODER_HOME:-$HOME/.qoder}/skills/direxio-deployer` | `PROJECT_ROOT/.qoder/skills/direxio-deployer` |
| Reasonix | `${REASONIX_HOME:-$HOME/.reasonix}/skills/direxio-deployer` | `PROJECT_ROOT/.reasonix/skills/direxio-deployer` |
| tmux | `$HOME/.agent/skills/direxio-deployer` | `PROJECT_ROOT/.agent/skills/direxio-deployer` |
| Generic or unknown | `$HOME/.agent/skills/direxio-deployer` | `PROJECT_ROOT/.agent/skills/direxio-deployer` |

## Direxio Connect Target

The bridge agent type is selected independently from the host operating system. `DIREXIO_CONNECT_AGENT` may be any agent supported by direxio-connect:

```text
acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux
```

`DIREXIO_AGENT_PLATFORM=auto` is a convenience detector. If it detects OpenClaw or Hermes, S6 wires `direxio-connect` through the generic `acp` agent. OpenClaw writes `cmd = "openclaw"` and requires the current agent/operator to provide the real Gateway URL, token-file, and ACP session. Hermes writes `cmd = "direxio-connect"` with `args = ["hermes-acp-adapter", "--", "hermes", "acp"]` so the Direxio ACP compatibility layer can buffer and clean Hermes output before it reaches the Matrix room. OpenClaw and Hermes are not native direxio-connect agent types. If detection is ambiguous or the detected host runtime should use a different connect backend, set `DIREXIO_CONNECT_AGENT` explicitly.

S6 writes service-specific files to `~/.direxio/nodes/<service_id>/`, where `service_id` is derived from the deployed domain:

```text
credentials.json
env
direxio-connect/config.toml
direxio-connect/data/
direxio-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

The generated `direxio-connect/config.toml` contains exactly one Matrix platform and includes:

```toml
[speech]
enabled = true
provider = "openai"
language = "zh"

[speech.openai]
api_key = "<optional speech-to-text key>"

[[projects]]
name = "<agent-node-id>"
admin_from = "@owner:<server>"

[projects.agent.options]
work_dir = "<workspace>"
cmd = "<optional explicit agent executable path>"

[[projects.platforms]]
type = "matrix"

[projects.platforms.options]
homeserver = "https://<domain>"
user_id = "@agent:<server>"
room_id = "!<real-agent-room>:<server>"
share_session_in_channel = true
group_reply_all = true
auto_join = false
auto_verify = false
```

The `[speech]` block is present only when S6 finds a speech-to-text API key from `DIREXIO_SPEECH_*` or supported provider environment variables. Voice input is not available without STT credentials.

`admin_from` must stay at the `[[projects]]` level. `direxio-connect` uses the full Matrix sender ID, so S6 writes `@owner:<server>`; privileged commands such as `/dir`, `/shell`, `/show`, `/restart`, and `/upgrade` are blocked for other room members. `/dir reset` returns to the generated `work_dir` and clears the runtime override stored under `direxio-connect/data/projects/<project>.state.json`.

## MCP Targets

S6 writes MCP artifacts for Codex, OpenClaw, and Hermes under `~/.direxio/nodes/<service_id>/mcp/`. These artifacts use `direxio-mcp` from `direxio-mcp@latest` by default and point to the service credential file through `DIREXIO_CREDENTIALS_FILE`.

```bash
npm install -g direxio-mcp@latest
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json direxio-mcp doctor --json
```

Use `mcp/codex.toml` for Codex and `mcp/hermes.mcp.json` for Hermes. For OpenClaw, use `mcp/openclaw.md`; it runs `openclaw mcp set` with `mcp/openclaw-server.json` so OpenClaw validates and writes its own `mcp.servers` config. Do not paste MCP JSON into `~/.openclaw/openclaw.json`. The deployer writes local artifacts only; it does not mutate each host application's global MCP config.

## Installation Policy

- `DIREXIO_AGENT_INSTALL=skip`: write credentials/env and direxio-connect config only.
- `DIREXIO_AGENT_INSTALL=recommend`: write files, record state, and print the install command.
- `DIREXIO_AGENT_INSTALL=auto` (default): run `npm install -g direxio-connent@latest`, `direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/direxio-connect/config.toml --service-name <service_id> --force`, and `npm install -g direxio-mcp@latest`. S6 records direxio-connect as installed only after `direxio-connect daemon status --service-name <service_id>` reports `Status: Running` and recent daemon logs do not show ACP session initialization failure; otherwise it records `agent_install_status=install_failed`. MCP records `mcp_install_status=installed` only when npm succeeds.

Prefer `DIREXIO_CONNECT_AGENT=<agent>` to choose the local agent that `direxio-connect` should run. Keep `DIREXIO_AGENT_PLATFORM=<runtime>` for auto-detection overrides and legacy host-runtime naming. Use `DIREXIO_AGENT_INSTALL_MODE=direxio-connect` only when overriding the default `recommended` mapping explicitly.
Use `DIREXIO_CONNECT_AGENT_OPTIONS_TOML` for agent-specific options that cannot be represented by `work_dir` or `cmd`; for example `reasonix` requires `serve_url`, `tmux` requires `session`, and generic `acp` requires a command when `DIREXIO_CONNECT_AGENT_CMD` is not enough.
For OpenClaw Gateway ACP, S6 defaults to `["acp", "--session", "agent:main:main"]` and lets `openclaw acp` auto-discover the Gateway from `~/.openclaw/openclaw.json`. To force an explicit Gateway, complete OpenClaw pairing first, then set all of `DIREXIO_OPENCLAW_ACP_URL`, `DIREXIO_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXIO_OPENCLAW_ACP_SESSION` from the current OpenClaw runtime. S6 writes `["acp", "--url", <url>, "--token-file", <local path>, "--session", <session>]` and converts the token-file with `DIREXIO_LOCAL_PATH_STYLE`. `DIREXIO_OPENCLAW_ACP_ARGS_TOML` replaces the OpenClaw ACP args array only when the runtime needs a fully custom argument list. `DIREXIO_HERMES_ACP_ARGS_TOML` supplies the child Hermes args and keeps the Direxio adapter prefix.
