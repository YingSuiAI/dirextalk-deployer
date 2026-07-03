# Agent Targets

Use this file when installing or updating this skill and when reviewing S6 local bridge output. Dirextalk no longer ships extra chat-platform adapters from this deployer; the only post-deploy local conversation bridge is `dirextalk-connect`. MCP-capable hosts can also use the generated `dirextalk-mcp` snippets.

## Npm Skill Installation

Prefer the npm-managed global install for normal users. Install the versioned package, then let the CLI copy the skill bundle into the selected runtime's host-level skill directory:

Do not use a generic "install skills <GitHub URL>" instruction for normal users. That can invoke a host's GitHub skill installer instead of the npm-managed installer. A short user prompt should give the repository URL for reading only and point the agent back to this npm install rule:

```text
Read https://github.com/YingSuiAI/dirextalk-deployer README and follow its npm install rule, then deploy Dirextalk with domain __DOMAIN__.
```

POSIX shells:

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
dirextalk-deployer skill update --agent codex
```

Windows PowerShell:

```powershell
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
dirextalk-deployer skill update --agent codex
```

Use `--scope project --project PROJECT_ROOT` only when the user explicitly asks for a repository-local install. Use a Git clone only for deployer development or local patching, not as the normal end-user installation path. The npm installer writes `.dirextalk-skill-install.json` and refuses to overwrite unmanaged existing target directories unless `--force` is passed.

| Runtime | Default global skill target | Explicit project-local skill target |
| --- | --- | --- |
| Codex | `${CODEX_HOME:-$HOME/.codex}/skills/dirextalk-deployer` | `PROJECT_ROOT/.codex/skills/dirextalk-deployer` |
| Claude Code | `${CLAUDE_HOME:-$HOME/.claude}/skills/dirextalk-deployer` | `PROJECT_ROOT/.claude/skills/dirextalk-deployer` |
| Gemini | `${GEMINI_HOME:-$HOME/.gemini}/skills/dirextalk-deployer` | `PROJECT_ROOT/.gemini/skills/dirextalk-deployer` |
| Cursor | `${CURSOR_HOME:-$HOME/.cursor}/skills/dirextalk-deployer` | `PROJECT_ROOT/.cursor/skills/dirextalk-deployer` |
| GitHub Copilot | `$HOME/.github/copilot/skills/dirextalk-deployer` | `PROJECT_ROOT/.github/copilot/skills/dirextalk-deployer` |
| OpenClaw | `${OPENCLAW_HOME:-$HOME/.openclaw}/skills/dirextalk-deployer` | `PROJECT_ROOT/.openclaw/skills/dirextalk-deployer` |
| Hermes | `${HERMES_HOME:-$HOME/.hermes}/skills/dirextalk-deployer` | `PROJECT_ROOT/.hermes/skills/dirextalk-deployer` |
| ACP-compatible | `$HOME/.agents/skills/dirextalk-deployer` | `PROJECT_ROOT/.agents/skills/dirextalk-deployer` |
| Antigravity | `${ANTIGRAVITY_HOME:-$HOME/.antigravity}/skills/dirextalk-deployer` | `PROJECT_ROOT/.antigravity/skills/dirextalk-deployer` |
| Devin | `${DEVIN_HOME:-$HOME/.devin}/skills/dirextalk-deployer` | `PROJECT_ROOT/.devin/skills/dirextalk-deployer` |
| iFlow | `${IFLOW_HOME:-$HOME/.iflow}/skills/dirextalk-deployer` | `PROJECT_ROOT/.iflow/skills/dirextalk-deployer` |
| Kimi | `${KIMI_HOME:-$HOME/.kimi}/skills/dirextalk-deployer` | `PROJECT_ROOT/.kimi/skills/dirextalk-deployer` |
| OpenCode | `${OPENCODE_HOME:-$HOME/.opencode}/skills/dirextalk-deployer` | `PROJECT_ROOT/.opencode/skills/dirextalk-deployer` |
| Pi | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/skills/dirextalk-deployer` | `PROJECT_ROOT/.pi/agent/skills/dirextalk-deployer` |
| Qoder | `${QODER_HOME:-$HOME/.qoder}/skills/dirextalk-deployer` | `PROJECT_ROOT/.qoder/skills/dirextalk-deployer` |
| Reasonix | `${REASONIX_HOME:-$HOME/.reasonix}/skills/dirextalk-deployer` | `PROJECT_ROOT/.reasonix/skills/dirextalk-deployer` |
| tmux | `$HOME/.agent/skills/dirextalk-deployer` | `PROJECT_ROOT/.agent/skills/dirextalk-deployer` |
| Generic or unknown | `$HOME/.agent/skills/dirextalk-deployer` | `PROJECT_ROOT/.agent/skills/dirextalk-deployer` |

## Dirextalk Connect Target

The bridge agent type is selected independently from the host operating system. `DIREXTALK_CONNECT_AGENT` may be any agent supported by dirextalk-connect:

```text
acp antigravity claudecode codex copilot cursor devin gemini iflow kimi opencode pi qoder reasonix tmux
```

`DIREXTALK_AGENT_PLATFORM=auto` is a convenience detector. If it detects OpenClaw or Hermes, S6 wires `dirextalk-connect` through the generic `acp` agent. OpenClaw writes `cmd = "openclaw"` and requires the current agent/operator to provide the real Gateway URL, token-file, and ACP session. Hermes writes `cmd = "dirextalk-connect"` with `args = ["hermes-acp-adapter", "--", "hermes", "acp"]` so the Dirextalk ACP compatibility layer can buffer and clean Hermes output before it reaches the Matrix room. OpenClaw and Hermes are not native dirextalk-connect agent types. If detection is ambiguous or the detected host runtime should use a different connect backend, set `DIREXTALK_CONNECT_AGENT` explicitly.

