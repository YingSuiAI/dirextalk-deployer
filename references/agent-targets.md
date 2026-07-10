# Agent Targets

Use this file when installing or updating this skill and when reviewing S6 local bridge output. Dirextalk no longer ships extra chat-platform adapters from this deployer; the only post-deploy local conversation bridge is `dirextalk-connect`. Bridge-agent support does not imply MCP capability; the explicit registry below controls remote HTTP MCP handling.

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

`DIREXTALK_AGENT_PLATFORM=auto` is a convenience detector. If it detects OpenClaw or Hermes, S6 wires `dirextalk-connect` through the generic `acp` agent and rejects a non-ACP override. OpenClaw writes `cmd = "openclaw"` and keeps an explicit profile/config path aligned between its ACP process and native MCP probe. Hermes writes `cmd = "dirextalk-connect"` with service-scoped `HERMES_HOME` and `args = ["hermes-acp-adapter", "--", "hermes", "-p", "<service-profile>", "acp"]`. The adapter can buffer and clean Hermes output before it reaches the Matrix room. To bridge directly to another backend, select that backend as `DIREXTALK_AGENT_PLATFORM` instead of overriding an OpenClaw/Hermes host.

S6 writes service-specific files to `~/.dirextalk/nodes/<service_id>/`, where `service_id` is derived from the deployed domain:

```text
credentials.json
dirextalk-connect/config.toml
dirextalk-connect/data/
dirextalk-connect/matrix-session.json
mcp/env
mcp/README.md
mcp/openclaw.md
mcp/hermes.md
```

The generated `dirextalk-connect/config.toml` contains exactly one Matrix platform and includes:

```toml
language = "auto"

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
mcp_url = "https://<domain>/mcp"
mcp_server_name = "dirextalk-<domain>"
mcp_agent_token = "<service agent token>"
mcp_node_id = "<agent-node-id>"
mcp_capability = "<session|project|host-managed|conditional|unsupported>"

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

S6 always writes canonical `mcp/env` plus a README under the service directory.
Standalone artifacts are limited to token-free OpenClaw `openclaw.md` and
Hermes `hermes.md` host guidance. Session agents receive canonical MCP data
through dirextalk-connect; no runtime receives a generic JSON fallback.
Capability follows the effective connect agent:
ACP/Claude Code/Codex/Copilot/Gemini/Kimi/OpenCode/Qoder `session`;
Antigravity/Cursor/iFlow `host-managed`; Devin/Pi/Reasonix/tmux `unsupported`.
Detected OpenClaw and Hermes hosts are always `host-managed`, require the ACP
bridge, and reject non-ACP connect overrides. Connect owns only conversation;
their native registries own MCP. Unsupported and unknown selections fail closed.
No current backend uses the retained `project` or `conditional` vocabulary entries.

```bash
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_doctor
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_tools
```

For host-managed selection, the host-specific artifact identifies the endpoint,
node id, and service-scoped credential location. S6 omits `mcp_url`,
`mcp_server_name`, `mcp_agent_token`, `mcp_node_id`, and `mcp_capability` from
the connect agent options; it does not mutate global host config, generate a
token-bearing server object, or put a bearer token in command arguments. With
`auto`, complete host enrollment first and rerun with
`DIREXTALK_MCP_HOST_READY=1`; only then does S6 start and verify the bridge.
For OpenClaw, S6 additionally requires `openclaw mcp probe <server-name> --json`
to pass without secret argv. `OPENCLAW_CONFIG_PATH` is inherited;
`DIREXTALK_OPENCLAW_PROFILE=<profile>` adds `--profile <profile>` for service
isolation. S6 never runs `mcp set`. Other host-managed backends with no official
probe record operator confirmation, which does not replace runtime MCP checks.
Hermes receives an empty service-isolated HERMES_HOME plus `hermes.md` guidance.
The operator must create/clone the named profile with the installed Hermes
version's official workflow, enroll the server in native `mcp_servers`, and let
S6 pass `hermes -p <profile> mcp test <server-name>` in that same HERMES_HOME.
With `recommend` or `skip`, output generation completes but
`mcp_install_status=host_action_required` remains explicit until confirmation.

## Installation Policy

- `DIREXTALK_AGENT_INSTALL=skip`: write credentials, canonical MCP artifacts, and dirextalk-connect config only.
- `DIREXTALK_AGENT_INSTALL=recommend`: write files, record state, and print the install command.
- `DIREXTALK_AGENT_INSTALL=auto` (default): refresh `dirextalk-connect@latest` under `~/.dirextalk/nodes/<service_id>/dirextalk-connect`, unless explicit binary/command overrides are set. S6 writes short wrappers at `dirextalk-connect/dirextalk-connect(.cmd)`, installs or refreshes the service-scoped `dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force`, and records dirextalk-connect as installed only after `dirextalk-connect daemon status --service-name <service_id>` reports `Status: Running` and recent daemon logs show `dirextalk-connect is running`. Logs that show agent CLI missing, login/auth/trust failures, ACP startup failures, or agent offline state make S6 fail with `connect_install_status=install_failed`; deploy does not continue to completion until the daemon startup is verified. MCP records `mcp_install_status=not_required` for the HTTP endpoint path.

Prefer `DIREXTALK_CONNECT_AGENT=<agent>` to choose the local agent that `dirextalk-connect` should run. Keep `DIREXTALK_AGENT_PLATFORM=<runtime>` for auto-detection overrides and legacy host-runtime naming. Use `DIREXTALK_AGENT_INSTALL_MODE=dirextalk-connect` only when overriding the default `recommended` mapping explicitly.
Use `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` for agent-specific options that cannot be represented by `work_dir` or `cmd`; for example `reasonix` requires `serve_url`, `tmux` requires `session`, and generic `acp` requires a command when `DIREXTALK_CONNECT_AGENT_CMD` is not enough.
For OpenCode, use `DIREXTALK_OPENCODE_COMMAND` when PATH lookup does not find the right CLI. The Windows wrapper also checks the global `opencode-ai` npm package under the npm global prefix.
For OpenClaw Gateway ACP, S6 defaults to `["acp", "--session", "agent:main:main"]` and lets `openclaw acp` auto-discover the Gateway from `~/.openclaw/openclaw.json`. To force an explicit Gateway, complete OpenClaw pairing first, then set all of `DIREXTALK_OPENCLAW_ACP_URL`, `DIREXTALK_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXTALK_OPENCLAW_ACP_SESSION` from the current OpenClaw runtime. S6 writes `["acp", "--url", <url>, "--token-file", <local path>, "--session", <session>]` and converts the token-file with `DIREXTALK_LOCAL_PATH_STYLE`. `DIREXTALK_OPENCLAW_ACP_ARGS_TOML` replaces the OpenClaw ACP args array only when the runtime needs a fully custom argument list. `DIREXTALK_HERMES_ACP_ARGS_TOML` supplies the child Hermes args and keeps the Dirextalk adapter prefix.
