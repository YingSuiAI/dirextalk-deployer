# Direxio Deployer

[简体中文](README_zh.md)

`direxio-deployer` deploys a production Direxio message server and wires the local agent room through Direxio's Matrix bridge. The supported local bridge is `direxio-connect`, installed from the npm package `@direxio/connent@1.3.7` by default or built from `YingSuiAI/connect`. S6 also writes service-scoped MCP snippets for MCP-capable hosts such as Codex, OpenClaw, and Hermes.

## Contents

- `SKILL.md`: Agent entrypoint, confirmation rules, deployment/destroy flow, and delivery format.
- `scripts/`: State machine, AWS/EC2/DNS/cloud-init/verification/destroy scripts.
- `references/`: Tooling, deployment resume flow, cc-connect wiring, state machine, architecture, troubleshooting, and recovery notes.
- `agents/`: Runtime metadata and recognition notes for agent hosts.

## Deployment Rules

- Deploy only to a real, long-lived domain.
- Matrix `server_name` is identity; changing it later is effectively a new homeserver.
- AWS resources cost money; the user must explicitly confirm before deployment.
- User-managed DNS mode pauses after Elastic IP creation until the user updates the A record.
- The backend image is `direxio/message-server`; Matrix and P2P APIs share port 8008.
- Cloud init generates `P2P_PORTAL_PASSWORD`; `init-tokens.sh` calls `portal.bootstrap` and creates a real Matrix agent room if the backend credentials file does not already include one.
- Treat synced `password` and owner `access_token` values as one-time/volatile credentials. Pull the current server `/opt/p2p/bootstrap.json` before showing a login password or using an owner token for API calls.
- S6 rejects legacy pseudo agent rooms such as `!agent:<domain>` and requires the real Matrix `agent_room_id` created by message-server.
- S6 creates an `@agent:<server>` Matrix session through `agent.matrix_session.create`, writes a Matrix-only `cc-connect/config.toml`, and restricts the bridge to the current `agent_room_id`.
- S6 writes MCP client snippets under `~/.direxio/nodes/<service_id>/mcp/`. They point `direxio-mcp` at the same service-scoped `credentials.json` by `DIREXIO_CREDENTIALS_FILE`; cc-connect still uses its direct Matrix config.
- `DIREXIO_CC_CONNECT_AGENT` selects the local `direxio-connect` agent type. Supported values match connent/connect: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- `DIREXIO_AGENT_PLATFORM` is the host runtime following this deployer skill; `DIREXIO_CC_CONNECT_AGENT` is the backend that `direxio-connect` launches. Detected OpenClaw and Hermes runtimes are wired through the generic `acp` agent, not native `type = "openclaw"` or `type = "hermes"` connect agents. S6 writes `cmd = "openclaw"` or `cmd = "hermes"` with default `args = ["acp"]`.
- Set `DIREXIO_CC_CONNECT_AGENT_CMD` or `DIREXIO_<AGENT>_COMMAND` when a local agent executable is not discoverable from PATH. Codex also supports `DIREXIO_CODEX_COMMAND` for Windows Desktop installs; OpenClaw and Hermes support `DIREXIO_OPENCLAW_COMMAND` and `DIREXIO_HERMES_COMMAND`.
- `DIREXIO_AGENT_INSTALL=auto` installs `@direxio/connent@1.3.7` and runs `direxio-connect daemon install --config <config> --service-name <service_id> --force`. The default `recommend` mode only records and prints the command. Auto install is marked installed only when `direxio-connect daemon status --service-name <service_id>` reports `Status: Running`; otherwise S6 records `agent_install_status=install_failed`.

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

On Windows, use the PowerShell entrypoint so the deployer selects Git Bash for the cloud phases while writing Windows-compatible local `direxio-connect` paths:

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:DOMAIN_MODE = "user"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:INSTANCE_TYPE = "t3.small"
$env:MESSAGE_SERVER_IMAGE = "direxio/message-server:latest"
.\scripts\orchestrate.ps1
```

Recommendation-only local bridge wiring:

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

Automatic local bridge install:

```bash
DIREXIO_AGENT_INSTALL=auto \
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_CC_CONNECT_AGENT=claudecode \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

Supported install modes: `recommended` and `cc-connect`.
If `DIREXIO_AGENT_PLATFORM=auto` cannot identify a single supported runtime, set `DIREXIO_CC_CONNECT_AGENT` explicitly. For OpenClaw or Hermes defaults, force the host runtime with `DIREXIO_AGENT_PLATFORM=openclaw` or `DIREXIO_AGENT_PLATFORM=hermes`; setting only `DIREXIO_CC_CONNECT_AGENT=acp` selects generic ACP and requires manual options. For OpenClaw Gateway ACP, set `DIREXIO_OPENCLAW_ACP_URL` and complete OpenClaw pairing before starting the daemon. Use `DIREXIO_OPENCLAW_ACP_ARGS_TOML` or `DIREXIO_HERMES_ACP_ARGS_TOML` for custom ACP argument arrays.

Check status:

```bash
bash scripts/orchestrate.sh status
DOMAIN=<domain> bash scripts/orchestrate.sh status
```

Destroy recorded resources:

```bash
DOMAIN=<domain> bash scripts/destroy.sh
```

Destroy stops the local `direxio-connect` daemon only when its reported `WorkDir`
matches the current service's `~/.direxio/nodes/<service_id>/cc-connect`
directory, then removes that service directory.

## Local Bridge

S6 writes these service-scoped files under `~/.direxio/nodes/<service_id>/`:

```text
credentials.json
env
cc-connect/config.toml
cc-connect/data/
cc-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.mcp.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

Manual install:

```bash
npm install -g @direxio/connent@1.3.7
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --service-name <service_id> --force
direxio-connect daemon status --service-name <service_id>
```

MCP install and check:

```bash
npm install -g @direxio/local-mcp@0.1.5
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json direxio-mcp doctor --json
```

Use `mcp/codex.toml` for Codex. Use `mcp/openclaw.mcp.json` or `mcp/hermes.mcp.json` as JSON snippets for OpenClaw and Hermes.

Voice input is supported when an STT provider key is available. Set `DIREXIO_SPEECH_API_KEY` or provider-specific variables such as `DIREXIO_SPEECH_QWEN_API_KEY`; S6 will then write `[speech] enabled = true` into `cc-connect/config.toml`.

Homebrew documentation should use:

```bash
brew install direxio-connect
```

Source builds use:

```bash
git clone https://github.com/YingSuiAI/connect.git
cd connect
make build AGENTS=<cc-connect-agent> PLATFORMS_INCLUDE=matrix
```

## Validation

```bash
bash tests/skill_structure_test.sh
bash tests/default_paths_test.sh
bash tests/s6_wire_local_test.sh
bash tests/destroy_local_bridge_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```