S6 writes service-specific files to `~/.dirextalk/nodes/<service_id>/`, where `service_id` is derived from the deployed domain:

```text
credentials.json
env
dirextalk-connect/config.toml
dirextalk-connect/data/
dirextalk-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

The generated `dirextalk-connect/config.toml` contains exactly one Matrix platform and includes:

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

The `[speech]` block is present only when S6 finds a speech-to-text API key from `DIREXTALK_SPEECH_*` or supported provider environment variables. Voice input is not available without STT credentials.

`admin_from` must stay at the `[[projects]]` level. `dirextalk-connect` uses the full Matrix sender ID, so S6 writes `@owner:<server>`; privileged commands such as `/dir`, `/shell`, `/show`, `/restart`, and `/upgrade` are blocked for other room members. `/dir reset` returns to the generated `work_dir` and clears the runtime override stored under `dirextalk-connect/data/projects/<project>.state.json`.

## MCP Targets

S6 writes one MCP artifact set under `~/.dirextalk/nodes/<service_id>/mcp/`, selected from the detected runtime. Codex gets `codex.toml`, Cursor gets `cursor.mcp.json`, OpenClaw gets `openclaw.md` plus `openclaw-server.json`, Hermes gets `hermes.mcp.json`, and other MCP-capable supported runtimes get `mcp-servers.json`. These artifacts use the service-scoped `dirextalk-mcp` from `dirextalk-mcp@latest` by default and point to the service credential file through `DIREXTALK_CREDENTIALS_FILE`. Generated client snippets launch `dirextalk-mcp` directly over stdio, so MCP does not require a local daemon, HTTP proxy, or listening port.

```bash
npm install --prefix ~/.dirextalk/nodes/<service_id>/mcp dirextalk-mcp@latest
DIREXTALK_CREDENTIALS_FILE=~/.dirextalk/nodes/<service_id>/credentials.json ~/.dirextalk/nodes/<service_id>/mcp/dirextalk-mcp doctor --json
```

Use the single MCP artifact selected for the detected runtime. For OpenClaw, use `mcp/openclaw.md`; it runs `openclaw mcp set` with `mcp/openclaw-server.json` so OpenClaw validates and writes its own `mcp.servers` config. Do not paste MCP JSON into `~/.openclaw/openclaw.json`. The deployer writes local artifacts only; it does not mutate each host application's global MCP config.

## Installation Policy

- `DIREXTALK_AGENT_INSTALL=skip`: write credentials/env and dirextalk-connect config only.
- `DIREXTALK_AGENT_INSTALL=recommend`: write files, record state, and print the install command.
- `DIREXTALK_AGENT_INSTALL=auto` (default): refresh `dirextalk-connect@latest` under `~/.dirextalk/nodes/<service_id>/dirextalk-connect` and `dirextalk-mcp@latest` under `~/.dirextalk/nodes/<service_id>/mcp`, unless explicit binary/command overrides are set. S6 writes short wrappers at `dirextalk-connect/dirextalk-connect(.cmd)` and `mcp/dirextalk-mcp(.cmd)`, installs or refreshes the service-scoped `dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force`, and records dirextalk-connect as installed only after `dirextalk-connect daemon status --service-name <service_id>` reports `Status: Running` and recent daemon logs show `dirextalk-connect is running`. Logs that show agent CLI missing, login/auth/trust failures, ACP startup failures, or agent offline state make S6 fail with `connect_install_status=install_failed`; deploy does not continue to completion until the daemon startup is verified. MCP records `mcp_install_status=installed` when the service-scoped stdio command is available.

Prefer `DIREXTALK_CONNECT_AGENT=<agent>` to choose the local agent that `dirextalk-connect` should run. Keep `DIREXTALK_AGENT_PLATFORM=<runtime>` for auto-detection overrides and legacy host-runtime naming. Use `DIREXTALK_AGENT_INSTALL_MODE=dirextalk-connect` only when overriding the default `recommended` mapping explicitly.
Use `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` for agent-specific options that cannot be represented by `work_dir` or `cmd`; for example `reasonix` requires `serve_url`, `tmux` requires `session`, and generic `acp` requires a command when `DIREXTALK_CONNECT_AGENT_CMD` is not enough.
For OpenCode, use `DIREXTALK_OPENCODE_COMMAND` when PATH lookup does not find the right CLI. The Windows wrapper also checks the global `opencode-ai` npm package under the npm global prefix.
For OpenClaw Gateway ACP, S6 defaults to `["acp", "--session", "agent:main:main"]` and lets `openclaw acp` auto-discover the Gateway from `~/.openclaw/openclaw.json`. To force an explicit Gateway, complete OpenClaw pairing first, then set all of `DIREXTALK_OPENCLAW_ACP_URL`, `DIREXTALK_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXTALK_OPENCLAW_ACP_SESSION` from the current OpenClaw runtime. S6 writes `["acp", "--url", <url>, "--token-file", <local path>, "--session", <session>]` and converts the token-file with `DIREXTALK_LOCAL_PATH_STYLE`. `DIREXTALK_OPENCLAW_ACP_ARGS_TOML` replaces the OpenClaw ACP args array only when the runtime needs a fully custom argument list. `DIREXTALK_HERMES_ACP_ARGS_TOML` supplies the child Hermes args and keeps the Dirextalk adapter prefix.
