# Runtime Wiring

After deployment, S6 writes service-scoped files under:

```text
~/.dirextalk/nodes/<service_id>/
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
      "agent_token": "<agent-token>",
      "agent_room_id": "__ROOM_ID__",
      "agent_node_id": "__AGENT_NODE_ID__",
      "mcp_url": "https://__DOMAIN__/mcp"
    }
  }
}
```

Treat the synced `password` and owner `access_token` as one-time/volatile values. A successful App initialization or token exchange can reset them on the server. Before showing the eight-digit app initialization code or using an owner `access_token` for `/_p2p/command` or Matrix Client API calls, pull the current `/var/dirextalk-message-server/p2p/bootstrap.json` from the server and refresh local credentials instead of using older local output.

Retired service-level and MCP `env` files are no longer generated. Existing
`agent_env_file` and `mcp_env_file` state is scrubbed during S6 migration.

## MCP Tooling

S6 writes MCP snippets under the same service directory:

```text
~/.dirextalk/nodes/<service_id>/mcp/
```

Generated files:

- `openclaw.md`: host-managed guidance only. It contains no bearer token and no global mutation command.
- `hermes.md`: Hermes native-registry/profile guidance only; no token-bearing generic JSON is generated.

MCP capability is declared separately from bridge-agent support:

| Capability | Runtimes |
| --- | --- |
| `session` | ACP, Claude Code, Codex, Copilot, Gemini, Kimi, OpenCode, Qoder |
| `project` | No current backend |
| `host-managed` | Antigravity, Cursor, iFlow; every detected OpenClaw or Hermes host |
| `conditional` | No current backend |
| `unsupported` | Devin, Pi, Reasonix, tmux |

Capability is normally resolved from the effective connect agent. Detected
OpenClaw and Hermes hosts are always `host-managed`, require ACP bridging, and
reject non-ACP overrides. Their native registries own MCP. Unsupported and
unknown selections fail closed. The host
runtime still selects any standalone artifact. S6 never writes a
generic MCP JSON fallback.
MCP uses the server HTTP endpoint and service agent token. For non-host-managed
selection, S6 writes `mcp_url`, `mcp_server_name`, `mcp_agent_token`,
`mcp_node_id`, and `mcp_capability` into `dirextalk-connect/config.toml`;
dirextalk-connect owns agent-specific injection. Conditional and unsupported
selection then blocks S6 before bridge startup. For host-managed selection, S6
retains the host guidance/artifact but omits all five canonical fields from
connect options. In `auto`, it records `host_action_required` and returns
`waiting_user` before starting the bridge. After explicit host enrollment,
rerun with `DIREXTALK_MCP_HOST_READY=1`; the
OpenClaw path must then pass `openclaw mcp probe <server-name> --json` before
bridge startup and records `host_probe_passed`. The probe receives no bearer
token or credential path in argv. `OPENCLAW_CONFIG_PATH` is inherited, and
`DIREXTALK_OPENCLAW_PROFILE=<profile>` adds `--profile <profile>` for service
isolation. S6 never runs `mcp set`. Other host-managed backends with no official
probe record `operator_confirmed_host_managed`, which is not automated proof.
Hermes uses a generated per-service HERMES_HOME and profile in both the ACP
bridge args/env and `hermes -p <profile> mcp test <server-name>` probe. S6 only
creates the empty home and guidance; the operator creates/clones the profile and
enrolls native `mcp_servers` before setting the ready flag.
Generated MCP client snippets do not install or launch a local MCP CLI. MCP does not require a local daemon, proxy endpoint, or listening port.

Check MCP through the deployer runtime checks:

```bash
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_doctor
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_tools
```

## dirextalk-connect Matrix Bridge

S6 calls `agent.matrix_session.create` with the backend `agent_token`, not the owner `access_token`. Current message-server builds must return a Matrix session for `@agent:<server>`, not for `@owner:<server>`. S6 retries transient HTTP 000/404/408/409/425/429/5xx responses before failing, because the Matrix action can become reachable after `/healthz`; defaults are 12 attempts with exponential backoff capped by `DIREXTALK_MATRIX_SESSION_RETRY_MAX_INTERVAL`. The resulting session is stored at:

```text
~/.dirextalk/nodes/<service_id>/dirextalk-connect/matrix-session.json
```

S6 then writes:

```text
~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml
```

The config uses:

- `type = "matrix"` only.
- `homeserver` from the deployed Dirextalk domain.
- `access_token`, `device_id`, and `user_id` from `agent.matrix_session.create`.
- `room_id` from the real backend-created `agent_room_id`.
- `admin_from = "@owner:<server>"` at the project level, so only the portal owner can run privileged commands such as `/dir` and `/shell`.
- `share_session_in_channel = true` and `group_reply_all = true` for agent-room conversation continuity.
- `auto_join = false` and `auto_verify = false`; message-server creates and joins the real room.
- `mcp_url`, `mcp_server_name`, `mcp_agent_token`, and `mcp_node_id` under `[projects.agent.options]` for every generated connect agent.
- `[speech]` is generated and enabled automatically when S6 can find a speech-to-text API key. Without a key, voice input is not enabled and `dirextalk-connect` will answer voice messages with its speech configuration warning.

