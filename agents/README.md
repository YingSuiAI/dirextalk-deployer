# Agent Runtime Notes

This skill is runtime-neutral. Claude, Codex/OpenAI, Gemini, Cursor, Copilot, OpenClaw, Hermes, and other shell-capable agents should use the same root entrypoint:

```text
SKILL.md
```

When an agent runtime supports skill metadata, point it at `SKILL.md`. POSIX hosts use `scripts/orchestrate.sh`; Windows hosts use `scripts/orchestrate.ps1`. Read `references/agent-targets.md` only for explicit skill installation or local bridge targeting, and `references/runtime-wiring.md` for current capability details. Capability is explicit and never falls back to generic MCP configuration.

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
- Use `aws`, `ssh`, `curl`, and Node.js for `scripts/json.mjs` after the user approves any missing installs. Go and SCP are not deployment prerequisites; the Ubuntu host downloads the pinned independent updater Release itself.
- Preserve secrets outside the repository.
