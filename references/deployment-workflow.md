# Deployment Workflow

## Conversation Confirmation Policy

For every user-facing confirmation in this workflow, accept a clear
natural-language confirmation in the user's own words. Do not require the user
to copy a fixed sentence, an environment variable, or a machine-generated
token. A short confirmation such as "confirm" or "go ahead" is sufficient when
the immediately preceding summary names the affected resource and its
consequences; otherwise ask one concise question for the missing fact.

The environment flags shown below remain machine-only safeguards. The agent
sets them only after the semantic user confirmation has been established.

## Preflight

1. Confirm `DOMAIN`, `DOMAIN_MODE`, and `CONFIRM_DOMAIN_BINDING=1`.
2. Confirm AWS region, credentials, billing, cloud provider, and costs. If no
   region is configured in state, `AWS_DEFAULT_REGION`/`AWS_REGION`, or the AWS
   profile, `scripts/orchestrate.sh` recommends a default region from the local
   timezone and uses it in non-interactive runs. Use `DIREXTALK_DEFAULT_REGION`
   for an explicit deployer default, or the standard AWS region settings for a
   run-specific choice.
3. Default cloud provider is Lightsail. S1 queries Lightsail bundles and
   Lightsail availability zones before provisioning, but does not query AWS
   Free Tier or credit usage.
   For manual Lightsail zone checks, use
   `aws lightsail get-regions --include-availability-zones --output json`;
   plain `aws lightsail get-regions` can omit availability-zone details and
   should not be used to decide that a region is unsupported.
   The explicit default Lightsail zone is `<region>a`; if it is unavailable,
   select another available Lightsail zone in the same region. If the selected
   region has no usable Lightsail bundle or availability zone, S1 records an EC2
   cost estimate but does not automatically switch to EC2. Ask the operator to
   choose another Lightsail-capable region/zone, or explicitly rerun with
   `DIREXTALK_CLOUD_PROVIDER=ec2` after reviewing the EC2 estimate. For explicit
   EC2, check regional hard blockers before mutating resources: default VPC, EC2
   vCPU quota, Elastic IP quota/current allocation, and Ubuntu AMI availability.
   For a manual EIP check, compare:

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value' --output text
aws ec2 describe-addresses --query 'length(Addresses[?Domain==`vpc`])' --output text
```

   If the selected region has no available Elastic IP capacity, stop before
   confirmation and ask the user to release an unused Elastic IP, request a
   higher EC2-VPC Elastic IP quota, or choose another region.
4. Check dependencies with the OS-specific commands in `tooling.md`.
5. Do not ask for the DNS provider. S2 checks the current AWS account for the
   longest matching public Route53 hosted zone. It selects Route53 automation
   when found; otherwise it continues with external DNS and requests the A
   record only after the fixed public IP exists.
6. Check state:

```bash
bash scripts/orchestrate.sh status
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh status
```

If state has resources, require one:

```bash
DIREXTALK_EXISTING_STATE_ACTION=continue
DIREXTALK_EXISTING_STATE_ACTION=destroy
DOMAIN=<different-domain>
```

For first-time credentials, offer the operator two paths before provisioning:
root access key or dedicated IAM deployment user. The root path is the fastest
because it uses the account owner identity directly, but it is highly
privileged; tell the operator to save the CSV securely, never paste or commit
it, and rotate or delete the root key after deployment. The dedicated
`DirextalkDeployer` IAM user path is safer because it avoids root keys, but it
requires more AWS console steps. Import the selected AWS access-key CSV and
verify the identity before provisioning:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer <region>
export AWS_PROFILE=dirextalk-deployer
bash scripts/aws-credentials.sh verify dirextalk-deployer
```

Before the first mutating AWS phase, produce a monthly estimate for the selected
region and cloud provider:

```bash
bash scripts/pricing-estimate.sh \
  --region <region> \
  --cloud-provider lightsail \
  --domain-mode route53
```

When `state.json` already exists, refresh and persist the same estimate:

```bash
bash scripts/pricing-estimate.sh --state ~/.dirextalk/nodes/<service_id>/state.json --write-state
```

