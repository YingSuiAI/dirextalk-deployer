# Verification And Recovery

## Fresh Verification

Run the built-in acceptance phase through the state machine:

```bash
bash scripts/orchestrate.sh status
```

Complete state shows `current: DONE` and S0-S7 as `done`.

The status command also prints a `Recovery summary`. When `current` is not
`DONE`, use that summary as the user-facing explanation instead of exposing only
raw phase names. It covers:

- where the deployment is blocked;
- whether recorded EC2, public IPv4/EIP, or EBS resources may still be billing;
- whether it is safe to rerun or must continue with preserved `state.json`;
- the next action for the current phase;
- stop-loss guidance through destroy when resources exist.

Independent checks:

```bash
curl -fsS https://<DOMAIN>/healthz
curl -fsS https://<DOMAIN>/_matrix/client/versions
curl -fsS https://<DOMAIN>/.well-known/matrix/server
curl -fsS https://<DOMAIN>/.well-known/portal/owner.json
```

If local DNS lags but authoritative DNS is correct, use:

```bash
curl --resolve <DOMAIN>:443:<PUBLIC_IP> -fsS https://<DOMAIN>/healthz
```

## Common Waiting Points

- S0 waits for valid AWS credentials.
- S1 waits for default VPC, EC2 quota, or AMI availability.
- S3 waits for DNS A record.
- S4 waits for Docker/image pulls/Caddy certificate issuance.
- S5 waits for `/opt/p2p/bootstrap.json` and password/agent_token extraction.

Rerun the same command after fixing the blocker; state resumes from the first unfinished phase.

After S3, do not reset or delete state just to silence an error. If EC2, public
IPv4/EIP, or other AWS resources are recorded, preserve `state.json`, repair the
blocker, and rerun with `DIREXIO_EXISTING_STATE_ACTION=continue`; or destroy first
if the user wants to stop billing.

## Destroy

Destroy recorded AWS resources while state exists:

```bash
DOMAIN=__DOMAIN__ bash scripts/destroy.sh
```

Destroy stops and uninstalls the local `direxio-connect` daemon only when its reported `WorkDir` matches the current service's `~/.direxio/nodes/<service_id>/direxio-connect` directory. It then cleans recorded EC2, EBS root volume, EIP, key pair, security group, Route53 records/zones created by the deployer, and current service directory best-effort. Before removing local state, it records AWS read-back cleanup evidence under `destroy.evidence`. User-managed DNS records and purchased domains remain the user's responsibility.

After destroy, read the redacted audit report at:

```text
~/.direxio/reports/<service_id>/operation-report.json
```

Use it to report which recorded AWS resources were processed, which AWS
read-back checks show released or deleted resources, and which external items
remain outside automatic destroy scope.

## Update / Reset Follow-Up

After `scripts/reset-app-data.sh`, rerun:

```bash
DIREXIO_EXISTING_STATE_ACTION=continue DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
```

The reset script intentionally marks S4-S7 pending and clears stale local secret
fields. Do not copy old initialization codes or tokens from chat history,
`state.json`, or `credentials.json`; S5 must fetch fresh bootstrap data and S6
must rewrite service-scoped local credentials/MCP snippets and reinstall local
packages by default.

After `scripts/update.sh`, do not rerun S4-S7 just because the service was
restarted. Image-only update preserves local credentials, direxio-connect daemon
state, MCP artifacts, confirmations, and runtime checks unless a separate
verification shows the server regenerated bootstrap credentials.
