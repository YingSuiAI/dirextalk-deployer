# Cursor Windows Runtime Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows Cursor deployments fail or recover at the right point by wiring Cursor Agent CLI correctly and verifying that the local agent backend can actually answer.

**Architecture:** Keep S6 as the owner of generated `dirextalk-connect/config.toml` and local install decisions, but keep agent-specific command/options logic in `scripts/lib/connect-agent-adapters.sh`. Keep `scripts/orchestrate.sh verify runtime` as the owner of post-deploy runtime truth, with daemon log classification shared through `scripts/lib/connect-daemon-logs.sh`. Documentation describes when a human login is unavoidable and what the deployer does automatically afterward.

**Tech Stack:** Bash state-machine scripts, PowerShell Windows entrypoints, Node-backed JSON helpers, shell integration tests.

---

### Task 1: Replace Windows Cursor Desktop Wiring With Cursor Agent CLI Wiring

**Files:**
- Modify: `scripts/phases/s6_wire_local.sh`
- Add/modify: `scripts/lib/connect-agent-adapters.sh`
- Test: `tests/s6_wire_local_test.sh`

- [ ] **Step 1: Write the failing test**

Add a fake `%LOCALAPPDATA%/cursor-agent/agent.cmd` and assert `_connect_agent_command cursor` returns that path in Windows path style:

```bash
fake_cursor_agent="$tmp/localapp/cursor-agent"
mkdir -p "$fake_cursor_agent"
: > "$fake_cursor_agent/agent.cmd"
(
  export LOCALAPPDATA="$tmp/localapp"
  export DIREXTALK_LOCAL_PATH_STYLE=windows
  cursor_cmd=$(_connect_agent_command cursor)
  case "$cursor_cmd" in
    */cursor-agent/agent.cmd|*:*/cursor-agent/agent.cmd) ;;
    *) echo "expected Cursor Agent CLI path, got: $cursor_cmd" >&2; exit 1 ;;
  esac
)
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash tests/s6_wire_local_test.sh
```

Expected before implementation: failure because current code resolves Cursor Desktop `Cursor.exe`.

- [ ] **Step 3: Implement the minimal wiring**

Move agent command defaults into `scripts/lib/connect-agent-adapters.sh` and replace Cursor desktop helper functions with Cursor Agent CLI helpers:

```bash
_cursor_agent_windows_command() {
  local candidate
  for candidate in \
    "${DIREXTALK_CURSOR_AGENT_COMMAND:-}" \
    "${DIREXTALK_CURSOR_COMMAND:-}" \
    "${LOCALAPPDATA:-}/cursor-agent/agent.cmd" \
    "${LOCALAPPDATA:-}/Programs/cursor-agent/agent.cmd"
  do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    _local_connect_path "$candidate"
    return 0
  done
  command -v agent.cmd 2>/dev/null || command -v agent 2>/dev/null || true
}
```

Change `_connect_agent_command` to call `_cursor_agent_windows_command` for `agent=cursor` on Windows.

- [ ] **Step 4: Verify test passes**

Run:

```bash
bash tests/s6_wire_local_test.sh
```

Expected: `s6 wire local ok`.

### Task 2: Generate Cursor Agent Safe Defaults

**Files:**
- Modify: `scripts/phases/s6_wire_local.sh`
- Modify: `scripts/lib/connect-agent-adapters.sh`
- Test: `tests/s6_wire_local_test.sh`

- [ ] **Step 1: Write the failing test**

Assert Cursor config options contain `mode = "yolo"` and no obsolete `cli.js` args:

```bash
cursor_options=$(
  DIREXTALK_LOCAL_PATH_STYLE=windows \
  _connect_agent_options_toml cursor cursor
)
[[ "$cursor_options" == *'mode = "yolo"'* ]]
[[ "$cursor_options" != *'cli.js'* ]]
```

- [ ] **Step 2: Implement options**

Make the Cursor default TOML:

```toml
mode = "yolo"
```

Let `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` keep full override priority.

- [ ] **Step 3: Verify test passes**

Run:

```bash
bash tests/s6_wire_local_test.sh
```

Expected: `s6 wire local ok`.

### Task 3: Classify Cursor Backend Failures From Daemon Logs

**Files:**
- Modify: `scripts/phases/s6_wire_local.sh`
- Modify: `scripts/orchestrate.sh`
- Add/modify: `scripts/lib/connect-daemon-logs.sh`
- Test: `tests/connect_daemon_runtime_check_test.sh`

- [ ] **Step 1: Write failing runtime checks**

Add log samples for:

```text
cursor: "C:/Users/.../agent.cmd" CLI not found in PATH
Authentication required. Please run 'agent login' first
Workspace Trust Required
```

Each sample must make `verify connect_daemon` return non-zero and store `runtime_checks.connect_daemon.status === 'failed'`.

- [ ] **Step 2: Implement a shared log pattern**

Match:

```bash
ACP_SESSION_INIT_FAILED|ACP metadata is missing|Recreate this ACP session|failed to create agent|CLI not found in PATH|Authentication required|agent login|Workspace Trust Required
```

Use this both in S6 auto install and in `verify connect_daemon`.

- [ ] **Step 3: Verify runtime tests**

Run:

```bash
bash tests/connect_daemon_runtime_check_test.sh
bash tests/runtime_summary_check_test.sh
```

Expected: both tests pass.

### Task 4: Update Docs For The Correct Cursor Contract

**Files:**
- Modify: `README.md`
- Modify: `README_zh.md`
- Modify: `SKILL.md`
- Modify: `references/runtime-wiring.md`
- Modify: `references/windows-deployment-notes.md`

- [ ] **Step 1: Replace Cursor Desktop wording**

Document Cursor Agent CLI path:

```text
%LOCALAPPDATA%\cursor-agent\agent.cmd
```

State that login may require one interactive `agent.cmd login`, but rerunning S6 after login refreshes config and restarts the daemon automatically.

- [ ] **Step 2: Verify docs references**

Run:

```bash
bash tests/skill_structure_test.sh
git diff --check
```

Expected: both pass.

### Task 5: Full Verification And Commit

**Files:**
- Verify all modified files

- [ ] **Step 1: Run focused tests**

Run:

```bash
bash tests/s6_wire_local_test.sh
bash tests/connect_daemon_runtime_check_test.sh
bash tests/runtime_summary_check_test.sh
bash tests/skill_structure_test.sh
bash tests/local_paths_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```

Expected: all commands pass.

- [ ] **Step 2: Run Windows status wrappers**

Run:

```powershell
.\scripts\orchestrate.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrate.ps1 status
```

Expected: both commands list local services.

- [ ] **Step 3: Commit**

Run:

```bash
git add README.md README_zh.md SKILL.md references/runtime-wiring.md references/windows-deployment-notes.md scripts/phases/s6_wire_local.sh scripts/orchestrate.sh scripts/lib/connect-agent-adapters.sh scripts/lib/connect-daemon-logs.sh tests/s6_wire_local_test.sh tests/connect_daemon_runtime_check_test.sh docs/superpowers/plans/2026-07-01-cursor-windows-runtime-hardening.md
git commit -m "Harden Windows Cursor runtime wiring"
```