For EC2 estimates, pass `--cloud-provider ec2 --instance-type t3.small --disk-gb 50`.

`scripts/orchestrate.sh` also writes `cost_estimate` automatically after region
selection and refreshes it in S3 after the final Lightsail bundle or EC2
instance type is known. Lightsail estimates include the default $12 bundle and
Route53 hosted-zone cost when applicable; EC2 estimates include EC2, gp3
storage, public IPv4, and Route53 hosted-zone cost when applicable. Estimates
exclude data transfer beyond included bundle allowances, TURN relay traffic,
domain registration, taxes, and AWS credits. Do not query AWS Free Tier or
credit usage. Tell the user that new AWS customer accounts generally receive
100-200 USD in free credits, and that users who have not used Lightsail
generally receive three months of free Lightsail usage. Credit and bundle-trial
coverage is account-specific; record the credit/trial reminder, AWS Billing
Console verification reminder, and that AWS official real-time policy prevails.
Set an AWS Budget or billing alert before leaving the node running.

## Destroy

From the repository root:

```bash
DOMAIN=__DOMAIN__ bash scripts/destroy.sh
```

On Windows, install Git for Windows and run the same command from Git Bash.
The deployer automatically records Windows-native local paths for Node.js and
local agent processes.

Destroy stops and uninstalls the local `dirextalk-connect` daemon only when `dirextalk-connect daemon status --service-name <service_id>` reports a `WorkDir` matching the current service directory, `~/.dirextalk/nodes/<service_id>/dirextalk-connect`. It then removes resources based on `cloud_provider`: Lightsail destroy releases the recorded static IP, deletes the Lightsail instance and key pair; EC2 destroy terminates the recorded EC2 instance, verifies the recorded EBS root volume, releases the Elastic IP, deletes the security group and key pair. Both paths remove Route53 records/zones created by the deployer, record AWS read-back results under `destroy.evidence`, and remove the corresponding local service directory under `~/.dirextalk/nodes/<service_id>`.

Destroy allows root AWS access-key identity when the operator explicitly chose
root credentials. Use the same deployment profile for teardown that was used
for provisioning.

Use `DIREXTALK_KEEP_WORKDIR=1 DOMAIN=__DOMAIN__ bash scripts/destroy.sh` only when preserving local state files for debugging; if used, report that the service directory still exists. This Bash command is the same on Windows Git Bash, Linux, and macOS.

## Run

From the repository root:

```bash
AWS_PROFILE=dirextalk-deployer \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
CONFIRM_DOMAIN_BINDING=1 \
DIREXTALK_CLOUD_PROVIDER=lightsail \
bash scripts/orchestrate.sh
```

S3 selects `dirextalk/message-server:latest` without querying message-server
GitHub Releases and persists `server_release.source=default_latest`,
`version=latest`, and the image reference before provisioning. Each new
deployment pulls the image currently published under `latest`. S3 also records
the deployer-owned independent updater version, commit, and
SHA-256 pin. User-data on the verified Ubuntu 22.04 or 24.04 x86_64 host downloads that
fixed Release asset, verifies the local pin, and atomically installs it; no
local Go toolchain or updater SCP step is required.
The updater's fixed Release download and checksum contract is unchanged.

### Fixed legacy d1 adoption

`scripts/adopt-legacy-node.sh` is a separate explicit operation, not normal
resume. Its dry run accepts only the recorded d1 source directory, Compose
project `dirextalk-p2p`, runtime v0.15.2, the approved legacy digest, minimal
healthy response, exact source Compose revision, and root-managed systemd Caddy
running as user/group `caddy`. A confirmed run copies an updater-owned Compose
definition and P2P state without pulling or recreating a container, records
`server_release.source=legacy_adopted`, then enters the existing pinned updater
bootstrap in systemd-Caddy mode. The Caddy edit exposes only public job URLs;
validation or reload failure restores the original file and removes the partial
updater layout.

For EC2, replace `DIREXTALK_CLOUD_PROVIDER=lightsail` with `DIREXTALK_CLOUD_PROVIDER=ec2` and add `INSTANCE_TYPE=t3.small` or a larger explicit type.

Exit codes:

