# Runtime Wiring

After deployment, S6 writes service-scoped files under:

```text
~/.direxio/nodes/<service_id>/
```

`service_id` is derived from the deployed service domain.

## Credentials

`credentials.json` keeps the IM login password, owner access token, agent token, and room identity:

```json
{
  "profiles": {
    "default": {
      "password": "<login-password>",
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

Treat the synced `password` and owner `access_token` as one-time/volatile values. A successful user login or token exchange can reset them on the server. Before showing a login password or using an owner `access_token` for `/_p2p/command` or Matrix Client API calls, pull the current `/opt/p2p/bootstrap.json` from the server and refresh local credentials instead of using older local output.

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
- `openclaw.mcp.json`: OpenClaw JSON snippet using `mcpServers`.
- `hermes.mcp.json`: Hermes JSON snippet using `mcpServers`.
- `mcp-servers.json`: generic JSON snippet for other MCP clients.
- `env`: shell exports for checking `direxio-mcp` manually.

All snippets run `direxio-mcp` over stdio and set:

```bash
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json
DIREXIO_AGENT_NODE_ID=__AGENT_NODE_ID__
```

This is intentionally separate from the `direxio-connect` bridge. MCP uses the deployer credential file; cc-connect uses a direct Matrix Client-Server session in `cc-connect/config.toml`.

Install and check the MCP package:

```bash
npm install -g @direxio/local-mcp@0.1.5
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json direxio-mcp doctor --json
```

## cc-connect Matrix Bridge

S6 calls `agent.matrix_session.create` with the owner token. Current message-server builds must return a Matrix session for `@agent:<server>`, not for `@owner:<server>`. The resulting session is stored at:

```text
~/.direxio/nodes/<service_id>/cc-connect/matrix-session.json
```

S6 then writes:

```text
~/.direxio/nodes/<service_id>/cc-connect/config.toml
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

`/dir reset` is expected to restore the generated `work_dir` and remove the current project directory override from `cc-connect/data/projects/<project>.state.json`.

## Install Parameters

```bash
DIREXIO_AGENT_PLATFORM=auto
DIREXIO_CC_CONNECT_AGENT=<optional cc-connect agent>
DIREXIO_AGENT_INSTALL=skip|recommend|auto
DIREXIO_AGENT_INSTALL_MODE=recommended|cc-connect
DIREXIO_LOCAL_PATH_STYLE=posix|windows
DIREXIO_CC_CONNECT_AGENT_CMD=<optional agent executable path>
DIREXIO_<AGENT>_COMMAND=<optional agent-specific executable path>
DIREXIO_CC_CONNECT_AGENT_OPTIONS_TOML=<optional extra TOML under projects.agent.options>
DIREXIO_OPENCLAW_COMMAND=<optional OpenClaw executable path>
DIREXIO_HERMES_COMMAND=<optional Hermes executable path>
DIREXIO_OPENCLAW_ACP_URL=<optional OpenClaw gateway URL>
DIREXIO_OPENCLAW_ACP_TOKEN_FILE=<optional OpenClaw ACP token file>
DIREXIO_OPENCLAW_ACP_ARGS_TOML=<optional OpenClaw ACP TOML array>
DIREXIO_HERMES_ACP_ARGS_TOML=<optional Hermes ACP TOML array>
DIREXIO_CC_CONNECT_NPM_PACKAGE=@direxio/connent@1.3.7
DIREXIO_CC_CONNECT_REPO=https://github.com/YingSuiAI/connect.git
DIREXIO_MCP_NPM_PACKAGE=@direxio/local-mcp@0.1.5
DIREXIO_MCP_COMMAND=direxio-mcp
DIREXIO_SPEECH_PROVIDER=openai|groq|qwen|gemini
DIREXIO_SPEECH_API_KEY=<optional generic STT key>
DIREXIO_SPEECH_BASE_URL=<optional OpenAI-compatible STT base URL>
DIREXIO_SPEECH_MODEL=<optional STT model>
DIREXIO_SPEECH_LANGUAGE=zh
```

Defaults:

- `DIREXIO_CC_CONNECT_AGENT` is the preferred explicit selector. It accepts every connent/connect agent: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- `DIREXIO_AGENT_PLATFORM=auto` detects the local agent runtime and maps it to a `direxio-connect` agent type only when it can identify one unambiguously. OpenClaw and Hermes map to the generic `acp` connect agent with default `args = ["acp"]`.
- `DIREXIO_LOCAL_PATH_STYLE=windows` writes Windows-compatible `data_dir`, `work_dir`, config paths, and install commands. `scripts/orchestrate.ps1` sets this automatically. Linux, macOS, and WSL Bash runs should leave the default `posix` style. Windows Git Bash/MSYS2 users who run `scripts/orchestrate.sh` directly must set `DIREXIO_LOCAL_PATH_STYLE=windows` when the local bridge is a Windows process.
- `DIREXIO_CC_CONNECT_AGENT_CMD` writes `cmd = "<path>"` into `[projects.agent.options]`. Agent-specific forms such as `DIREXIO_CODEX_COMMAND`, `DIREXIO_CLAUDE_CODE_COMMAND`, `DIREXIO_GEMINI_COMMAND`, `DIREXIO_OPENCODE_COMMAND`, `DIREXIO_QODERCLI_COMMAND`, `DIREXIO_OPENCLAW_COMMAND`, and `DIREXIO_HERMES_COMMAND` are also accepted.
- `DIREXIO_CC_CONNECT_AGENT_OPTIONS_TOML` appends agent-specific options under `[projects.agent.options]`; use it for agents with required non-command options such as `reasonix` (`serve_url`) or `tmux` (`session`).
- OpenClaw Gateway ACP uses `DIREXIO_OPENCLAW_ACP_URL` to append `--url <url>` and `DIREXIO_OPENCLAW_ACP_TOKEN_FILE` to append `--token-file <local path>`. Complete OpenClaw pairing before installing or starting the daemon.
- `DIREXIO_OPENCLAW_ACP_ARGS_TOML` and `DIREXIO_HERMES_ACP_ARGS_TOML` replace the generated ACP args array, for example `["acp", "--url", "wss://gateway.example.test:18789"]`.
- `DIREXIO_AGENT_INSTALL=recommend` prints and records the command only.
- `DIREXIO_AGENT_INSTALL=auto` runs `npm install -g @direxio/connent@1.3.7` and then installs the `direxio-connect` daemon with the generated config and `--service-name <service_id>`. It is recorded as installed only when `direxio-connect daemon status --service-name <service_id>` reports `Status: Running`; otherwise S6 records `agent_install_status=install_failed`.
- `DIREXIO_AGENT_INSTALL_MODE=recommended` maps every supported local runtime to `cc-connect`.
- Speech defaults to `DIREXIO_SPEECH_PROVIDER=openai` and `DIREXIO_SPEECH_LANGUAGE=zh`. Provider-specific keys are also accepted: `DIREXIO_SPEECH_OPENAI_API_KEY` or `OPENAI_API_KEY`, `DIREXIO_SPEECH_GROQ_API_KEY` or `GROQ_API_KEY`, `DIREXIO_SPEECH_QWEN_API_KEY` or `DASHSCOPE_API_KEY`, and `DIREXIO_SPEECH_GEMINI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY`. Set `DIREXIO_SPEECH_ENABLED=false` to suppress speech config generation even when a key exists.

Manual command:

```bash
npm install -g @direxio/connent@1.3.7
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --service-name <service_id> --force
direxio-connect daemon status --service-name <service_id>
```

Source fallback:

```bash
git clone https://github.com/YingSuiAI/connect.git
cd connect
make build AGENTS=<cc-connect-agent> PLATFORMS_INCLUDE=matrix
./direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --service-name <service_id> --force
```

## State Fields

S6 records these bridge-related fields in `state.json`:

```text
agent_runtime
agent_install_policy
agent_install_mode
agent_install_command
agent_install_status
agent_node_id
agent_service_id
agent_service_dir
agent_credentials_file
agent_env_file
agent_workspace
agent_skill_install_path
agent_global_skill_install_path
direxio_agent_bridge
cc_connect_agent
cc_connect_agent_cmd
cc_connect_agent_options_toml_present
cc_connect_npm_package
cc_connect_repo
cc_connect_ref
cc_connect_source_dir
cc_connect_runtime_dir
cc_connect_config
cc_connect_binary
cc_connect_data_dir
cc_connect_matrix_session_file
cc_connect_matrix_user
cc_connect_matrix_device
cc_connect_matrix_homeserver
mcp_npm_package
mcp_command
mcp_server_name
mcp_config_dir
mcp_credentials_file
mcp_codex_config
mcp_openclaw_config
mcp_hermes_config
mcp_json_config
mcp_env_file
mcp_readme
mcp_install_command
mcp_doctor_command
```
