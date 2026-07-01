# Agent Runtime Notes

This skill is runtime-neutral. Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, and other shell-capable agents should use the same root entrypoint:

```text
SKILL.md
```

When an agent runtime supports skill metadata, point it at `SKILL.md` and use `scripts/orchestrate.sh` as the deployment command. Read `references/agent-targets.md` before installing this skill or wiring the local `direxio-connect` bridge and `direxio-mcp` snippets for a runtime. S6 writes current Direxio bridge/MCP variables and records the detected runtime plus target paths. After deployment, ask the user before mutating the runtime-specific local bridge or MCP configuration.

Recognition keywords:

- deploy Direxio
- resume Direxio deployment
- verify Direxio message server
- destroy Direxio AWS resources
- wire Direxio connect bridge
- refresh Direxio MCP snippets
- refresh Direxio agent token

Required capabilities:

- Read local files.
- Run POSIX shell commands.
- Use `aws`, `ssh`, `scp`, `curl`, and Node.js for `scripts/json.mjs` after the user approves any missing installs.
- Preserve secrets outside the repository.
