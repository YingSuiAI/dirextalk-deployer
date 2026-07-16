# Deployment Optimization Audit

This file maps the 2026-06-26 deployment discussion checklist to the current
`dirextalk-deployer` branch. It is intentionally a deployer-side audit, not a
claim that every App or host-agent runtime has been proven in a real session.

## Status Legend

- Deployer-side implemented: implemented or guarded in this repository with
  scripts, docs, and regression tests.
- Runtime evidence still required: this repository can prepare or check the
  condition, but a real App, Codex, OpenClaw, Hermes, or MCP runtime must still
  provide final evidence.
- Deferred by design: intentionally outside the current deployer-side scope.

## Test Profiles And Windows Feedback Time

Windows Git Bash profiling on 2026-07-16 measured the release suite at 1313.3
seconds. The S6 extended failure matrix alone took 260 seconds; S6 wiring took
119 seconds, final delivery 78 seconds, status recovery 69 seconds, and runtime
summary 64 seconds. These were valid but mostly unrelated matrices being run
unconditionally, not AWS, Docker, WSL, or real deployment waits.

The test runner is therefore split deliberately:

- `npm test` discovers uncommitted files and commits ahead of `origin/main`,
  then runs only mapped boundary tests and their neighboring contracts.
- `npm run test:release` uses that affected plan plus LF, npm package, and skill
  structure checks. It no longer expands into unrelated cloud/runtime matrices.
- The isolated runner starts one authenticated loopback Node JSON worker. Test
  shells reuse it, while production retains the direct `scripts/json.mjs` CLI
  fallback, avoiding one native Node process per JSON key on Windows.
- `npm run test:quick` and `npm run test:stage` retain the portable baseline and
  default Lightsail workflow for explicit broader checks.
- `npm run test:full` retains optional EC2, legacy adoption, updater, detailed
  DNS, and exhaustive runtime compatibility matrices. It runs only on explicit
  manual request; CI keeps quick coverage cross-platform and the stage lane once
  on Ubuntu.

The split does not discard credential, DNS, initialization, S6, updater, or
destroy contracts. Redundant compatibility tests were merged into their
owning tests: default path inventory, runtime summary details, S5 timeout and
code-shape checks, root-volume tracking, Route53 overwrite protection, and
Route53 destroy calls. PowerShell-wrapper tests were removed with the retired
wrappers; Windows behavior is now covered by the Git Bash contract test.

## Current Best Plan

Current best plan is the stricter plan now encoded in this branch:

1. Use Lightsail as the default AWS path with the $12/month Linux bundle,
   dynamic cost estimate, Route53 automation, temporary IAM user guidance, and
   destroy evidence. Keep EC2 as an explicit `DIREXTALK_CLOUD_PROVIDER=ec2`
   option with the existing 50 GiB gp3 root volume default.
2. Keep all node-local deployment state under `~/.dirextalk/nodes/<service_id>/`.
   Do not mutate global host MCP configs or assume one computer has only one
   agent or one backend node.
3. Treat S7 as automated foundation checks only. `verify runtime is an internal
   non-polluting check`; it is not enough to declare the product complete.
4. Require explicit user App initialization and real chat evidence before user
   gates can be confirmed.
5. Keep Agent/MCP validation non-polluting by default, then let the user decide
   whether to send a real message in the Agent chat box.
6. Keep update/reset/destroy as separate operations with separate receipts;
   update/reset are now first-class scripts, not runbook-only manual actions.
7. Treat reset/redeploy follow-up as a Local refresh state: reset/redeploy
   clears old credentials, user confirmations, runtime checks, bridge install
   proof, and MCP install proof, so the next action is to rerun S4-S7 and
   runtime checks. Image-only update keeps local state intact.
8. Keep Lightsail and EC2 resource models separate: Lightsail has its own
   bundle/static-IP/state/destroy tests, while EC2 keeps VPC/EIP/security-group
   preflight and cleanup.

Audit anchors:
- verify runtime is an internal non-polluting check
- user App initialization and real chat evidence
- update/reset are now first-class scripts
- Local refresh
- Lightsail default path is implemented

## Requirement Mapping

### DEPLOY-P0-001 - Do Not Declare Completion Early

Status: Deployer-side implemented, with Runtime evidence still required.

Current evidence:
- `SKILL.md` defines Product Completion Gates and says S7 green is not final
  product completion.
- `scripts/orchestrate.sh confirm app_initialization|real_chat|agent_mcp_runtime`
  requires explicit evidence and rejects short generic confirmations.
- `tests/user_confirmation_gates_test.sh` and `tests/operation_report_test.sh`
  assert pending gates and redacted evidence.

Difference from the checklist:
- The checklist asked for product gates. The current branch implements them as
  state/report fields instead of a single "done" word.

