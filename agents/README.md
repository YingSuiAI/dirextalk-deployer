# Agent Runtime Notes

This skill is runtime-neutral. Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, and other shell-capable agents should use the same root entrypoint:

```text
SKILL.md
```

When an agent runtime supports skill metadata, point it at `SKILL.md`. POSIX hosts use `scripts/orchestrate.sh`; Windows hosts use `scripts/orchestrate.ps1`. Read `references/agent-targets.md` before installing this skill or wiring the local `dirextalk-connect` bridge. S6 normally records capability from the effective connect agent and never falls back to generic MCP JSON. Antigravity/Cursor/iFlow and every detected OpenClaw/Hermes host are host-managed; Devin/Pi/Reasonix/tmux are unsupported and fail closed. OpenClaw and Hermes require native secret-free probes before bridge startup.

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
- Run POSIX shell commands on Linux/macOS, or native PowerShell plus Git Bash on Windows.
- Use `aws`, `ssh`, `scp`, `curl`, and Node.js for `scripts/json.mjs` after the user approves any missing installs.
- Preserve secrets outside the repository.
