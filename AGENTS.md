# AGENTS.md

`dirextalk-deployer` is a cross-platform deployment product and agent skill, not a Linux-only script collection. Maintain it as a portable orchestration layer that can be driven from Windows PowerShell, Git Bash/MSYS2, Linux, and macOS while deploying a Linux-based Dirextalk server.

## Product Scope

- Deploy, resume, verify, destroy, and locally wire a production Dirextalk message server.
- Install the independently released `YingSuiAI/dirextalk-updater` host binary from the deployer-owned immutable version/commit/SHA pin. The deployer does not embed or build updater Go source.
- Treat `SKILL.md` as the compact agent-facing entrypoint. Detailed runbooks belong in `references/`; `scripts/` are the stable implementation entrypoints.
- The supported local conversation bridge is `dirextalk-connect`, installed from `dirextalk-connect@latest` by default or built from `YingSuiAI/dirextalk-connect`.
- MCP support is capability-driven and is separate from bridge-agent support. Declared MCP consumers connect directly to the deployed message server's HTTP endpoint; unknown runtimes never receive a generic fallback.
- Supported local agent targets are the dirextalk-connect agent providers, treated as peers: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- Do not reintroduce legacy local gateway installation flows or third-party chat platform wiring.
- Do not hard-code one developer's home directory, shell, agent executable path, AWS region, domain, node id, token, or password.

## Platform Law

Every deployer change must classify paths and commands by the platform that will consume them:

- **Remote server paths** are Linux paths inside EC2/cloud-init/Docker, such as `/var/dirextalk-message-server`, `/var/dirextalk-message-server/p2p/bootstrap.json`, and `/etc/dirextalk-message-server`.
- **Deployer execution paths** are used by the orchestration engine. Bash phase scripts can use POSIX paths, but PowerShell entrypoints must convert Windows paths before invoking Bash.
- **Local bridge paths** are consumed by `dirextalk-connect` and the local agent process. On Windows they must be Windows-compatible paths, not `/mnt/c/...` or Git Bash-only `/c/...` paths.
- **Documentation paths** must be portable examples using `$HOME`, `%USERPROFILE%`, `$env:USERPROFILE`, `<service_id>`, or `<domain>`, not machine-specific absolute paths.

If a change writes a path into `state.json`, `credentials.json`, `dirextalk-connect/config.toml`, docs, or printed commands, verify which process will read that path and format it for that process. Do not generate an artifact without a current consumer.
Use `scripts/lib/local-paths.sh` for Bash-side local path conversion and `scripts/lib/windows-paths.ps1` for PowerShell wrapper conversion. These helpers must lexically recognize `C:\Users\alice`, `C:/Users/alice`, `/mnt/c/Users/alice`, `/cygdrive/c/Users/alice`, and `/c/Users/alice` before calling shell-specific conversion tools.

## Entrypoints

- POSIX users run `bash scripts/orchestrate.sh`.
- Windows users run `.\scripts\orchestrate.ps1` from PowerShell. The wrapper may use Git Bash internally for existing Bash phases, but it must set Windows-local wiring variables such as `DIREXTALK_LOCAL_PATH_STYLE=windows`.
- POSIX users run `bash scripts/destroy.sh`; Windows users run `.\scripts\destroy.ps1`.
- Do not tell Windows users to run WSL unless the user explicitly chooses WSL as the host runtime. WSL and Windows are different local runtimes with different home directories, PATH lookup, daemon process control, and agent executable paths.
- Keep `scripts/orchestrate.sh` and `scripts/orchestrate.ps1` behaviorally aligned for status, deploy/resume, and local bridge wiring.

## Script Architecture

- Keep the state-machine phases idempotent and resumable. A phase should be safe to rerun after token refresh, DNS wait, or partial local wiring.
- Shell phase files should expose `run_phase` and use `state_get`, `state_set`, and `phase_set` instead of ad hoc state edits.
- Prefer small helpers for platform conversion, command discovery, and output formatting. Do not scatter OS-specific path rewrites across phase bodies.
- Use `scripts/json.mjs` through `scripts/lib/json.sh` for JSON reads/writes. Do not reintroduce legacy external JSON CLI dependencies.
- Remote server commands may assume Linux because the EC2 host is Linux. Local commands must not assume Linux.
- Version 1 cloud hosts may run Ubuntu 22.04 or 24.04 on x86_64. New cloud hosts still default to Ubuntu 24.04; bootstrap must verify the supported host set before downloading the pinned updater or starting Compose.
- Pre-updater d1 adoption is never inferred by normal resume. Use only `scripts/adopt-legacy-node.sh` after its fixed v0.15.2/digest/Compose/systemd-Caddy dry run and exact confirmation; it must not pull or recreate the running image.
- Use PowerShell for Windows-native process and path behavior when the consumer is Windows-local, especially `dirextalk-connect.exe`, local agent executables, Windows user profile paths, or npm global binaries.
- When adding a new local runtime or agent executable, support explicit override env vars before detection. For connect this includes `DIREXTALK_CONNECT_AGENT`, `DIREXTALK_CONNECT_AGENT_CMD`, and runtime-specific aliases such as `DIREXTALK_CODEX_COMMAND`, `DIREXTALK_GEMINI_COMMAND`, or `DIREXTALK_CLAUDE_CODE_COMMAND`. Host-owned OpenClaw/Hermes bridges reject generic child command/args overrides.
- Do not make Codex, Claude, Gemini, Cursor, or any other provider the semantic default for an unknown runtime. Unknown or ambiguous detection should require an explicit `DIREXTALK_CONNECT_AGENT`.