- `0`: deployment complete.
- `1`: phase failed; inspect logs and rerun or destroy.
- `2`: waiting for user/external action, usually DNS or credentials.

## Operation Report

New deploys write a redacted machine-readable report to:

```text
~/.dirextalk/nodes/<service_id>/operation-report.json
```

Regenerate it from current state with:

```bash
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh report new_deploy
```

Destroy writes its audit report outside the service directory because the
service directory is removed:

```text
~/.dirextalk/reports/<service_id>/operation-report.json
```

Reports include operation type, S0-S7 gate status, user-confirmation gates,
credential/config paths, dirextalk-connect/MCP metadata, AWS resource IDs, billing
reminders, `billing.cost_estimate`, destroy read-back evidence under
`destroy.evidence` when applicable, AWS credit/Lightsail trial reminder,
AWS official policy reminder, AWS Billing Console verification reminder, and
redaction evidence. They must not
contain the initialization code, AWS secrets, access tokens, agent tokens, or
Matrix session tokens. User/runtime evidence is also scrubbed for
eight-or-more digit numeric strings because users may paste initialization
codes into confirmation notes. After reset/redeploy, the report must show
`credentials.status=refresh_pending`, `connect.install_status=refresh_pending`,
and `mcp.status=refresh_pending` until S5/S6/S7 and runtime checks refresh
local evidence. Image-only update does not clear local credentials,
confirmations, runtime checks, dirextalk-connect state, or MCP artifacts.

When the user or runtime evidence confirms a manual product gate, write it back
to state before regenerating the report. Connect daemon status is a
service-scoped local bridge check, MCP doctor is a non-polluting HTTP MCP
initialize check, MCP tools is HTTP MCP `tools/list` discovery, and MCP smoke is
a read-only HTTP MCP `tools/call` against `dirextalk_messages_list`. In the `DIREXTALK_AGENT_INSTALL=recommend` path, `verify runtime` records
`connect_daemon=manual_pending` instead of failing the aggregate, because
daemon installation is an explicit operator action. The default
`DIREXTALK_AGENT_INSTALL=auto` path expects dirextalk-connect to be installed
automatically during S6, while MCP uses the server HTTP endpoint directly. S6 waits for `dirextalk-connect is running`
in daemon logs and fails on local Agent startup errors before moving on. These
checks are not the full runtime product gate:

```bash
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify runtime

DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify connect_daemon
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_doctor
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_tools
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh verify mcp_smoke

DIREXTALK_CONFIRM_EVIDENCE="user completed app initialization" \
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh confirm app_initialization

DIREXTALK_CONFIRM_EVIDENCE="user sent a message and saw the agent reply" \
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh confirm real_chat

DIREXTALK_CONFIRM_RUNTIME_PROBE=1 \
DIREXTALK_CONFIRM_EVIDENCE="MCP doctor/tool discovery and runtime probe confirmed" \
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh confirm agent_mcp_runtime

DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh report new_deploy
```

`confirm agent_mcp_runtime` refuses to write the gate until
`runtime_checks.summary.status=passed` and `DIREXTALK_CONFIRM_RUNTIME_PROBE=1`
are both present. Use the flag only after the selected runtime/channel probe has
actually loaded the service-scoped MCP tools; `verify runtime` alone is an
internal non-polluting check, not the full product gate.
All `confirm` commands require `DIREXTALK_CONFIRM_EVIDENCE` with a concrete
user/runtime evidence note. The agent writes that machine-only note after a
clear natural-language user confirmation; it must not ask the user to provide
an exact phrase or environment variable. The evidence note must be at least 12
characters; avoid generic defaults or placeholders such as `ok`, `yes`, or
`done`.

## Existing Node Update

Update the running service image without recreating infrastructure or deleting
data:

```bash
DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 DOMAIN=__DOMAIN__ MESSAGE_SERVER_IMAGE=dirextalk/message-server:<debug-tag> bash scripts/update.sh
DIREXTALK_EXISTING_STATE_ACTION=continue DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
```

