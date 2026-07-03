# MCP Daemon Design

## Problem

Hermes and other MCP hosts commonly launch MCP through a stdio child process.
After a machine or host-client restart, users can find that the Dirextalk MCP tool
surface is no longer present. Running the existing `dirextalk-mcp` stdio process
as a generic background task is not enough, because stdio MCP must be connected
by the host client.

## Design

`dirextalk-mcp` now exposes a service-scoped local daemon:

- `dirextalk-mcp serve-http` serves the same MCP tools over localhost Streamable
  HTTP.
- `dirextalk-mcp daemon install/status/run` manages service metadata and
  platform autostart.
- `dirextalk-mcp proxy --url <local-daemon-url>` keeps a stdio-compatible entry
  for hosts that still expect to launch an MCP child process.

S6 generates Codex, Cursor, OpenClaw, Hermes, and generic stdio snippets that
all use the stdio proxy. Each host client starts a lightweight proxy process,
while the service-scoped daemon owns the real MCP server state and survives
client restarts. `DIREXTALK_AGENT_INSTALL=auto` installs both
`dirextalk-mcp@latest` and the service-scoped MCP daemon.

## Verification

Target checks:

- `npm test`, `npm run typecheck`, and `npm run build` in `dirextalk-mcp`.
- A local daemon smoke that installs with platform registration disabled,
  checks `/healthz`, and lists MCP tools over Streamable HTTP.
- `bash tests/s6_wire_local_test.sh` in `dirextalk-deployer`.
