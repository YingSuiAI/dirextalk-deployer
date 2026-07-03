# Agent Runtime Notes

This skill is runtime-neutral. Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, and other shell-capable agents should use the same root entrypoint:

```text
SKILL.md
```

When an agent runtime supports skill metadata, point it at `SKILL.md` and use `scripts/orchestrate.sh` as the deployment command. Read `references/agent-targets.md` before installing this skill or wiring the local `dirextalk-connect` bridge and `dirextalk-mcp` snippets for a runtime. S6 writes current Dirextalk bridge/MCP variables and records the detected runtime plus target paths. After deployment, ask the user before mutating the runtime-specific local bridge or MCP configuration.

Recognition keywords:

- deploy Dirextalk
- resume Dirextalk deployment
- verify Dirextalk message server
- destroy Dirextalk AWS resources
- wire Dirextalk connect bridge
- refresh Dirextalk MCP snippets
- refresh Dirextalk agent token

Required capabilities:

- Read local files.
- Run POSIX shell commands.
- Use `aws`, `ssh`, `scp`, `curl`, and Node.js for `scripts/json.mjs` after the user approves any missing installs.
- Preserve secrets outside the repository.
