# Task 3 Report: Deployer Remote MCP Contract

## Status

Implemented the Task 3 deployer contract on `codex/remote-mcp-contract-20260710`
against baseline `5dfea6995ccb78b04ecc4d7debc85728adfd7ef8`.

## Delivered behavior

- Final delivery always reruns live `verify runtime`; cached passed state is not
  accepted as current evidence, and either a non-zero verifier result or a
  non-passed runtime component blocks delivery.
- S6 now propagates invalid runtime, agent, agent options, install policy,
  install mode, artifact generation, config generation, daemon install, and MCP
  enrollment failures. A failed S6 cannot subsequently be marked done.
- The MCP registry is declarative and aligned with `dirextalk-connect`:
  `session`, `project`, `host-managed`, `conditional`, and `unsupported` are
  explicit; unknown runtimes fail closed and no generic JSON artifact is made.
- OpenClaw is host-managed. S6 writes reviewable guidance only, does not mutate
  user-global OpenClaw configuration, and does not put bearer credentials in
  command arguments.
- Generated `dirextalk-connect` configuration includes canonical remote MCP
  endpoint/token/node fields plus `mcp_capability`, including host-managed
  OpenClaw configuration for fail-closed consumption by connect.
- Windows recommendations are executable native PowerShell with native
  consumer paths. POSIX recommendations remain Bash. Stored/displayed local
  consumer paths are normalized for the consumer platform.
- The legacy service-level `env` artifact and `agent_env_file` state are retired;
  S6 removes an existing service `env` during migration and retains `mcp/env`.
  `credentials.json` now uses canonical `agent_token`, `agent_node_id`, and
  `mcp_url` profile fields.
- Operation reports expose MCP capability and selected artifact metadata.
- CI now covers Windows, Ubuntu, and macOS, runs a native Windows PowerShell
  test, enforces tracked-text LF, runs Bash syntax checks, and checks package
  contents.
- Public deployer docs and agent metadata describe the same capability map,
  artifact behavior, credential shape, and platform-specific commands.

## TDD evidence

Observed failing tests before each corresponding implementation change,
including:

- cached passed runtime state incorrectly allowed final delivery;
- invalid S6 runtime returned success;
- the retired service `env` survived a migration rerun;
- the old credential profile and generic/OpenClaw artifact expectations;
- Windows recommendations contained Bash/WSL syntax;
- a CRLF tracked text fixture was not covered by a NUL-safe gate.

The focused tests then passed after the smallest contract-specific changes.
The LF gate uses `git ls-files --eol -z`, parses records NUL-safely, skips files
actually classified as `i/-text`, and self-tests both a binary containing
`0x0D` and a CRLF text file.

## Verification

- `npm test` — passed, including LF, distribution/structure, live delivery,
  full S6 failure propagation, capability/artifact, operation report, and
  existing focused regression tests.
- `pwsh -NoProfile -File tests/windows_path_wrappers_test.ps1` — passed.
- `pwsh -NoProfile -File tests/windows_recommendation_test.ps1` — passed; the
  generated command executed against temporary fake npm/connect commands and
  left the sentinel user configuration unchanged.
- All `scripts/**/*.sh` and `tests/**/*.sh` via `bash -n` — passed.
- `npm pack --dry-run` — passed; package contained the expected deployer files.
- `git diff --check` and `tests/tracked_text_lf_test.sh` — passed.
- Parent workspace `scripts/dtx.ps1 -Task skills` and `-Task lf-check` — passed.
- Extended shell suite: 40 of 41 tests passed. The sole failure,
  `tests/orchestrate_status_recovery_test.sh`, is a pre-existing baseline
  mismatch: the test expects “EC2/public IPv4/EBS” while baseline implementation
  `5dfea699...` already emits “cloud instance/public IPv4/storage”. It is outside
  Task 3 and was not modified.

One pre-existing tracked CRLF Markdown file was normalized mechanically during
the LF audit. Its content hash was unchanged after newline normalization and it
has no semantic diff or staged change.

## Remaining limits

- No cloud deployment, real user-home mutation, or real OpenClaw/agent
  enrollment was performed. Verification used repository tests and isolated
  temporary homes/fakes as required.
- Hosted Windows/Ubuntu/macOS CI has not run in this local task; the workflow was
  validated statically, with native Windows PowerShell and local Bash execution.
- End-to-end capability injection depends on the matching `dirextalk-connect`
  registry/consumer change landing with this deployer commit.