`update.sh` SSHes to the recorded cloud instance, runs Docker Compose pull/up,
reruns `/var/dirextalk-message-server/init-tokens.sh`, clears stale local secret fields, stops only
the matching service-scoped dirextalk-connect daemon when its `WorkDir` matches
this service, and marks S4-S7 pending so health, credential sync, local
MCP/agent wiring, and final verification run again. It does not remove Docker
volumes.

## Existing Node App Data Reset

Reset application data while preserving the cloud instance, fixed public
IP/static IP or Elastic IP, DNS, and Caddy TLS volumes:

```bash
DIREXTALK_RESET_APP_DATA_CONFIRM=1 DOMAIN=__DOMAIN__ bash scripts/reset-app-data.sh
DIREXTALK_EXISTING_STATE_ACTION=continue DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
```

`reset-app-data.sh` removes only `postgres-data`, `message-config`, and
`message-data`. It must not remove `caddy-data` or `caddy-config`; losing those
volumes can trigger certificate reissuance and Let's Encrypt rate limits. It
stops only the matching service-scoped dirextalk-connect daemon when its `WorkDir`
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
   DIREXTALK_EXISTING_STATE_ACTION=continue \
   DNS_READY=1 \
   AWS_PROFILE=dirextalk-deployer \
   AWS_DEFAULT_REGION=us-east-1 \
   DOMAIN=<DOMAIN> \
   DOMAIN_MODE=route53 \
   CONFIRM_DOMAIN_BINDING=1 \
   DIREXTALK_CLOUD_PROVIDER=lightsail \
   bash scripts/orchestrate.sh
   ```

2. **Use a different domain** — If you have multiple domains, destroy the
   current deployment and deploy on a domain without recent cert history:
   ```bash
   bash scripts/destroy.sh
   ```
   On Windows, run the same command from Git Bash.
   Then start again with a fresh domain.

3. **Force Caddy staging CA** (development only) — Set the environment
   variable `CADDY_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory`
   in the compose file to get a staging certificate. Staging certs are **not
   trusted by browsers** — use only for testing.

## Route53 DNS Mode

With automatically detected or explicitly selected `DOMAIN_MODE=route53`, S3
requires and reuses a matching public hosted zone, records the zone id in
`state.json`, upserts the A record, and waits for DNS to resolve. It does not
create a hosted zone or change registrar NS delegation.

If the current Route53 A record already points to a different IP, S3 stops
before changing DNS and records `route53_existing_a_value` plus
`route53_pending_a_value` in state. Confirm the replacement only after checking
that the old IP is safe to replace:

```bash
DIREXTALK_CONFIRM_DNS_OVERWRITE=1 \
DIREXTALK_EXISTING_STATE_ACTION=continue \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=route53 \
CONFIRM_DOMAIN_BINDING=1 \
bash scripts/orchestrate.sh
```

If an existing Route53 hosted zone is not yet authoritative because the domain
is registered elsewhere, delegate that zone's nameservers at the registrar or
through a provider API:

```bash
node scripts/json.mjs get ~/.dirextalk/nodes/<service_id>/state.json resources
```

After authoritative DNS returns the new IP, continue with the same state:

```bash
DIREXTALK_EXISTING_STATE_ACTION=continue \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=route53 \
CONFIRM_DOMAIN_BINDING=1 \
bash scripts/orchestrate.sh
```

Destroy retains backward-compatible cleanup for older state and deletes a
deployer-created hosted zone when state records
`route53_zone_created_by_deployer=true`; pre-existing or user-owned zones are
left in place.

## Manual DNS Mode

Use manual DNS mode only when an external DNS provider must keep managing the
domain and no DNS provider automation is available. When S3 emits the fixed
public IP, ask the user to set:

```text
<DOMAIN>  A  <PUBLIC_IP>
```

For Cloudflare, use DNS-only, not proxied. For Alibaba/HiChina, edit the A record in Alibaba Cloud DNS.

After authoritative DNS returns the new IP:

```bash
DNS_READY=1 \
AWS_PROFILE=dirextalk-deployer \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
DIREXTALK_CLOUD_PROVIDER=lightsail \
DIREXTALK_EXISTING_STATE_ACTION=continue \
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

All fields are written to `~/.dirextalk/nodes/<service_id>/credentials.json` with mode `0600`.
