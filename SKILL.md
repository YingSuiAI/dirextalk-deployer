---
name: dirextalk-deployer
description: Operate a production Dirextalk message server on AWS. Use for deploy, resume, status, verify, update, reset, destroy, local dirextalk-connect/MCP wiring, or an explicit install/refresh of this skill; do not use for ordinary repository development or review.
---

# Dirextalk Deployer

Use the packaged scripts as the execution engine. Read only the reference for the selected phase.

## Select The Operation

| Intent | POSIX | Windows PowerShell |
| --- | --- | --- |
| deploy/resume/status/verify/report | `bash scripts/orchestrate.sh ...` | `.\scripts\orchestrate.ps1 ...` |
| destroy | `bash scripts/destroy.sh` | `.\scripts\destroy.ps1` |
| server image update | `bash scripts/update.sh` | Run through the documented POSIX host/runtime |
| reset app data | `bash scripts/reset-app-data.sh` | Run through the documented POSIX host/runtime |

For an existing node, run `status` and inspect its redacted recovery summary before changing state. Resume with the same installed package/source and AWS identity that created the state unless the user explicitly requests and authorizes a tool upgrade.

## Version And Installation

- Record the current package/skill version and source before operating. A read-only `npm view dirextalk-deployer version` may show that an update exists.
- Keep the installed package, skill, and execution engine unchanged during deploy/resume/verify/destroy.
- When the user explicitly asks to install or update the skill, read `references/agent-targets.md`, install a versioned npm package, refresh the requested runtime target, and report the installed version/source. Use project scope only when requested.

## Safety Gate

Before the first cloud mutation for a new node:

1. Confirm a real long-lived domain, DNS authority, supported AWS region/provider, and a verified AWS profile or local credential file.
2. Prefer a least-privilege deployment profile. Root access keys are allowed only when the operator explicitly chooses them after a security warning.
3. Run the repository pricing/quota preflight and present the current estimate from tooling. Direct the user to current AWS pricing, Budgets, and Billing; do not promise credits or free usage from memory.
4. Obtain one explicit confirmation naming the domain, AWS identity/profile, region, provider, and authorization to create billable resources. Existing read-only inspection does not need this confirmation.

Never print or commit AWS secrets, SSH private keys, app initialization codes, Matrix/agent tokens, `.env`, credential files, or unredacted state. Report account/region/resource identities and booleans only. Use credential helpers and restrictive files; keep secrets out of argv and logs.

## Platform And Release Boundaries

- Remote server paths are Linux. Local bridge/agent paths match the process consuming them; Windows-native paths are not WSL/MSYS paths.
- New cloud hosts use supported Ubuntu 22.04/24.04 x86_64 images. The deployer installs the independently released updater only from its pinned immutable Release/commit/SHA.
- Normal server selection resolves the latest published stable GitHub Release and persists an immutable image digest. Mutable `latest` and arbitrary image overrides are not production defaults.
- Leave normal DNS mode automatic. A matching Route53 public zone may be managed; external DNS remains user/provider controlled. Never infer an API failure as external DNS.
- Use the dedicated tested legacy-adoption script only for its exact documented topology; never use normal resume to guess a legacy host.

Read `references/deployment-workflow.md` for prerequisites, confirmation, DNS, pricing, phase behavior, and recovery. Read `references/windows-deployment-notes.md` for Windows entrypoints and path handling.

## Local Agent And MCP

- The bridge is service-scoped `dirextalk-connect`, using a real `agent_room_id` and an `@agent:<server>` Matrix session created with `agent_token`.
- Dirextalk MCP is bearer-authenticated HTTP at `https://<domain>/mcp`. Do not install a local Dirextalk MCP CLI, daemon, proxy, stdio bridge, env shim, or listening port.
- Capability is explicit and fail-closed. Complete the applicable session injection, host-owned registry enrollment, or documented unsupported result; never generate a generic fallback.
- Host-owned registries remain authoritative and cannot be bypassed by selecting a child backend. Do not mutate a user's global host config without explicit authorization.
- Runtime verification is non-polluting: prefer doctor/tool discovery and read-only probes instead of sending normal chat content.

Read `references/agent-targets.md` for installation targets and `references/runtime-wiring.md` for current capability/host instructions.

## Completion And Recovery

A green server health check is not the complete product gate. For a new node, also account for:

- delivery of the App domain and eight-digit app initialization code;
- user confirmation that App initialization succeeded;
- applicable dirextalk-connect and remote MCP verification;
- a redacted `operation-report.json` with recovery, resource, and billing status.

Use the documented `verify` and `confirm` commands in `references/verification-recovery.md` and `references/deployment-workflow.md`. Do not fabricate user confirmation or runtime evidence.

For update/reset, preserve infrastructure and unrelated node state exactly as documented; `reset-app-data.sh` requires `DIREXTALK_RESET_APP_DATA_CONFIRM=1`. For destroy, use the deployment's AWS identity boundary, stop only the matching service-scoped bridge, remove recorded resources, and continue cleanup while `possible_remaining_billable_resources` is non-empty. AWS Console/Billing is the final cleanup authority.

When blocked, report the failed phase, billing impact, resume safety, exact next action, and stop-loss option. See `references/verification-recovery.md`, `references/token-refresh.md`, and `references/troubleshooting.md` only when those branches apply.
