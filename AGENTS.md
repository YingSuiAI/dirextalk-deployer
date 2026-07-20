# AGENTS.md

`dirextalk-deployer` is a cross-platform deployment product and agent skill, not a Linux-only script collection. Maintain it as a portable orchestration layer driven by Git Bash on native Windows and Bash on Linux/macOS/WSL while deploying a Linux-based Dirextalk server.

## Product Scope

- Deploy, resume, verify, destroy, and locally wire a production Dirextalk message server.
- Install the independently released `YingSuiAI/dirextalk-updater` host binary from the deployer-owned immutable version/commit/SHA pin. The deployer does not embed or build updater Go source.
- Direct-version upgrades are client initiated; do not reintroduce the retired daily updater GitHub discovery timer or service.
- Treat `SKILL.md` as the compact agent-facing entrypoint. Detailed runbooks belong in `references/`; `scripts/` are the stable implementation entrypoints.
- `SKILL.md` is a user-facing runbook that must remain usable by less capable models. Its Freshness Gate, step-by-step onboarding, semantic confirmation policy, AWS promotional/billing reminders, and repeated safety guidance are intentional product behavior; preserve them unless the product owner explicitly changes that onboarding contract.
- The supported local conversation bridge is `dirextalk-connect`, installed from `dirextalk-connect@latest` by default or built from `YingSuiAI/dirextalk-connect`.
- MCP support is capability-driven and is separate from bridge-agent support. Declared MCP consumers connect directly to the deployed message server's HTTP endpoint; unknown runtimes never receive a generic fallback.
- Supported local agent targets are the dirextalk-connect agent providers, treated as peers: `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.
- Do not reintroduce legacy local gateway installation flows or third-party chat platform wiring.
- Do not hard-code one developer's home directory, shell, agent executable path, AWS region, domain, node id, token, or password.

## Platform Law

Every deployer change must classify paths and commands by the platform that will consume them:

- **Remote server paths** are Linux paths inside EC2/cloud-init/Docker, such as `/var/dirextalk-message-server`, `/var/dirextalk-message-server/p2p/bootstrap.json`, and `/etc/dirextalk-message-server`.
- **Deployer execution paths** are used by the orchestration engine. On Git Bash, normalize paths before passing them to Windows-native Node.js, AWS CLI, curl, or agent executables. Do not rely on implicit MSYS argv conversion: parent runtimes may set `MSYS_NO_PATHCONV=1`, and `/tmp` redirections otherwise diverge from native-tool file arguments.
- **Local bridge paths** are consumed by `dirextalk-connect` and the local agent process. On Windows they must be Windows-compatible paths, not `/mnt/c/...` or Git Bash-only `/c/...` paths.
- **Documentation paths** must be portable examples using `$HOME`, `%USERPROFILE%`, `$env:USERPROFILE`, `<service_id>`, or `<domain>`, not machine-specific absolute paths.

If a change writes a path into `state.json`, `credentials.json`, `dirextalk-connect/config.toml`, docs, or printed commands, verify which process will read that path and format it for that process. Do not generate an artifact without a current consumer.
Use `scripts/lib/git-bash.sh`, `scripts/lib/local-paths.sh`, and `scripts/lib/paths.sh` for the Git Bash platform check and path conversion. These helpers must lexically recognize `C:\Users\alice`, `C:/Users/alice`, `/mnt/c/Users/alice`, `/cygdrive/c/Users/alice`, and `/c/Users/alice` before calling shell-specific conversion tools.

## Entrypoints

- All supported hosts run `bash scripts/orchestrate.sh`, `bash scripts/destroy.sh`, `bash scripts/update.sh`, and `bash scripts/reset-app-data.sh`.
- Native Windows users must install Git for Windows and run those commands from Git Bash. On native Windows, the skill CLI and lifecycle scripts require a `MINGW*` shell, `cygpath`, a `.windows.` Git version, and a matching Git for Windows installation root; otherwise they must tell the user to install Git for Windows and stop. Native WSL sessions are Linux hosts and run Bash directly.
- Do not tell native Windows users to run PowerShell wrappers or launch WSL as a command runner. Keep one service directory owned by one environment, and keep lifecycle commands, recovery output, documentation, and generated recommendations in Bash syntax.

## Script Architecture

- Keep the state-machine phases idempotent and resumable. A phase should be safe to rerun after token refresh, DNS wait, or partial local wiring.
- Shell phase files should expose `run_phase` and use `state_get`, `state_set`, and `phase_set` instead of ad hoc state edits.
- Prefer small helpers for platform conversion, command discovery, and output formatting. Do not scatter OS-specific path rewrites across phase bodies.
- Use `scripts/json.mjs` through `scripts/lib/json.sh` for JSON reads/writes. Do not reintroduce legacy external JSON CLI dependencies.
- Remote server commands may assume Linux because the EC2 host is Linux. Local commands must not assume Linux.
- Version 1 cloud hosts may run Ubuntu 22.04 or 24.04 on x86_64. New cloud hosts still default to Ubuntu 24.04; bootstrap must verify the supported host set before downloading the pinned updater or starting Compose.
- Pre-updater d1 adoption is never inferred by normal resume. Use only `scripts/adopt-legacy-node.sh` after its fixed v0.15.2/digest/Compose/systemd-Caddy dry run and an explicit semantic user confirmation; the agent supplies the script's machine confirmation token and it must not pull or recreate the running image.
- Use `dirextalk_native_tool_path` at every shell-to-native file-path boundary and `dirextalk_normalize_local_path` for persisted consumer paths. This includes Node scripts and input files, AWS `file://` arguments, curl output/header files, `dirextalk-connect.exe`, local agent executables, Windows user profile paths, and npm global binaries.
- When adding a new local runtime or agent executable, support explicit override env vars before detection. For connect this includes `DIREXTALK_CONNECT_AGENT`, `DIREXTALK_CONNECT_AGENT_CMD`, and runtime-specific aliases such as `DIREXTALK_CODEX_COMMAND`, `DIREXTALK_GEMINI_COMMAND`, or `DIREXTALK_CLAUDE_CODE_COMMAND`. Host-owned OpenClaw/Hermes bridges reject generic child command/args overrides.
- Do not make Codex, Claude, Gemini, Cursor, or any other provider the semantic default for an unknown runtime. Unknown or ambiguous detection should require an explicit `DIREXTALK_CONNECT_AGENT`.

