# Deployment Workflow

## Preflight

1. Confirm `DOMAIN`, `DOMAIN_MODE`, and `CONFIRM_DOMAIN_BINDING=1`.
2. Confirm AWS region, credentials, billing, instance type, and costs.
3. Check dependencies with the OS-specific commands in `tooling.md`.
4. Check current DNS provider. Prefer `DOMAIN_MODE=route53` when the user
   confirms AWS may manage the hosted zone and A record. Use `DOMAIN_MODE=user`
   only as a fallback when no DNS provider automation is available.
5. Check state:

```bash
bash scripts/orchestrate.sh status
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh status
```

If state has resources, require one:

```bash
P2P_EXISTING_STATE_ACTION=continue
P2P_EXISTING_STATE_ACTION=destroy
DOMAIN=<different-domain>
```

For first-time credentials, import the temporary `DirexioDeployer` IAM CSV and
verify the non-root identity before provisioning:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer <region>
export AWS_PROFILE=direxio-deployer
bash scripts/aws-credentials.sh verify direxio-deployer
```

Before the first mutating AWS phase, produce a monthly estimate for the selected
region and instance size:

```bash
bash scripts/pricing-estimate.sh \
  --region <region> \
  --instance-type t3.small \
  --disk-gb 8 \
  --domain-mode user
```

When `state.json` already exists, refresh and persist the same estimate:

```bash
bash scripts/pricing-estimate.sh --state ~/.direxio/nodes/<service_id>/state.json --write-state
```

`scripts/orchestrate.sh` also writes `cost_estimate` automatically after region
selection and refreshes it in S3 after the final EC2 instance type is known.
The estimate includes EC2, gp3 storage, public IPv4, and Route53 hosted-zone
cost when applicable. It excludes data transfer, TURN relay traffic, domain
registration, taxes, and AWS credits. Credit coverage is not guaranteed; verify
credits and actual charges in AWS Billing Console, and set an AWS Budget or
billing alert before leaving the node running.

## Destroy

From the repository root:

```bash
DOMAIN=__DOMAIN__ bash scripts/destroy.sh
```

Destroy stops the local `direxio-connect` daemon only when `direxio-connect daemon status --service-name <service_id>` reports a `WorkDir` matching the current service directory, `~/.direxio/nodes/<service_id>/cc-connect`. It then terminates the recorded EC2 instance, verifies the recorded EBS root volume, releases the Elastic IP, deletes the security group and key pair, removes Route53 records/zones created by the deployer, records AWS read-back results under `destroy.evidence`, and removes the corresponding local service directory under `~/.direxio/nodes/<service_id>`. This prevents stale credentials and `state.json` files from being treated as active deployments later while preserving an audit report for cleanup.

Destroy refuses root AWS access-key identity before any AWS mutation or local
service-state removal. Use the same temporary non-root `DirexioDeployer`
profile for teardown that is required for provisioning.

Use `P2P_KEEP_WORKDIR=1 DOMAIN=__DOMAIN__ bash scripts/destroy.sh` only when preserving local state files for debugging; if used, report that the service directory still exists.

## Run

From the repository root:

```bash
AWS_PROFILE=p2p-matrix \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

Exit codes:

- `0`: deployment complete.
- `1`: phase failed; inspect logs and rerun or destroy.
- `2`: waiting for user/external action, usually DNS or credentials.

## Operation Report

New deploys write a redacted machine-readable report to:

```text
~/.direxio/nodes/<service_id>/operation-report.json
```

Regenerate it from current state with:

```bash
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh report new_deploy
```

Destroy writes its audit report outside the service directory because the
service directory is removed:

```text
~/.direxio/reports/<service_id>/operation-report.json
```

Reports include operation type, S0-S7 gate status, user-confirmation gates,
credential/config paths, cc-connect/MCP metadata, AWS resource IDs, billing
reminders, `billing.cost_estimate`, destroy read-back evidence under
`destroy.evidence` when applicable, and redaction evidence. They must not
contain the initialization code, AWS secrets, access tokens, agent tokens, or
Matrix session tokens. User/runtime evidence is also scrubbed for
eight-or-more digit numeric strings because users may paste initialization
codes into confirmation notes. After update/reset, the report must show
`credentials.status=refresh_pending`, `connect.install_status=refresh_pending`,
and `mcp.status=refresh_pending` until S5/S6/S7 and runtime checks refresh
local evidence.

When the user or runtime evidence confirms a manual product gate, write it back
to state before regenerating the report. Connect daemon status is a
service-scoped local bridge check, MCP doctor is a non-polluting runtime check,
MCP tools is stdio `tools/list` discovery, and MCP smoke is a read-only backend
call. They are not the full runtime product gate:

```bash
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify runtime

DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify connect_daemon
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_doctor
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_tools
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_smoke

DIREXIO_CONFIRM_EVIDENCE="user completed app initialization" \
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh confirm app_initialization

DIREXIO_CONFIRM_EVIDENCE="user sent a message and saw the agent reply" \
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh confirm real_chat

DIREXIO_CONFIRM_RUNTIME_PROBE=1 \
DIREXIO_CONFIRM_EVIDENCE="MCP doctor/tool discovery and runtime probe confirmed" \
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh confirm agent_mcp_runtime

DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh report new_deploy
```

`confirm agent_mcp_runtime` refuses to write the gate until
`runtime_checks.summary.status=passed` and `DIREXIO_CONFIRM_RUNTIME_PROBE=1`
are both present. Use the flag only after the selected runtime/channel probe has
actually loaded the service-scoped MCP tools; `verify runtime` alone is an
internal non-polluting check, not the full product gate.
All `confirm` commands require `DIREXIO_CONFIRM_EVIDENCE` with a concrete
user/runtime evidence note; do not write user-confirmation gates with generic
default evidence. The evidence note must be at least 12 characters; avoid
placeholders such as `ok`, `yes`, or `done`.

