# Runtime Wiring

After deployment, S6 writes service-scoped files under:

```text
~/.direxio/nodes/<service_id>/
```

`service_id` is derived from the deployed service domain.

## Credentials

`credentials.json` keeps the backend `password` field, owner access token, agent token, and room identity. User-facing reports should call the `password` value the eight-digit app initialization code:

```json
{
  "profiles": {
    "default": {
      "password": "<eight-digit-app-initialization-code>",
      "access_token": "<owner-access-token>",
      "agent_room_id": "__ROOM_ID__",
      "direxio_domain": "https://__DOMAIN__",
      "direxio_agent_token": "<agent-token>",
      "direxio_agent_room_id": "__ROOM_ID__",
      "direxio_agent_node_id": "__AGENT_NODE_ID__"
    }
  }
}
```

Treat the synced `password` and owner `access_token` as one-time/volatile values. A successful App initialization or token exchange can reset them on the server. Before showing the eight-digit app initialization code or using an owner `access_token` for `/_p2p/command` or Matrix Client API calls, pull the current `/var/direxio-message-server/p2p/bootstrap.json` from the server and refresh local credentials instead of using older local output.

`env` contains the same service-scoped environment values for shell usage:

```bash
DIREXIO_DOMAIN=https://__DOMAIN__
DIREXIO_AGENT_TOKEN=<agent_token>
DIREXIO_AGENT_ROOM_ID=__ROOM_ID__
DIREXIO_AGENT_NODE_ID=__AGENT_NODE_ID__
```

## MCP Tooling

S6 writes MCP snippets under the same service directory:

```text
~/.direxio/nodes/<service_id>/mcp/
```

Generated files:

- `codex.toml`: Codex TOML snippet using `[mcp_servers."<server-name>"]`.
- `cursor.mcp.json`: Cursor-compatible JSON snippet using `mcpServers`. Operators can merge it into project-level `.cursor/mcp.json` or global `~/.cursor/mcp.json`; S6 does not write those locations by default because they contain machine-local credential paths.
- `openclaw.md` plus `openclaw-server.json`: OpenClaw CLI setup. It must use `openclaw mcp set`; do not paste MCP JSON into `~/.openclaw/openclaw.json`.
- `hermes.mcp.json`: Hermes JSON snippet using `mcpServers` with direct stdio `direxio-mcp`.
- `mcp-servers.json`: generic JSON snippet for other MCP-capable supported runtimes.
- `env`: shell exports for checking `direxio-mcp` manually.

S6 writes only the snippet selected for the detected runtime. Dedicated snippets are used for Codex, Cursor, OpenClaw, and Hermes; other MCP-capable supported runtimes receive the generic `mcp-servers.json`. The selected snippet runs the service-scoped `direxio-mcp` directly over stdio and sets:

```bash
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json
DIREXIO_AGENT_NODE_ID=__AGENT_NODE_ID__
```

This is intentionally separate from the `direxio-connect` bridge. MCP uses the deployer credential file; direxio-connect uses a direct Matrix Client-Server session in `direxio-connect/config.toml`.
Generated MCP client snippets launch the service-scoped `direxio-mcp` command directly over stdio. MCP does not require a local daemon, Streamable HTTP proxy endpoint, or listening port.
Cursor can load the generated MCP server after the snippet is added to `.cursor/mcp.json` or `~/.cursor/mcp.json`, but Cursor may require a full restart or MCP settings reload/enable before the server starts and tools appear.

Install and check the MCP package:

```bash
npm install --prefix ~/.direxio/nodes/<service_id>/mcp direxio-mcp@latest
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json ~/.direxio/nodes/<service_id>/mcp/direxio-mcp doctor --json
```

## direxio-connect Matrix Bridge

S6 calls `agent.matrix_session.create` with the backend `agent_token`, not the owner `access_token`. Current message-server builds must return a Matrix session for `@agent:<server>`, not for `@owner:<server>`. S6 retries transient HTTP 000/404/408/409/425/429/5xx responses before failing, because the Matrix action can become reachable after `/healthz`; defaults are 12 attempts with exponential backoff capped by `DIREXIO_MATRIX_SESSION_RETRY_MAX_INTERVAL`. The resulting session is stored at:

```text
~/.direxio/nodes/<service_id>/direxio-connect/matrix-session.json
```

S6 then writes:

```text
~/.direxio/nodes/<service_id>/direxio-connect/config.toml
```

The config uses:

- `type = "matrix"` only.
- `homeserver` from the deployed Direxio domain.
- `access_token`, `device_id`, and `user_id` from `agent.matrix_session.create`.
- `room_id` from the real backend-created `agent_room_id`.
- `admin_from = "@owner:<server>"` at the project level, so only the portal owner can run privileged commands such as `/dir` and `/shell`.
- `share_session_in_channel = true` and `group_reply_all = true` for agent-room conversation continuity.
- `auto_join = false` and `auto_verify = false`; message-server creates and joins the real room.
- `[speech]` is generated and enabled automatically when S6 can find a speech-to-text API key. Without a key, voice input is not enabled and `direxio-connect` will answer voice messages with its speech configuration warning.