## Dirextalk Connect Wiring

- S5/S6 must fail closed when `agent_room_id` is missing or uses a legacy pseudo id such as `!agent:<domain>`.
- S6 must create a Matrix session through `agent.matrix_session.create` using `agent_token`, not owner `access_token`, and require `@agent:<server>` for the bridge. Returning `@owner:<server>` is a server-side compatibility failure.
- The generated dirextalk-connect config must contain one Matrix platform and must restrict sync/replies to the real `agent_room_id`.
- The generated agent config must preserve the selected connect agent type and optional agent-specific TOML. Some providers require more than `cmd`; for example `reasonix` needs `serve_url`, `tmux` needs `session`, and generic `acp` may need command/args.
- `DIREXTALK_AGENT_INSTALL=auto` is the default and installs `dirextalk-connect@latest` into the current service directory, not into the npm global prefix, unless an explicit binary/command override is set. It installs the service-scoped `dirextalk-connect` daemon. The canonical MCP description points to the deployed message server HTTP MCP endpoint; do not install or launch a local MCP CLI, daemon, proxy, or listening port.
- Keep the declarative MCP registry aligned with dirextalk-connect. Resolve capability from the effective connect agent except that detected OpenClaw and Hermes hosts own authoritative native MCP registries and are always `host-managed`. They require the ACP bridge; reject non-ACP `DIREXTALK_CONNECT_AGENT` overrides. Antigravity, Cursor, and iFlow are also `host-managed`; Pi, tmux, Devin, and Reasonix are `unsupported`. Unsupported and unknown runtimes fail closed. Do not generate a generic JSON artifact.
- Host-runtime artifact selection is separate from effective connect-agent capability. Preserve reviewable host guidance, but omit canonical MCP fields from host-managed connect options. With `auto`, S6 registers OpenClaw through `config patch --stdin`, then requires its native tool probe. For Hermes, it clones the active configured profile into a marked service profile, stores the service token through the native API, and requires a native tool probe before bridge startup. Neither path passes secrets in argv; destroy removes the OpenClaw entry/token or the owned Hermes profile. Other host-managed backends remain explicitly operator-confirmed with `DIREXTALK_MCP_HOST_READY=1` when no safe native adapter exists.
- `recommend` must only write files and print commands; `skip` writes credentials, connect config, and canonical MCP artifacts only. S6 must not recreate the retired service-level `env` file.
- Do not pin old package versions in runtime defaults. Keep `@latest` defaults and preserve env overrides only for explicit debugging or rollback.

