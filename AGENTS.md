# Dirextalk Deployer Development

This repository is a cross-platform orchestration product and the distributable `dirextalk-deployer` operations skill. Development rules live here; real deploy/resume/status/verify/update/reset/destroy tasks use `SKILL.md`.

## Ownership

- Deployer owns idempotent orchestration, cloud state, immutable updater installation, service wiring, redacted reports, and local bridge setup.
- `dirextalk-updater` independently owns the root host Unix API, upgrade/rollback job state, desired state, and watchdog.
- `dirextalk-connect` owns Matrix Agent-room bridging and agent-runtime adaptation.
- MCP is bearer-authenticated remote HTTP at `https://<domain>/mcp`. Do not introduce a local Dirextalk MCP CLI, daemon, proxy, stdio bridge, env artifact, or listening port.

## Platform And State

- Classify paths by consumer: remote server paths are Linux; Bash execution paths are POSIX; Windows-local bridge/agent paths are native Windows; documentation paths are portable placeholders.
- Windows users enter through PowerShell wrappers; POSIX users enter through Bash scripts. WSL is a separate POSIX runtime, not evidence for Windows-native behavior.
- Keep phases idempotent and resumable. Use existing state, JSON, path, and phase helpers instead of ad hoc file mutation or OS-specific rewrites in phase bodies.
- Supported cloud hosts are Ubuntu 22.04/24.04 x86_64; new hosts default to 24.04. Install only the deployer-pinned updater Release/commit/SHA and the server Release resolved to an immutable digest.
- Format generated paths for the process that reads them. Do not create config/state fields without a current consumer and test.

## Connect And MCP

- Local wiring requires the real `agent_room_id`, an `@agent:<server>` Matrix session created with `agent_token`, and room-restricted sync/replies.
- Runtime/MCP capability is explicit and fail-closed. A host-owned MCP registry cannot be bypassed by selecting a child backend; unknown/unsupported integrations do not receive a generic fallback.
- Preserve selected backend options and use tested capability/config fixtures as the source of truth rather than copying provider tables into instructions.
- Generated credentials/config use restrictive same-directory temporary files plus atomic replacement. Tests that touch agent config must redirect every home/config root to a verified temporary tree and use fake CLIs; never exercise real user homes, daemons, cloud accounts, or published packages unintentionally.

## Development And Release

- Keep POSIX and PowerShell entrypoints behaviorally aligned for deploy/resume/status/destroy and local wiring.
- Platform bugs need focused tests for the consuming OS/path layer. Cross-platform claims require corresponding CI or real-host evidence, not only cross-compilation.
- Update the user-facing skill/reference that owns a changed operational contract, but avoid copying implementation details into every README, AGENTS, and skill file.
- A package release must align npm version, source commit/tag, GitHub Release/assets, package contents, and a real temporary install. External publication or host-global config mutation requires explicit authorization.

Use focused tests for the changed phase first, then `npm test` and `git diff --check`. For Windows-specific changes, run the relevant PowerShell wrapper/status path. Review and commit only current-task changes and keep credentials, state, logs, binaries, `.codegraph/`, and machine artifacts untracked.
