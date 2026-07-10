# Remote MCP Connect Contract

**Date:** 2026-07-10
**Status:** Approved for implementation

## Objective

Make `dirextalk-connect` the single owner of agent-specific remote MCP
injection while `dirextalk-deployer` owns deployment, service credentials,
service-scoped installation, and runtime verification. Retire the local
`dirextalk-mcp` CLI/daemon/proxy path without replacing it with another local
gateway.

## Product Contract

### Server shape

- The only Dirextalk MCP endpoint is `POST https://<domain>/mcp`.
- The transport is Streamable HTTP.
- Authentication uses `Authorization: Bearer <agent_token>`.
- `DIREXTALK-Agent-Node-Id: <node_id>` is sent when a node id is available.
- No local Dirextalk MCP listener, stdio proxy, daemon, scheduled task,
  LaunchAgent, or user systemd unit is installed.

### Deployer ownership

`dirextalk-deployer`:

- deploys and verifies the remote message server;
- creates the Matrix agent session and service-scoped credentials;
- writes the canonical MCP URL, server name, agent token, and node id into
  `dirextalk-connect/config.toml`;
- installs, starts, and verifies the service-scoped connect daemon;
- reports a runtime as MCP-capable only when the selected connect backend has
  an explicit capability entry;
- does not silently mutate an agent's user-global MCP configuration;
- does not generate a generic MCP artifact and imply that every runtime will
  consume it.

Legacy state-field deletion remains as migration cleanup for at least one
release cycle. Legacy env/profile artifacts that have no current consumer stop
being generated.

### Connect ownership

`dirextalk-connect`:

- validates partial MCP configuration instead of silently disabling it;
- converts the canonical MCP description to the selected agent's official
  schema;
- prefers session/process-scoped injection and temporary files;
- never writes test data outside an explicitly isolated test root;
- fails closed when a backend cannot safely consume remote HTTP MCP;
- distinguishes agent transport (`stdio`, ACP, HTTP API, tmux) from MCP
  transport.

The capability vocabulary is:

| Capability | Meaning |
| --- | --- |
| `session` | Official per-session or per-process remote HTTP MCP injection. |
| `project` | Official project-scoped configuration; the operator is warned about persisted credentials. |
| `host-managed` | The host runtime must be configured outside an ACP/session request. |
| `conditional` | Support requires a named extension or wrapper that connect can detect. |
| `unsupported` | Connect rejects MCP configuration with an actionable error. |

No unknown backend falls back to a generic JSON file.

### Known capability exceptions

- OpenClaw ACP rejects per-session `mcpServers`; it is `host-managed`.
  Automatic host enrollment requires a separate explicit opt-in and must not
  place bearer tokens in process arguments.
- Pi has no built-in MCP client; it is `conditional` on a supported extension.
- tmux is a terminal transport, not an MCP client; it is `conditional` on a
  declared MCP-consuming wrapper/init command.
- Reasonix HTTP service mode is not allowed to rely on a local `.mcp.json` that
  the remote service cannot see.
- ACP backends send the standard `mcpServers` field only after the agent
  advertises HTTP MCP capability.

## Platform Contract

- Windows native PowerShell, Windows Git Bash/MSYS2, Linux, and macOS are
  product execution environments.
- WSL is a distinct POSIX runtime and never substitutes for Windows-native
  verification.
- Remote deployment hosts remain Linux.
- Paths are formatted for the process that consumes them, not the shell that
  generated them.
- Windows recommendations are valid PowerShell; POSIX recommendations are
  valid Bash.
- macOS scripts remain compatible with the system Bash 3.2 unless a newer Bash
  requirement is explicitly introduced and documented.

## Test Isolation Contract

Any test that may resolve or write a home/config path must redirect and verify
all relevant roots, including:

- `HOME`, `USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`;
- `APPDATA`, `LOCALAPPDATA`, `XDG_CONFIG_HOME`;
- `DIREXTALK_HOME` and runtime-specific homes/config paths.

Tests must assert that every write target is inside the temporary root. On
Windows, tests do not use POSIX mode-bit equality as proof of ACL security.
Repository CI verifies that sentinel user-config files outside the temporary
root are unchanged.

## Verification Contract

1. Unit tests validate canonical config, each backend schema, partial-config
   errors, and failure propagation.
2. Strict fake agents validate ACP capability negotiation and generated CLI
   arguments without accepting unknown fields.
3. A local fake Streamable HTTP MCP endpoint validates initialize,
   `tools/list`, and one tool call for supported adapters where practical.
4. CI runs the MCP contract on `windows-latest`, `ubuntu-latest`, and
   `macos-latest`.
5. Deployer CI separately exercises native PowerShell, Git Bash, Linux Bash,
   and macOS Bash; WSL evidence is labeled separately.
6. Release verification checks package version, tag, GitHub release/assets,
   npm metadata, `npm pack`, and a real temporary install.

## Cross-project behavior

- Matrix agent-room identity, room restriction, sync, timeline, and UI behavior
  do not change.
- The message-server remains the source of truth for `POST /mcp`.
- `dirextalk-web-deployer` must vendor the current HTTP MCP acceptance path and
  must not call removed fixed `mcp.*` P2P actions.
- The old Agent plugin and the unrelated admin console MCP feature are not
  silently removed as part of the two-repository implementation. The Agent
  plugin retirement is a separate reviewed change; the admin feature is out of
  scope.

## Retirement contract

- Active workspace indexes, commands, and agent routing stop listing
  `dirextalk-mcp` as an active project.
- Historical design documents are retained only with an explicit superseded
  marker.
- The old repository receives a tombstone README and cross-platform migration
  guidance before npm deprecation and GitHub archival.
- npm deprecation, publishing a tombstone release, and GitHub archival are
  external release actions and require explicit execution approval.
- The local clone is removed only after active code paths and migration needs
  are resolved.