`/dir reset` is expected to restore the generated `work_dir` and remove the current project directory override from `dirextalk-connect/data/projects/<project>.state.json`.

## Install Parameters

```bash
DIREXTALK_AGENT_PLATFORM=auto
DIREXTALK_CONNECT_AGENT=<optional dirextalk-connect agent>
DIREXTALK_AGENT_INSTALL=skip|recommend|auto
DIREXTALK_AGENT_INSTALL_MODE=recommended|dirextalk-connect
DIREXTALK_LOCAL_PATH_STYLE=posix|windows
DIREXTALK_CONNECT_AGENT_CMD=<optional agent executable path>
DIREXTALK_<AGENT>_COMMAND=<optional agent-specific executable path>
DIREXTALK_CONNECT_AGENT_OPTIONS_TOML=<optional extra TOML under projects.agent.options>
DIREXTALK_OPENCLAW_COMMAND=<optional OpenClaw executable path>
DIREXTALK_HERMES_COMMAND=<optional Hermes executable path>
DIREXTALK_OPENCLAW_ACP_URL=<optional explicit OpenClaw gateway URL>
DIREXTALK_OPENCLAW_ACP_TOKEN_FILE=<optional explicit OpenClaw ACP token file>
DIREXTALK_OPENCLAW_ACP_SESSION=<optional OpenClaw ACP session; defaults to agent:main:main>
DIREXTALK_HERMES_ACP_ARGS_TOML=<optional Hermes ACP TOML array>
DIREXTALK_CONNECT_NPM_PACKAGE=dirextalk-connect@latest
DIREXTALK_CONNECT_REPO=https://github.com/YingSuiAI/dirextalk-connect.git
mcp_transport=http
mcp_endpoint_url=https://<domain>/mcp
DIREXTALK_SPEECH_PROVIDER=openai|groq|qwen|gemini
DIREXTALK_SPEECH_API_KEY=<optional generic STT key>
DIREXTALK_SPEECH_BASE_URL=<optional OpenAI-compatible STT base URL>
DIREXTALK_SPEECH_MODEL=<optional STT model>
DIREXTALK_SPEECH_LANGUAGE=zh
```

Defaults:

