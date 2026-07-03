# Npm Skill Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add npm-based versioned distribution and updating for the Dirextalk deployer skill.

**Architecture:** A small Node CLI ships inside the npm package and copies the packaged skill bundle into runtime-specific target directories. Existing shell deployment scripts remain untouched; docs and `SKILL.md` switch skill installation guidance from GitHub-first to npm-first while preserving Git clone as a developer fallback.

**Tech Stack:** Node.js ESM CLI, npm package metadata, Bash tests, existing Markdown docs.

---

## File Structure

- Create `package.json`: npm metadata, binary mapping, publish file allowlist, script aliases for tests.
- Create `bin/dirextalk-deployer.mjs`: CLI command parsing, target resolution, managed-copy installer, freshness check.
- Create `tests/npm_skill_distribution_test.sh`: black-box CLI tests using temporary project/global directories.
- Modify `SKILL.md`: npm-first freshness gate and skill install/update instructions.
- Modify `README.md`: English user-facing npm install/update workflow.
- Modify `README_zh.md`: Chinese user-facing npm install/update workflow.
- Modify `references/agent-targets.md`: source-of-truth npm CLI examples and managed install policy.
- Modify `tests/skill_structure_test.sh`: required files and doc guardrails for npm distribution.

### Task 1: Failing Package Metadata Test

**Files:**
- Create: `tests/npm_skill_distribution_test.sh`
- Modify: `tests/skill_structure_test.sh`

- [ ] **Step 1: Add a black-box test for package metadata and install target behavior**

Create `tests/npm_skill_distribution_test.sh` with assertions that run `node bin/dirextalk-deployer.mjs skill install --agent codex --scope project --project "$tmp/project"` and check for copied `SKILL.md`, `references/agent-targets.md`, and `.dirextalk-skill-install.json`.

- [ ] **Step 2: Run test and verify it fails**

Run: `bash tests/npm_skill_distribution_test.sh`
Expected: FAIL because `bin/dirextalk-deployer.mjs` and `package.json` do not exist yet.

### Task 2: Minimal CLI And Package

**Files:**
- Create: `package.json`
- Create: `bin/dirextalk-deployer.mjs`
- Test: `tests/npm_skill_distribution_test.sh`

- [ ] **Step 1: Implement the npm package metadata**

Add `package.json` with package name `dirextalk-deployer`, binary `dirextalk-deployer`, package files allowlist, and test scripts that call the existing shell tests.

- [ ] **Step 2: Implement the CLI installer**

Implement `skill install`, `skill update`, and `skill refresh` commands. The CLI resolves runtime targets, copies the skill bundle recursively, writes `.dirextalk-skill-install.json`, protects unmanaged targets unless `--force` is present, and supports `--dry-run`.

- [ ] **Step 3: Run the focused test**

Run: `bash tests/npm_skill_distribution_test.sh`
Expected: PASS.

### Task 3: Documentation And Skill Freshness

**Files:**
- Modify: `SKILL.md`
- Modify: `README.md`
- Modify: `README_zh.md`
- Modify: `references/agent-targets.md`
- Modify: `tests/skill_structure_test.sh`

- [ ] **Step 1: Update skill instructions**

Replace GitHub-first install/update instructions with npm-first commands and add the automatic freshness check using `dirextalk-deployer skill refresh`.

- [ ] **Step 2: Update user docs**

Add English and Chinese README sections for install, update, project-local scope, global scope, and version pinning.

- [ ] **Step 3: Update source-of-truth target docs**

Document the npm CLI as the supported installer while keeping target paths visible for audit and advanced users.

- [ ] **Step 4: Update structure tests**

Add checks that `package.json`, `bin/dirextalk-deployer.mjs`, and npm install guidance are present.

### Task 4: Verification And Commit

**Files:**
- All changed files

- [ ] **Step 1: Run focused verification**

Run:

```bash
bash tests/npm_skill_distribution_test.sh
bash tests/skill_structure_test.sh
```

Expected: PASS.

- [ ] **Step 2: Run required deployer checks**

Run:

```bash
bash tests/s6_wire_local_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```

Expected: PASS.

- [ ] **Step 3: Run Windows status checks**

Run:

```powershell
.\scripts\orchestrate.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrate.ps1 status
```

Expected: status output or a documented state-not-found result without script syntax failure.

- [ ] **Step 4: Commit**

Run:

```bash
git add package.json bin/dirextalk-deployer.mjs tests/npm_skill_distribution_test.sh tests/skill_structure_test.sh SKILL.md README.md README_zh.md references/agent-targets.md docs/superpowers/specs/2026-06-30-npm-skill-distribution-design.md docs/superpowers/plans/2026-06-30-npm-skill-distribution.md
git commit -m "Add npm skill distribution"
```