## Secrets And State

- Never print, commit, or paste AWS secrets, Matrix access tokens, `agent_token`, private keys, or full credential files. After a completed deployment, the final user handoff must include the App domain and the eight-digit app initialization code.
- When verifying credentials, print booleans or identities only, such as `has_access_token=true`, `user_id`, `device_id`, and `homeserver`.
- `credentials.json`, Matrix session files, SSH keys, and generated env files must stay outside the repository and should be written with restrictive permissions when the platform supports it.
- Write generated credentials, MCP artifacts, and connect config through a restrictive same-directory temporary file followed by atomic replacement. Propagate directory creation, rendering, permission, and replacement failures instead of reporting S6 success.
- Do not silently reuse stale `DIREXTALK_AGENT_NODE_ID` across domains. Node ids must be scoped to the current deployment unless the operator explicitly forces an override.

## Documentation Rules

- Keep `README.md`, `SKILL.md`, `AGENTS.md`, `agents/README.md`, `agents/openai.yaml`, and `references/*` synchronized when changing deployment contracts, local bridge behavior, install commands, or platform support.
- Keep user-facing docs focused on operating the deployer. Put implementation details and edge cases in `references/`.
- Use the same Bash command examples on Windows, Linux, macOS, and WSL; explain that native Windows runs them from Git Bash while WSL runs them directly.

## Validation

During one coherent delivery stage, use only the smallest immediate check that
answers a real safety question. The test runner selects tests from uncommitted
files plus commits ahead of `origin/main`. At the stage boundary, run:

```bash
git diff --check
npm test
```

`npm test` runs only directly affected tests and their declared neighboring
contracts. `npm run test:release` uses the same affected plan plus package,
skill-structure, and LF checks; it is the normal pre-publish gate. Use
`DIREXTALK_TEST_BASE=<ref>` or newline/comma-separated
`DIREXTALK_TEST_CHANGED_FILES=<paths>` only when automatic Git discovery needs
an explicit boundary.

`npm run test:quick` runs the portable baseline, and `npm run test:stage` runs
the default Lightsail workflow lane. Run them only when that whole boundary is
actually affected. `npm run test:full` retains EC2, legacy adoption, updater,
DNS, S6, and runtime compatibility matrices for explicit manual validation or
a genuinely broad cross-cutting change; it is not a routine development or
publishing requirement. For changed shell files, run focused `bash -n` checks;
CI retains one repository-wide syntax check because it is inexpensive.

CI runs `npm run test:quick` on all three supported platforms and the stage lane
once on Ubuntu. The exhaustive full lane runs only through explicit
`workflow_dispatch`.

On Windows, the npm test runner starts one Git for Windows Bash controller and
runs test files sequentially. Its isolated test root starts one authenticated,
loopback-only Node JSON worker and reuses each shell connection instead of
launching native `node.exe` for every JSON key. Production JSON calls retain
the direct CLI fallback. Do not add `wsl.exe`, WSL distributions, or parallel
shell fan-out to the test entrypoint; WSL-backed IDE and Docker processes are
outside this repository's test lifecycle.

On Windows-specific changes, run the Git Bash contract test and a direct status command from Git Bash.

If a validation cannot be run on the current host, record the reason and run the closest targeted static check.

## Change Discipline

- Prefer portable helpers over one-off fixes.
- Do not repeat design/spec reviews for pure internal helpers or test fixtures;
  one stage-end diff review is sufficient unless a public contract changes.
- When fixing a platform bug, search for the same assumption elsewhere before stopping.
- Keep unrelated deployment behavior untouched unless the same abstraction owns it.
- Self-review diffs before committing.
- Commit finished work on the active branch with a focused message. Do not stage generated credentials, local state, binaries, logs, `.codegraph/`, or machine-specific test artifacts.