## Dirextalk Connect Wiring

- S5/S6 must fail closed when `agent_room_id` is missing or uses a legacy pseudo id such as `!agent:<domain>`.
- S6 must create a Matrix session through `agent.matrix_session.create` using `agent_token`, not owner `access_token`, and require `@agent:<server>` for the bridge. Returning `@owner:<server>` is a server-side compatibility failure.
- The generated dirextalk-connect config must contain one Matrix platform and must restrict sync/replies to the real `agent_room_id`.
- The generated agent config must preserve the selected connect agent type and optional agent-specific TOML. Some providers require more than `cmd`; for example `reasonix` needs `serve_url`, `tmux` needs `session`, and generic `acp` may need command/args.
- `DIREXTALK_AGENT_INSTALL=auto` is the default and installs `dirextalk-connect@latest` into the current service directory, not into the npm global prefix, unless an explicit binary/command override is set. It installs the service-scoped `dirextalk-connect` daemon. The canonical MCP description points to the deployed message server HTTP MCP endpoint; do not install or launch a local MCP CLI, daemon, proxy, or listening port.
- Keep the declarative MCP registry aligned with dirextalk-connect. Resolve capability from the effective connect agent except that detected OpenClaw and Hermes hosts own authoritative native MCP registries and are always `host-managed`. They require the ACP bridge; reject non-ACP `DIREXTALK_CONNECT_AGENT` overrides. Antigravity, Cursor, and iFlow are also `host-managed`; Pi, tmux, Devin, and Reasonix are `unsupported`. Unsupported and unknown runtimes fail closed. Do not generate a generic JSON artifact.
- Host-runtime artifact selection is separate from effective connect-agent capability. Preserve reviewable host guidance, but omit canonical MCP fields from host-managed connect options. With `auto`, require explicit host enrollment plus `DIREXTALK_MCP_HOST_READY=1` before starting the bridge. OpenClaw must then pass `openclaw mcp probe <server-name> --json`; Hermes must pass the service-isolated `hermes -p <profile> mcp test <server-name>`. Neither probe receives secrets in argv. Other host-managed backends remain explicitly operator-confirmed when no official probe exists.
- `recommend` must only write files and print commands; `skip` writes credentials, connect config, and canonical MCP artifacts only. S6 must not recreate the retired service-level `env` file.
- Do not pin old package versions in runtime defaults. Keep `@latest` defaults and preserve env overrides only for explicit debugging or rollback.

## Secrets And State

- Never print, commit, or paste AWS secrets, the eight-digit app initialization code, Matrix access tokens, `agent_token`, private keys, or full credential files.
- When verifying credentials, print booleans or identities only, such as `has_access_token=true`, `user_id`, `device_id`, and `homeserver`.
- `credentials.json`, Matrix session files, SSH keys, and generated env files must stay outside the repository and should be written with restrictive permissions when the platform supports it.
- Write generated credentials, MCP artifacts, and connect config through a restrictive same-directory temporary file followed by atomic replacement. Propagate directory creation, rendering, permission, and replacement failures instead of reporting S6 success.
- Do not silently reuse stale `DIREXTALK_AGENT_NODE_ID` across domains. Node ids must be scoped to the current deployment unless the operator explicitly forces an override.

## Documentation Rules

- Keep `README.md`, `README_zh.md`, `SKILL.md`, `AGENTS.md`, `agents/README.md`, `agents/openai.yaml`, and `references/*` synchronized when changing deployment contracts, local bridge behavior, install commands, or platform support.
- Keep user-facing docs focused on operating the deployer. Put implementation details and edge cases in `references/`.
- Document Windows and POSIX examples separately when commands differ.
- Avoid saying "run bash" as the universal answer. Say which host runtime is intended and why.

## Validation

Run focused checks after every change:

```bash
bash tests/skill_structure_test.sh
bash tests/s6_wire_local_test.sh
bash tests/local_paths_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
npm test
```

On Windows-specific changes, also run or inspect:

```powershell
.\scripts\orchestrate.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrate.ps1 status
```

If a validation cannot be run on the current host, record the reason and run the closest targeted static check.

## Change Discipline

- Prefer portable helpers over one-off fixes.
- When fixing a platform bug, search for the same assumption elsewhere before stopping.
- Keep unrelated deployment behavior untouched unless the same abstraction owns it.
- Self-review diffs before committing.
- Commit finished work on the active branch with a focused message. Do not stage generated credentials, local state, binaries, logs, `.codegraph/`, or machine-specific test artifacts.