Remaining evidence:
- Real user App initialization and real chat evidence.
- Real selected runtime confirmation that service-scoped MCP tools loaded.

### DEPLOY-P0-002 - OpenClaw Runtime Acceptance

Status: Deployer-side implemented, with Runtime evidence still required.

Current evidence:
- Runtime snippets are written under `~/.dirextalk/nodes/<service_id>/mcp/`.
- `verify mcp_doctor`, `verify mcp_tools`, `verify mcp_smoke`, and
  `verify runtime` are available.
- `mcp_smoke` uses a read-only backend action by default.
- `agent_mcp_runtime` confirmation requires both a passed runtime summary and
  `DIREXTALK_CONFIRM_RUNTIME_PROBE=1`.

Difference from the checklist:
- The deployer does not auto-send a test chat message. That is deliberate:
  internal probes are non-polluting, while user-visible chat proof stays a user
  action.

Remaining evidence:
- A real OpenClaw/Hermes/Codex runtime must prove it loaded the exact
  service-scoped MCP snippet and can use it.

### DEPLOY-P0-003 - Cost And Destroy Loop

Status: Deployer-side implemented.

Current evidence:
- `scripts/pricing-estimate.sh` records Lightsail bundle estimates by default
  and EC2/EBS/public IPv4/EIP estimates when `--cloud-provider ec2` is used,
  with fallback status when AWS Pricing cannot answer.
- `scripts/destroy.sh` reads AWS resources back and records `destroy.evidence`.
- `operation-report.json` includes `billing.destroy_cleanup_status` and
  `billing.possible_remaining_billable_resources`.
- Tests reject old wording that attached public IPv4/EIP is free.

Difference from the checklist:
- The checklist asked for deploy and destroy receipts. The current branch adds
  operation-scoped machine-readable reports so future agents can audit residue.

Remaining evidence:
- User should still review AWS Billing Console and AWS Budget status in the AWS
  account, because credits, tax, transfer, and usage are account-specific.

### DEPLOY-P0-004 - Domain And DNS Automation Protection

Status: Deployer-side implemented, with external-provider limits.

Current evidence:
- Route53 hosted zone reuse/create is automated.
- Existing A record overwrite is blocked unless
  `DIREXTALK_CONFIRM_DNS_OVERWRITE=1`.
- Authoritative DNS checks and tests cover hosted-zone and overwrite behavior.

Difference from the checklist:
- The current MVP automates Route53. If the domain is managed by another DNS
  provider without an available API or authorization, the correct state is
  waiting for authorization, not pretending completion.

Remaining evidence:
- Third-party DNS providers still need provider-specific automation before they
  can be treated like Route53.

### DEPLOY-P0-005 - Authorization And Security Boundary

Status: Deployer-side implemented.

Current evidence:
- `scripts/aws-credentials.sh import-csv|verify` imports local CSV credentials,
  tightens file permissions, allows root identity only with explicit operator
  choice, and redacts identity output.
- `SKILL.md` documents both the fast root access-key path with security
  warnings and the safer temporary `DirextalkDeployer` IAM user path with
  temporary `AdministratorAccess`, then cleanup.
- Reports and tests assert secrets are redacted and not written to reports.

Difference from the checklist:
- The current branch chooses the practical MVP path: let the operator choose
  fast root credentials or a safer temporary IAM admin user, with cleanup
  guidance after deployment.

Remaining evidence:
- Long-term least-privilege IAM generation is still a future hardening task.

### DEPLOY-P1-001 - Instance And Region Choice

Status: Deployer-side implemented.

Current evidence:
- `SKILL.md` keeps Lightsail as the default path and documents
  `DIREXTALK_CLOUD_PROVIDER=ec2` for EC2.
- Pricing is region-aware where AWS Pricing lookup succeeds, otherwise marked
  fallback.
- Docs steer ordinary users away from `t2.micro`/`t3.micro` as default
  production nodes.

Difference from the checklist:
- The current plan is simpler than a user choice matrix: recommend one default
  path, then allow explicit upgrade when the user asks for heavier usage.

Remaining evidence:
- Region choice still depends on where the user and their contacts are.

### DEPLOY-P1-002 - EC2 And Lightsail Path Separation

Status: Deployer-side implemented.

Current evidence:
- `SKILL.md` says the default cloud provider is Lightsail and EC2 is explicit.
- Tests cover Lightsail S3 provisioning and Lightsail destroy, while EC2 tests
  still cover EIP preflight and 50 GiB root EBS mapping.

Difference from the checklist:
- The deployer now provides both paths without mixing resource models.

Remaining evidence:
- Live Lightsail and EC2 deployments should still be exercised against disposable
  accounts before treating both paths as production-proven.

### DEPLOY-P1-003 - Recovery For Nontechnical Users

Status: Deployer-side implemented.

