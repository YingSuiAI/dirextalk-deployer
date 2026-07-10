# Remote MCP Connect Contract Implementation Plan

> Execute with focused TDD, repository-scoped commits, and a final cross-project review.

**Goal:** Make remote HTTP MCP reliable and honestly supported across connect
agents and Windows/macOS/Linux deployment hosts while retiring active
`dirextalk-mcp` paths.

**Global constraints:** Preserve Matrix room/sync behavior. Do not introduce a
local MCP daemon/proxy. Deployer owns deployment and service wiring; connect
owns agent schema conversion. Unknown or unsafe capability fails closed.
Tests never write real user configuration. Preserve legacy state scrubbers for
one migration cycle. Do not modify unrelated `dirextalk-plugins/.idea/`.

---

## Task 1: Fix connect MCP correctness and test isolation

**Repository:** `dirextalk-connect`

1. Add failing tests proving home resolution is isolated on Windows and that
   config writers cannot escape a supplied temporary root.
2. Replace ad hoc test `HOME` setup with a shared cross-platform test helper;
   make POSIX permission assertions platform-aware.
3. Add failing Codex tests for the official `http_headers` inline table, then
   replace the ignored `headers` arguments without exposing tokens in logs.
4. Add explicit partial-config validation and actionable errors.
5. Run focused core/Codex/config-writer tests before broader agent tests.

## Task 2: Make connect capability-driven

**Repository:** `dirextalk-connect`

1. Add a single capability registry covering every registered backend.
2. Add strict ACP tests for HTTP capability true/false and remove the
   non-standard duplicate `mcp_servers` request field.
3. Replace avoidable global writes with official session/process-scoped
   mechanisms where supported.
4. Remove Antigravity's undocumented duplicate global path.
5. For Pi, tmux, and remote Reasonix, add failing tests and actionable
   conditional/unsupported behavior rather than silent no-op configuration.
6. Add concurrency/preservation tests for any unavoidable shared writer.
7. Add a Windows/Linux/macOS MCP contract CI job and keep agent/platform build
   selection neutral.

## Task 3: Correct deployer state, failure, and platform behavior

**Repository:** `dirextalk-deployer`

1. Add failing tests showing delivery must re-run live runtime verification
   even when stored state says passed.
2. Add full `run_phase` tests proving invalid runtime/agent/options/policy/mode
   and MCP enrollment failures mark S6 failed and return non-zero.
3. Stop default OpenClaw host-global mutation. Model it as `host-managed`; add
   a separate explicit opt-in if safe auto enrollment is retained, and never
   pass bearer tokens in argv.
4. Replace generic runtime fallback with a declarative capability/artifact
   map aligned with connect.
5. Render Windows recommendations as PowerShell and POSIX recommendations as
   Bash; keep stored/display paths in the consumer's native style.
6. Stop generating legacy env/profile fields with no active consumer while
   retaining legacy state scrubbers.
7. Add Windows, Ubuntu, and macOS CI coverage plus a native PowerShell test
   step.

## Task 4: Remove active old MCP deployment paths

**Repositories:** `dirextalk-web-deployer`, `dirextalk-mcp`, parent workspace

1. Sync web-deployer's vendored JSON-RPC/S7 acceptance logic with the current
   remote `POST /mcp` implementation; remove operation-report defaults that
   advertise `dirextalk-mcp@latest`.
2. Add regression tests scanning all relevant vendored scripts, not only the
   orchestrator entrypoint.
3. [x] The user manually deleted the local clone on 2026-07-10. Because the
   clone was absent, the repository-local tombstone and cleanup-guidance task
   was skipped. No npm publish/deprecation or GitHub archival was performed.
4. Remove the old project from active parent project/command/status/skill
   routing and mark historical design documents superseded.

## Task 5: Add the shared development skill

**Location:** parent `.codex/skills/dirextalk-connect-deployer-development`

1. Run baseline pressure scenarios without the new skill and record failures.
2. Scaffold the skill with `skill-creator` tooling.
3. Keep `SKILL.md` concise; put the agent capability table and OS verification
   matrix in focused references.
4. Encode official-schema verification, ownership boundaries, test-home
   isolation, TDD, CodeGraph-first discovery, release synchronization, and
   deprecated-path checks.
5. Validate the skill structure and re-run pressure scenarios with a fresh
   reviewer.

## Task 6: Cross-project review and verification

1. Review every repository diff for contract drift and unrelated changes.
2. Run focused tests, full feasible suites, Bash syntax checks, PowerShell
   tests, Go builds/cross-builds, `npm pack`, and `git diff --check`.
3. Run independent specification and code-quality reviews; fix all critical or
   important findings and re-review.
4. Commit each repository separately. Record parent-workspace files separately
   because the parent is not a Git repository.
5. Report remaining real-agent smoke gaps and request separate approval before
   npm deprecation, releases, GitHub archival, or old Agent plugin removal.
