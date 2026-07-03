# Npm Skill Distribution Design

## Goal

Distribute `dirextalk-deployer` as a versioned npm package so users can install and update the skill without cloning from GitHub. The package should install the current skill bundle into the correct project-local or global location for the selected agent runtime.

## Scope

This change covers the deployer skill distribution path only. It does not change Dirextalk server deployment, `dirextalk-connect` daemon wiring, Matrix credentials, or MCP runtime checks.

## Package Contract

The npm package name is `dirextalk-deployer`. The package contains the agent-facing skill bundle:

- `SKILL.md`
- `README.md`
- `README_zh.md`
- `AGENTS.md`
- `LICENSE`
- `agents/`
- `references/`
- `scripts/`
- `tests/`

The package exposes a Node CLI named `dirextalk-deployer`.

## CLI Contract

The primary user commands are:

```bash
npm install -g dirextalk-deployer
dirextalk-deployer skill install --agent codex --scope project --project .
dirextalk-deployer skill update --agent codex --scope project --project .
```

`skill install` and `skill update` both copy the package skill bundle into the target runtime directory. `update` is intentionally the same install operation over an existing directory because npm package versions already represent release history.

Supported options:

- `--agent <runtime>`: one of the existing runtime names from `references/agent-targets.md`, with the same aliases used by the deployer where practical.
- `--scope project|global`: project-local by default.
- `--project <path>`: project root for project-local installs; defaults to the current working directory.
- `--target <path>`: explicit target override for advanced users.
- `--dry-run`: print the resolved target and files without copying.

The installer must not copy generated credentials, local state, `.git`, `.codegraph`, IDE folders, logs, or machine-specific artifacts.

## Target Resolution

The CLI owns a small runtime target table aligned with `references/agent-targets.md`. Project-local installs remain the default when a project root is available. Global installs are explicit because they write into host-level agent configuration directories.

On Windows, target paths are native Windows paths. POSIX shells use POSIX paths. Documentation examples must show Windows PowerShell and POSIX commands separately when command syntax differs.

## Freshness And Auto Update

`SKILL.md` should replace the old GitHub-first freshness gate with an npm-first gate:

1. If the skill is running from an npm-installed package or copied npm bundle, run `dirextalk-deployer skill refresh --agent <runtime> --scope <scope> --project <path>` when the CLI is available.
2. `skill refresh` checks `npm view dirextalk-deployer version`, compares it with the local package version, runs `npm install -g dirextalk-deployer@latest` when a newer version exists, and then refreshes the target skill directory.
3. If npm is unavailable or offline, the agent reports that freshness could not be checked and continues with the local copy.
4. GitHub remains a developer fallback only when the skill is running from a Git clone of `YingSuiAI/dirextalk-deployer`.

Auto update must not discard user edits inside an installed project-local skill directory. The npm installer writes a `.dirextalk-skill-install.json` manifest. If a target directory exists without that manifest, the CLI refuses to overwrite it unless the user provides `--force`.

## Testing

Focused tests should verify:

- The npm package metadata exists and exposes the `dirextalk-deployer` binary.
- `skill install --agent codex --scope project` copies the expected skill files to `.codex/skills/dirextalk-deployer`.
- `skill update` overwrites a managed install and refreshes the install manifest.
- An unmanaged existing target is protected unless `--force` is used.
- `skill refresh --dry-run` can resolve update intent without mutating the workspace.

Existing project validation remains required:

```bash
bash tests/skill_structure_test.sh
bash tests/s6_wire_local_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```

On Windows, also run:

```powershell
.\scripts\orchestrate.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrate.ps1 status
```

If the status command requires deployment state that is not available, record the reason and run the static checks.