Current evidence:
- `orchestrate.sh status` prints a recovery summary with phase, billing impact,
  resume safety, next action, and stop-loss guidance.
- `reset` warns that resetting state can lose destroy resource records.
- Tests cover recovery output shape.

Difference from the checklist:
- The branch moves recovery language into the state command so it is available
  during real interrupted deployments, not only in docs.

Remaining evidence:
- Real failures should still be reviewed after live deploy runs to improve
  phase-specific wording.

### DEPLOY-P1-004 - Operation-Specific Receipts

Status: Deployer-side implemented.

Current evidence:
- `operation-report.json` supports `new_deploy`, `repair_or_verify`, `update`,
  `reset_app_data`, and `destroy`.
- `scripts/update.sh` updates an existing EC2 node without recreating infra or
  deleting data volumes.
- `scripts/reset-app-data.sh` clears application data only after strong
  confirmation and preserves infra/TLS state.
- `scripts/destroy.sh` records AWS cleanup evidence.

Difference from the checklist:
- The checklist said update/reset first-class scripts were still future work.
  They are now present in this branch.

Remaining evidence:
- Live update/reset should be exercised against a disposable deployed node
  before treating them as production-proven.

### DEPLOY-P1-005 - Redeploy Token Refresh

Status: Deployer-side implemented.

Current evidence:
- S5 refreshes bootstrap credentials from the server.
- S6 rewrites service-scoped `credentials.json`, `env`, dirextalk-connect config, and
  MCP snippets.
- Reset/redeploy mark S4-S7 pending and report refresh-pending status.
- Reset/redeploy stops only the matching service-scoped dirextalk-connect daemon
  when its `WorkDir` matches the current service, so stale local bridge
  processes do not keep using old credentials.
- `status` reports Local refresh when reset/redeploy cleared old credentials, user confirmations, runtime checks, bridge install proof, and MCP install proof.
- Runtime checks fail closed when a stale service directory or wrong WorkDir is
  detected.

Difference from the checklist:
- The current path is service-scoped by domain-derived service id, so multiple
  nodes can coexist without global credential pollution.

Remaining evidence:
- If a real runtime reports 401/403 after reset, first verify it is using the
  current service-scoped credential file before blaming the backend.

### DEPLOY-P2-001 - Automated And Human Acceptance Layers

Status: Deployer-side implemented, with Runtime evidence still required.

Current evidence:
- Delivery wording is "Automated Deployment Gates Passed", not final product
  completion.
- Reports keep automatic gates separate from user confirmation gates.
- Runtime confirmation has an explicit stricter path.

Difference from the checklist:
- The better plan is a layered state model: automated gates passed, user
  initialization pending, real chat pending, runtime confirmation pending.

Remaining evidence:
- Human confirmation is still required for App initialization and real chat.

### DEPLOY-P2-002 - User Initialization And Message Loop

Status: Deployer-side implemented for wording and gates, Runtime evidence still
required for the App loop.

Current evidence:
- Docs and delivery call the user-facing value an eight-digit app
  initialization code.
- Old wording around direct IM login is rejected by structure tests.
- `confirm app_initialization` and `confirm real_chat` record user evidence.

Difference from the checklist:
- The deployer can record and guard the App path, but the App itself must prove
  the domain plus eight-digit code flow and message readback.

Remaining evidence:
- Real App or simulator evidence that initialization completes, a user message
  is stored/synced, and the message can be read after refresh/restart.

### DEPLOY-P2-003 - Agent Agents Room Loop

Status: Deployer-side implemented for internal checks, Runtime evidence still
required for user-visible chat.

Current evidence:
- Non-polluting MCP doctor, tools discovery, read-only smoke, and aggregate
  runtime checks exist.
- `real_chat` cannot be confirmed from internal non-polluting probes alone.
- `agent_mcp_runtime` requires explicit runtime probe evidence.

Difference from the checklist:
- The user-facing proof stays simple: the user sends a message and sees the
  agent reply. Internal gate details stay as agent diagnostics.

Remaining evidence:
- Real chat in the selected host runtime, using the current service-scoped
  agent room and token.

### DEPLOY-P2-004 - Call And TURN Acceptance

Status: Deployer-side implemented for basic deployment acceptance.

Current evidence:
- S7 checks Matrix `turnServer` and requires non-empty valid TURN credentials.
- Security group and compose include coturn ports and configuration.
- `references/voip-turn-runbook.md` distinguishes basic deploy acceptance from
  real media-call testing.

Difference from the checklist:
- The current branch keeps real voice/video calls out of the blocking deploy
  gate. That is better because calls depend on devices, NAT, permissions, and
  client behavior beyond server deployment.

Remaining evidence:
- Real device call testing belongs to a VoIP-specific test pass, not every
  normal deployment.