## Existing Node Update

Update the running service image without recreating infrastructure or deleting
data:

```bash
DOMAIN=__DOMAIN__ MESSAGE_SERVER_IMAGE=direxio/message-server:latest bash scripts/update.sh
P2P_EXISTING_STATE_ACTION=continue DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
```

`update.sh` SSHes to the recorded EC2 instance, runs Docker Compose pull/up,
reruns `/opt/p2p/init-tokens.sh`, clears stale local secret fields, stops only
the matching service-scoped direxio-connect daemon when its `WorkDir` matches
this service, and marks S4-S7 pending so health, credential sync, local
MCP/agent wiring, and final verification run again. It does not remove Docker
volumes.

## Existing Node App Data Reset

Reset application data while preserving EC2, public IPv4/EIP, DNS, and Caddy
TLS volumes:

```bash
DIREXIO_RESET_APP_DATA_CONFIRM=1 DOMAIN=__DOMAIN__ bash scripts/reset-app-data.sh
P2P_EXISTING_STATE_ACTION=continue DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
```

`reset-app-data.sh` removes only `postgres-data`, `message-config`, and
`message-data`. It must not remove `caddy-data` or `caddy-config`; losing those
volumes can trigger certificate reissuance and Let's Encrypt rate limits. It
stops only the matching service-scoped direxio-connect daemon when its `WorkDir`
matches this service. After reset, treat old app users, rooms, messages,
initialization code, access token, agent token, and agent room as stale until
S5-S7 complete again.

## S4 Bootstrap Timeout / Certificate Rate Limit Recovery

When S4 fails with `healthz did not return 200 before timeout`, the most
common cause is **Let's Encrypt certificate rate limiting** (max 5 certs per
domain per 7 days). Caddy retries automatically with backoff, but the
orchestration script may time out first.

**How to check:**

```bash
ssh -i <keyfile> ubuntu@<public-ip> \
  'sudo docker logs p2p-caddy-1 --tail 20 2>&1 | grep -i "rateLimit\|retry after\|429"'
```

If rate-limited, the log shows `retry after <timestamp> UTC`.

**Recovery options:**

1. **Wait for rate limit to expire** — Caddy retries in the background.
   Check progress periodically:
   ```bash
   curl -skI https://<DOMAIN>/healthz  # returns 200 when cert is ready
   ```
   Once the endpoint returns 200, re-run orchestrate.sh to complete:
   ```bash
   P2P_EXISTING_STATE_ACTION=continue \
   DNS_READY=1 \
   AWS_PROFILE=p2p-matrix \
   AWS_DEFAULT_REGION=us-east-1 \
   DOMAIN=<DOMAIN> \
   DOMAIN_MODE=route53 \
   CONFIRM_DOMAIN_BINDING=1 \
   INSTANCE_TYPE=t3.small \
   bash scripts/orchestrate.sh
   ```

2. **Use a different domain** — If you have multiple domains, destroy the
   current deployment and deploy on a domain without recent cert history:
   ```bash
   bash scripts/destroy.sh
   ```
   Then start again with a fresh domain.

3. **Force Caddy staging CA** (development only) — Set the environment
   variable `CADDY_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory`
   in the compose file to get a staging certificate. Staging certs are **not
   trusted by browsers** — use only for testing.

## Route53 DNS Mode

With `DOMAIN_MODE=route53`, S3 reuses a matching hosted zone or creates one,
records the zone id and nameservers in `state.json`, upserts the A record, and
waits for DNS to resolve.

If the current Route53 A record already points to a different IP, S3 stops
before changing DNS and records `route53_existing_a_value` plus
`route53_pending_a_value` in state. Confirm the replacement only after checking
that the old IP is safe to replace:

```bash
DIREXIO_CONFIRM_DNS_OVERWRITE=1 \
P2P_EXISTING_STATE_ACTION=continue \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=route53 \
CONFIRM_DOMAIN_BINDING=1 \
bash scripts/orchestrate.sh
```

If the domain is registered outside Route53, delegate the recorded nameservers
at the current registrar or through a provider API:

```bash
jq '.resources | {route53_zone_id, route53_zone_name, route53_name_servers}' ~/.direxio/nodes/<service_id>/state.json
```

After authoritative DNS returns the new IP, continue with the same state:

```bash
P2P_EXISTING_STATE_ACTION=continue \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=route53 \
CONFIRM_DOMAIN_BINDING=1 \
bash scripts/orchestrate.sh
```

Destroy deletes deployer-created hosted zones when state records
`route53_zone_created_by_deployer=true`; pre-existing or user-owned zones are
left in place.

## Manual DNS Mode

Use manual DNS mode only when no DNS provider automation is available. When S3
emits an Elastic IP, ask the user to set:

```text
<DOMAIN>  A  <PUBLIC_IP>
```

For Cloudflare, use DNS-only, not proxied. For Alibaba/HiChina, edit the A record in Alibaba Cloud DNS.

After authoritative DNS returns the new IP:

```bash
DNS_READY=1 \
AWS_PROFILE=p2p-matrix \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
P2P_EXISTING_STATE_ACTION=continue \
bash scripts/orchestrate.sh
```

## Initialization Code Field

Current backend delivery uses the `password` field for the user-facing eight-digit app initialization code, a unified user `access_token`, and an agent-only `agent_token`.

State fields after S5:

```text
password
agent_token
access_token
as_url
```

All fields are written to `~/.direxio/nodes/<service_id>/credentials.json` with mode `0600`.