`/dir reset` is expected to restore the generated `work_dir` and remove the current project directory override from `direxio-connect/data/projects/<project>.state.json`.

## Install Parameters

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_CONNECT_AGENT=<optional direxio-connect agent>
DIREXIO_AGENT_INSTALL=skip|recommend|auto
DIREXIO_AGENT_INSTALL_MODE=recommended|direxio-connect
DIREXIO_LOCAL_PATH_STYLE=posix|windows
DIREXIO_CONNECT_AGENT_CMD=<optional agent executable path>
DIREXIO_<AGENT>_COMMAND=<optional agent-specific executable path>
DIREXIO_CONNECT_AGENT_OPTIONS_TOML=<optional extra TOML under projects.agent.options>
DIREXIO_OPENCLAW_COMMAND=<optional OpenClaw executable path>
DIREXIO_HERMES_COMMAND=<optional Hermes executable path>
DIREXIO_OPENCLAW_ACP_URL=<optional explicit OpenClaw gateway URL>
DIREXIO_OPENCLAW_ACP_TOKEN_FILE=<optional explicit OpenClaw ACP token file>
DIREXIO_OPENCLAW_ACP_SESSION=<optional OpenClaw ACP session; defaults to agent:main:main>
DIREXIO_OPENCLAW_ACP_ARGS_TOML=<optional OpenClaw ACP TOML array>
DIREXIO_HERMES_ACP_ARGS_TOML=<optional Hermes ACP TOML array>
DIREXIO_CONNECT_NPM_PACKAGE=direxio-connent@latest
DIREXIO_CONNECT_REPO=https://github.com/YingSuiAI/direxio-connect.git
DIREXIO_MCP_NPM_PACKAGE=direxio-mcp@latest
DIREXIO_MCP_COMMAND=direxio-mcp
DIREXIO_SPEECH_PROVIDER=openai|groq|qwen|gemini
DIREXIO_SPEECH_API_KEY=<optional generic STT key>
DIREXIO_SPEECH_BASE_URL=<optional OpenAI-compatible STT base URL>
DIREXIO_SPEECH_MODEL=<optional STT model>
DIREXIO_SPEECH_LANGUAGE=zh
```

Defaults:

- `DIREXIO_CONNECT_AGENT` is the preferred explicit selector. It accepts every direxio-connect agent: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- `DIREXIO_AGENT_PLATFORM=auto` detects the local agent runtime and maps it to a `direxio-connect` agent type only when it can identify one unambiguously. OpenClaw and Hermes map to the generic `acp` connect agent. OpenClaw uses `openclaw acp --session agent:main:main` by default and lets OpenClaw discover its Gateway config; Hermes uses the `direxio-connect hermes-acp-adapter -- hermes acp` compatibility wrapper by default.
- `DIREXIO_LOCAL_PATH_STYLE=windows` writes Windows-compatible `data_dir`, `work_dir`, config paths, and install commands. `scripts/orchestrate.ps1` sets this automatically. Linux, macOS, and WSL Bash runs should leave the default `posix` style. Windows Git Bash/MSYS2 users who run `scripts/orchestrate.sh` directly must set `DIREXIO_LOCAL_PATH_STYLE=windows` when the local bridge is a Windows process.
- `DIREXIO_CONNECT_AGENT_CMD` writes `cmd = "<path>"` into `[projects.agent.options]`. Agent-specific forms such as `DIREXIO_CODEX_COMMAND`, `DIREXIO_CLAUDE_CODE_COMMAND`, `DIREXIO_GEMINI_COMMAND`, `DIREXIO_OPENCODE_COMMAND`, `DIREXIO_QODERCLI_COMMAND`, and `DIREXIO_OPENCLAW_COMMAND` are also accepted. For Hermes, `DIREXIO_HERMES_COMMAND` selects the child Hermes executable behind the adapter, while `DIREXIO_HERMES_ACP_ADAPTER_COMMAND` overrides the adapter command itself.
- S6 writes `mode = "yolo"` by default under `[projects.agent.options]` for generated agent configs. A `mode` supplied through `DIREXIO_CONNECT_AGENT_OPTIONS_TOML` or `DIREXIO_CURSOR_MODE` overrides this default.
- Windows Cursor wiring uses Cursor Agent CLI, not Cursor Desktop CLI. S6 looks for `%LOCALAPPDATA%\cursor-agent\agent.cmd` and writes that as `cmd`. Set `DIREXIO_CURSOR_AGENT_COMMAND`, `DIREXIO_CURSOR_COMMAND`, `DIREXIO_CONNECT_AGENT_CMD`, `DIREXIO_CURSOR_MODE`, or `DIREXIO_CONNECT_AGENT_OPTIONS_TOML` to override defaults. If `agent.cmd status` is not logged in, run `agent.cmd login` once and rerun the deployer; S6 will refresh config and reinstall the daemon.
- `DIREXIO_CONNECT_AGENT_OPTIONS_TOML` appends agent-specific options under `[projects.agent.options]`; use it for agents with required non-command options such as `reasonix` (`serve_url`) or `tmux` (`session`).
- OpenClaw Gateway ACP auto-detects the Gateway from `~/.openclaw/openclaw.json` when `DIREXIO_OPENCLAW_ACP_URL` and `DIREXIO_OPENCLAW_ACP_TOKEN_FILE` are unset. It uses `DIREXIO_OPENCLAW_ACP_SESSION` when provided, otherwise `agent:main:main`. To force explicit Gateway settings, complete OpenClaw pairing first and set all three real values: `DIREXIO_OPENCLAW_ACP_URL`, `DIREXIO_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXIO_OPENCLAW_ACP_SESSION`.
- `DIREXIO_OPENCLAW_ACP_ARGS_TOML` replaces the generated OpenClaw ACP args array, for example `["acp", "--url", "wss://gateway.example.test:18789", "--token-file", "$HOME/.openclaw/gateway.token", "--session", "agent:main:main"]`. `DIREXIO_HERMES_ACP_ARGS_TOML` supplies the child Hermes args; S6 prefixes `["hermes-acp-adapter", "--", "<hermes-command>"]` automatically.
- `DIREXIO_AGENT_INSTALL=auto` is the default. It installs `direxio-connent@latest` and `direxio-mcp@latest` under the current service directory unless explicit binary/command overrides are set. It installs the `direxio-connect` daemon with the generated config and `--service-name <service_id>`. direxio-connect is recorded as installed only when `direxio-connect daemon status --service-name <service_id>` reports `Status: Running` and recent daemon logs show `direxio-connect is running`. Logs that show local agent backend failures such as missing CLI, missing login/auth, workspace trust prompts, ACP session initialization failure, or agent offline state make S6 fail with `connect_install_status=install_failed`. MCP records `mcp_install_status=installed` when the service-scoped stdio command is available.
- `DIREXIO_AGENT_INSTALL=recommend` prints and records commands only. `verify runtime` records the daemon check as `manual_pending` in this mode and still verifies MCP doctor/tools/smoke when the MCP command is available.
- `DIREXIO_AGENT_INSTALL_MODE=recommended` maps every supported local runtime to `direxio-connect`.
- Speech defaults to `DIREXIO_SPEECH_PROVIDER=openai` and `DIREXIO_SPEECH_LANGUAGE=zh`. Provider-specific keys are also accepted: `DIREXIO_SPEECH_OPENAI_API_KEY` or `OPENAI_API_KEY`, `DIREXIO_SPEECH_GROQ_API_KEY` or `GROQ_API_KEY`, `DIREXIO_SPEECH_QWEN_API_KEY` or `DASHSCOPE_API_KEY`, and `DIREXIO_SPEECH_GEMINI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY`. Set `DIREXIO_SPEECH_ENABLED=false` to suppress speech config generation even when a key exists.

Manual command:

```bash
npm install --prefix ~/.direxio/nodes/<service_id>/direxio-connect direxio-connent@latest
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/direxio-connect/config.toml --service-name <service_id> --force
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon status --service-name <service_id>
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon logs --service-name <service_id> -n 120
```

Source fallback:

```bash
git clone https://github.com/YingSuiAI/direxio-connect.git
cd connect
make build AGENTS=<direxio-connect-agent> PLATFORMS_INCLUDE=matrix
./direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/direxio-connect/config.toml --service-name <service_id> --force
```

## State Fields

S6 records these bridge-related fields in `state.json`:

```text
agent_runtime
connect_install_policy
connect_install_mode
connect_install_command
connect_install_status
agent_node_id
agent_service_id
agent_service_dir
agent_credentials_file
agent_env_file
agent_workspace
agent_skill_install_path
agent_global_skill_install_path
direxio_agent_bridge
connect_agent
connect_agent_cmd
connect_agent_options_toml_present
connect_npm_package
connect_repo
connect_ref
connect_source_dir
connect_runtime_dir
connect_config
connect_binary
connect_data_dir
connect_matrix_session_file
connect_matrix_user
connect_matrix_device
connect_matrix_homeserver
mcp_npm_package
mcp_command
mcp_server_name
mcp_config_dir
mcp_credentials_file
mcp_codex_config
mcp_cursor_config
mcp_openclaw_config
mcp_hermes_config
mcp_json_config
mcp_env_file
mcp_readme
mcp_install_command
mcp_doctor_command
```
