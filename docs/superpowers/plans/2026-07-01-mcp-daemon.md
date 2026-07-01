# MCP Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Direxio MCP tool surface available for generated MCP host snippets after client or machine restarts.

**Architecture:** Add a localhost Streamable HTTP daemon to `direxio-mcp`, then connect Codex, Cursor, OpenClaw, Hermes, and generic stdio snippets through a stdio proxy.

**Tech Stack:** TypeScript, Node.js HTTP, `@modelcontextprotocol/sdk`, Bash S6 deployer scripts.

---

### Task 1: Add MCP HTTP Transport

**Files:**
- Create: `../direxio-mcp/src/http-server.ts`
- Test: `../direxio-mcp/test/http-server.test.ts`

- [x] Write a failing test that connects with `StreamableHTTPClientTransport` and lists tools.
- [x] Implement `startDirexioMcpHttpServer`.
- [x] Verify `npm test -- http-server`.

### Task 2: Add MCP Daemon CLI

**Files:**
- Create: `../direxio-mcp/src/daemon.ts`
- Create: `../direxio-mcp/src/proxy.ts`
- Modify: `../direxio-mcp/src/index.ts`
- Test: `../direxio-mcp/test/daemon.test.ts`

- [x] Write failing daemon metadata/status tests.
- [x] Add `serve-http`, `proxy`, and `daemon install/status/run`.
- [x] Verify `npm test -- http-server daemon`, `npm run typecheck`, and `npm run build`.

### Task 3: Wire Deployer S6

**Files:**
- Modify: `scripts/lib/mcp-client-adapters.sh`
- Modify: `scripts/phases/s6_wire_local.sh`
- Modify: `scripts/json.mjs`
- Test: `tests/s6_wire_local_test.sh`

- [x] Add failing S6 assertions for daemon URL, install command, and generated MCP client proxy args.
- [x] Generate `mcp_daemon_*` state fields and install daemon in auto mode.
- [x] Verify `bash tests/s6_wire_local_test.sh`.

### Task 4: Document And Verify

**Files:**
- Modify: `README.md`, `README_zh.md`, `SKILL.md`, `AGENTS.md`, `references/runtime-wiring.md`, `references/agent-targets.md`
- Modify: `../direxio-mcp/README.md`, `../direxio-mcp/README_zh.md`

- [x] Document daemon install/status/proxy commands.
- [x] Run MCP and deployer verification.
- [ ] Commit both repositories.
