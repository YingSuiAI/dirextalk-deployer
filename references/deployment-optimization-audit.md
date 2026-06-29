# Deployment Optimization Audit

This file maps the 2026-06-26 deployment discussion checklist to the current
`direxio-deployer` branch. It is intentionally a deployer-side audit, not a
claim that every App or host-agent runtime has been proven in a real session.

## Status Legend

- Deployer-side implemented: implemented or guarded in this repository with
  scripts, docs, and regression tests.
- Runtime evidence still required: this repository can prepare or check the
  condition, but a real App, Codex, OpenClaw, Hermes, or MCP runtime must still
  provide final evidence.
- Deferred by design: not part of the current EC2 MVP path.

## Current Best Plan

Current best plan is the stricter plan now encoded in this branch:

1. Keep one EC2 MVP path first, with `t3.small` default, dynamic cost estimate,
   Route53 automation, temporary IAM user guidance, and destroy evidence.
2. Keep all node-local deployment state under `~/.direxio/nodes/<service_id>/`.
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
7. Treat update/reset follow-up as a Local refresh state: update/reset cleared
   old credentials, user confirmations, runtime checks, and bridge install
   proof, so the next action is to rerun S4-S7 and runtime checks.
8. Keep Lightsail out of the current user-facing path. Lightsail remains
   deferred until it has an independent resource model, pricing, state,
   destroy, and test matrix.

Audit anchors:
- verify runtime is an internal non-polluting check
- user App initialization and real chat evidence
- update/reset are now first-class scripts
- Local refresh
- Lightsail remains deferred

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
- Runtime snippets are written under `~/.direxio/nodes/<service_id>/mcp/`.
- `verify mcp_doctor`, `verify mcp_tools`, `verify mcp_smoke`, and
  `verify runtime` are available.
- `mcp_smoke` uses a read-only backend action by default.
- `agent_mcp_runtime` confirmation requires both a passed runtime summary and
  `DIREXIO_CONFIRM_RUNTIME_PROBE=1`.

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
- `scripts/pricing-estimate.sh` records EC2, EBS, public IPv4/EIP, and Route53
  estimate fields, with fallback status when AWS Pricing cannot answer.
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
  `DIREXIO_CONFIRM_DNS_OVERWRITE=1`.
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
  tightens file permissions, blocks root identity, and redacts identity output.
- `SKILL.md` documents the temporary `DirexioDeployer` IAM user path with
  temporary `AdministratorAccess`, then cleanup.
- Reports and tests assert secrets are redacted and not written to reports.

Difference from the checklist:
- The current branch chooses the practical MVP path: temporary IAM admin user,
  no root access keys, and cleanup guidance after deployment.

Remaining evidence:
- Long-term least-privilege IAM generation is still a future hardening task.

### DEPLOY-P1-001 - Instance And Region Choice

Status: Deployer-side implemented.

Current evidence:
- `SKILL.md` keeps the current MVP path as EC2 `t3.small` by default.
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

Status: Deployer-side implemented for EC2 boundary, Deferred by design for
Lightsail.

Current evidence:
- `SKILL.md` says the current MVP deployment path is EC2-only.
- Tests reject wording that offers Lightsail as an implemented automatic path.

Difference from the checklist:
- No current script attempts to mix Lightsail into the EC2 state machine. That
  is the safer plan.

Remaining evidence:
- A future `deploy_mode=lightsail` must have independent provision, DNS,
  state, pricing, destroy, and tests before being offered.

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
- S6 rewrites service-scoped `credentials.json`, `env`, cc-connect config, and
  MCP snippets.
- Update/reset mark S4-S7 pending and report refresh-pending status.
- Update/reset stops only the matching service-scoped direxio-connect daemon
  when its `WorkDir` matches the current service, so stale local bridge
  processes do not keep using old credentials.
- `status` reports Local refresh when update/reset cleared old credentials, user confirmations, runtime checks, and bridge install proof.
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
