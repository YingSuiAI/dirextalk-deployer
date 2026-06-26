# Direxio Deployer

[简体中文](README_zh.md)

`direxio-deployer` deploys a production Direxio message server and wires the local agent room through Direxio's Matrix bridge. The supported local bridge is `direxio-connect`, installed from the npm package `@direxio/connent` or built from `YingSuiAI/connect`.

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
- S6 rejects legacy pseudo agent rooms such as `!agent:<domain>` and requires the real Matrix `agent_room_id` created by message-server.
- S6 creates an `@agent:<server>` Matrix session through `agent.matrix_session.create`, writes a Matrix-only `cc-connect/config.toml`, and restricts the bridge to the current `agent_room_id`.
- `DIREXIO_CC_CONNECT_AGENT` selects the local `direxio-connect` agent type. Supported values match connent/connect: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- Set `DIREXIO_CC_CONNECT_AGENT_CMD` or `DIREXIO_<AGENT>_COMMAND` when a local agent executable is not discoverable from PATH. Codex also supports `DIREXIO_CODEX_COMMAND` for Windows Desktop installs.
- `DIREXIO_AGENT_INSTALL=auto` installs `@direxio/connent` and runs `direxio-connect daemon install --config <config> --force`. The default `recommend` mode only records and prints the command.

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
If `DIREXIO_AGENT_PLATFORM=auto` cannot identify a single supported runtime, set `DIREXIO_CC_CONNECT_AGENT` explicitly.

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
```

Manual install:

```bash
npm install -g @direxio/connent
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --force
direxio-connect daemon status
```

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