- `DIREXTALK_CONNECT_AGENT` is the preferred explicit selector. It accepts every dirextalk-connect agent: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- `DIREXTALK_AGENT_PLATFORM=auto` detects the local agent runtime and maps it to a `dirextalk-connect` agent type only when it can identify one unambiguously. OpenClaw and Hermes map exclusively to the generic `acp` connect agent. OpenClaw uses the same optional `--profile`/`OPENCLAW_CONFIG_PATH` scope for ACP and its native MCP probe. Hermes uses `dirextalk-connect hermes-acp-adapter -- hermes -p <service-profile> acp` with the same service HERMES_HOME as its native MCP test.
- `DIREXTALK_LOCAL_PATH_STYLE=windows` writes Windows-compatible `data_dir`, `work_dir`, config paths, and install commands. Git Bash detects Windows automatically and applies that style before invoking Windows-native Node.js or local agent processes; users should not set it manually. Linux and macOS retain the default `posix` style.
- `DIREXTALK_CONNECT_AGENT_CMD` writes `cmd = "<path>"` into `[projects.agent.options]` for direct agents. It is rejected for OpenClaw/Hermes because their host-owned bridge shape must match the native MCP profile/probe. Agent-specific forms such as `DIREXTALK_CODEX_COMMAND`, `DIREXTALK_CLAUDE_CODE_COMMAND`, `DIREXTALK_GEMINI_COMMAND`, `DIREXTALK_OPENCODE_COMMAND`, `DIREXTALK_QODERCLI_COMMAND`, and `DIREXTALK_OPENCLAW_COMMAND` are accepted in their declared scope. For Hermes, `DIREXTALK_HERMES_COMMAND` selects the child Hermes executable behind the adapter, while `DIREXTALK_HERMES_ACP_ADAPTER_COMMAND` overrides the adapter command itself.
- S6 writes `mode = "yolo"` by default under `[projects.agent.options]` for generated agent configs. A `mode` supplied through `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` or `DIREXTALK_CURSOR_MODE` overrides this default.
- Windows Cursor wiring uses Cursor Agent CLI, not Cursor Desktop CLI. S6 looks for `%LOCALAPPDATA%\cursor-agent\agent.cmd` and writes that as `cmd`. Set `DIREXTALK_CURSOR_AGENT_COMMAND`, `DIREXTALK_CURSOR_COMMAND`, `DIREXTALK_CONNECT_AGENT_CMD`, `DIREXTALK_CURSOR_MODE`, or `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` to override defaults. If `agent.cmd status` is not logged in, run `agent.cmd login` once and rerun the deployer; S6 will refresh config and reinstall the daemon.
- `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` appends agent-specific options under `[projects.agent.options]`; use it for agents with required non-command options such as `reasonix` (`serve_url`) or `tmux` (`session`).
- OpenClaw Gateway ACP auto-detects the Gateway from `~/.openclaw/openclaw.json` when `DIREXTALK_OPENCLAW_ACP_URL` and `DIREXTALK_OPENCLAW_ACP_TOKEN_FILE` are unset. It uses `DIREXTALK_OPENCLAW_ACP_SESSION` when provided, otherwise `agent:main:main`. To force explicit Gateway settings, complete OpenClaw pairing first and set all three real values: `DIREXTALK_OPENCLAW_ACP_URL`, `DIREXTALK_OPENCLAW_ACP_TOKEN_FILE`, and `DIREXTALK_OPENCLAW_ACP_SESSION`.
- A fully replaceable OpenClaw args array is intentionally unsupported. Use the discrete URL, token-file, session, and profile variables so `acp` and session structure cannot be removed. `DIREXTALK_HERMES_ACP_ARGS_TOML` supplies child Hermes args; S6 prefixes `["hermes-acp-adapter", "--", "<hermes-command>", "-p", "<profile>"]` automatically.
- `DIREXTALK_AGENT_INSTALL=auto` is the default. It installs `dirextalk-connect@latest` under the current service directory unless explicit binary/command overrides are set. It installs the `dirextalk-connect` daemon with the generated config and `--service-name <service_id>`. dirextalk-connect is recorded as installed only when `dirextalk-connect daemon status --service-name <service_id>` reports `Status: Running` and recent daemon logs show `dirextalk-connect is running`. Logs that show local agent backend failures such as missing CLI, missing login/auth, workspace trust prompts, ACP session initialization failure, or agent offline state make S6 fail with `connect_install_status=install_failed`. MCP records `mcp_install_status=not_required` in the default HTTP endpoint path.
- `DIREXTALK_AGENT_INSTALL=recommend` prints and records commands only. `verify runtime` records the daemon check as `manual_pending` in this mode and still verifies MCP doctor/tools/smoke when the MCP command is available.
- `DIREXTALK_AGENT_INSTALL_MODE=recommended` maps every supported local runtime to `dirextalk-connect`.
- Speech defaults to `DIREXTALK_SPEECH_PROVIDER=openai` and `DIREXTALK_SPEECH_LANGUAGE=zh`. Provider-specific keys are also accepted: `DIREXTALK_SPEECH_OPENAI_API_KEY` or `OPENAI_API_KEY`, `DIREXTALK_SPEECH_GROQ_API_KEY` or `GROQ_API_KEY`, `DIREXTALK_SPEECH_QWEN_API_KEY` or `DASHSCOPE_API_KEY`, and `DIREXTALK_SPEECH_GEMINI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY`. Set `DIREXTALK_SPEECH_ENABLED=false` to suppress speech config generation even when a key exists.

Linux/macOS Bash manual command:

```bash
npm install --prefix ~/.dirextalk/nodes/<service_id>/dirextalk-connect dirextalk-connect@latest
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon status --service-name <service_id>
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon logs --service-name <service_id> -n 120
```

Windows Git Bash manual command:

```bash
service_dir=$(cygpath -m "$HOME/.dirextalk/nodes/<service_id>")
runtime_dir="$service_dir/dirextalk-connect"
connect="$runtime_dir/dirextalk-connect.cmd"
npm install --prefix "$runtime_dir" dirextalk-connect@latest
"$connect" daemon install --config "$runtime_dir/config.toml" --service-name <service_id> --force
"$connect" daemon status --service-name <service_id>
"$connect" daemon logs --service-name <service_id> -n 120
```

Source fallback:

```bash
git clone https://github.com/YingSuiAI/dirextalk-connect.git
cd connect
make build AGENTS=<dirextalk-connect-agent> PLATFORMS_INCLUDE=matrix
./dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force
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
agent_workspace
agent_skill_install_path
agent_global_skill_install_path
dirextalk_agent_bridge
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
connect_mcp_url
connect_mcp_server_name
connect_mcp_capability
mcp_transport
mcp_capability
mcp_endpoint_url
mcp_server_name
mcp_config_dir
mcp_credentials_file
mcp_openclaw_config
mcp_hermes_config
mcp_hermes_home
mcp_hermes_profile
mcp_host_probe_status
mcp_readme
mcp_install_command
mcp_doctor_command
```
