# Agent Runtime Notes

This skill is runtime-neutral. Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, and other shell-capable agents should use the same root entrypoint:

```text
SKILL.md
```

When an agent runtime supports skill metadata, point it at `SKILL.md`. Every supported host uses `bash scripts/orchestrate.sh`; native Windows hosts must install Git for Windows and run it from Git Bash, while native WSL runs as Linux. Read `references/agent-targets.md` before installing this skill or wiring the local `dirextalk-connect` bridge. S6 normally records capability from the effective connect agent and never falls back to generic MCP JSON. Antigravity/Cursor/iFlow and every detected OpenClaw/Hermes host are host-managed; Devin/Pi/Reasonix/tmux are unsupported and fail closed. OpenClaw and Hermes require native secret-free probes before bridge startup.

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
- Run Bash commands on Linux/macOS/WSL, or Git Bash on native Windows. Before a native Windows lifecycle or skill-install action, use the matching-install-root `MINGW*`/`cygpath`/`.windows.` Git preflight in `references/agent-targets.md`; if it fails, tell the user to install Git for Windows and stop.
- Use `aws`, `ssh`, `curl`, and Node.js for `scripts/json.mjs` after the user approves any missing installs. Go and SCP are not deployment prerequisites; the Ubuntu host downloads the pinned independent updater Release itself.
- Preserve secrets outside the repository.
