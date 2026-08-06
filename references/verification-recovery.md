# Verification And Recovery

## Contents

- Fresh verification
- Common waiting points
- Production split update and reconcile
- Reboot recovery
- Recovery acceptance gate
- Destroy
- Update/reset follow-up

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
curl -fsS https://<DOMAIN>/_p2p/health
curl -fsS https://<DOMAIN>/_matrix/client/versions
curl -fsS https://<DOMAIN>/.well-known/matrix/server
curl -fsS https://<DOMAIN>/.well-known/portal/owner.json
```

If local DNS lags but authoritative DNS is correct, use:

```bash
curl --resolve <DOMAIN>:443:<PUBLIC_IP> -fsS https://<DOMAIN>/_p2p/health
```

## Common Waiting Points

- S0 waits for valid AWS credentials.
- S1 waits for default VPC, EC2 quota, or AMI availability.
- S3 waits for DNS A record.
- S4 waits for Docker/image pulls/Caddy certificate issuance.
- S5 waits for `/var/dirextalk-message-server/p2p/bootstrap.json` and password/agent_token extraction.

Rerun the same command after fixing the blocker; state resumes from the first unfinished phase.

After S3, do not reset or delete state just to silence an error. If EC2, public
IPv4/EIP, or other AWS resources are recorded, preserve `state.json`, repair the
blocker, and rerun with `DIREXTALK_EXISTING_STATE_ACTION=continue`; or destroy first
if the user wants to stop billing.

## Production Split Update And Reconcile

Use the local lifecycle entrypoint for a normal existing-node update:

```bash
DOMAIN=<DOMAIN> bash scripts/update.sh
```

It stages the current production helpers and invokes the canonical
receipt-bound reconcile path. Reconcile verifies and repairs the protected
edge, calls `recover-production.sh`, and refreshes the portal bootstrap through
the canonical exporter. It must not select a stack by mutable Compose name,
replace an image ad hoc, or operate without the protected split and edge
receipts.

Use the installed host helper directly only while diagnosing the same verified
node identity. Before every read, retry, or mutation, revalidate the recorded
AWS account, region, provider, immutable instance identifier, machine-id, and
Docker Engine ID; stop if any identity differs:

```bash
sudo /var/dirextalk-message-server/production-ops/reconcile-production.sh
```

Preserve its three result classes through every caller and wrapper:

- `0`: operation and postconditions succeeded.
- `3`: expected negative state, such as an absent completed runtime or an
  incomplete receipt; stop for the matching operator decision.
- Any other nonzero status: infrastructure, identity, or contract failure;
  report the failing boundary and do not relabel it as a negative state.

## Reboot Recovery

Production split supports Ubuntu 24.04+ x86_64 with systemd >= 254, unified
cgroup v2, and rootful Docker. The installed
`dirextalk-split-recovery.service` is a root-owned systemd oneshot ordered after
and requiring `docker.service`. Its only entrypoint is:

```text
/var/dirextalk-message-server/production-ops/recover-production.sh
```

Recovery rebinds the completed runtime from the protected receipt, runs the
canonical `prepare-runner-cgroups.sh` for that exact stack, protects the new
runner-preparation receipt, waits for the receipt-recorded `agent`,
`extension-runner`, and `core-runner` containers to leave their short
`restarting` state, and then calls the canonical `restart-agent-local.sh` for
the same run. Do not start the three services independently or recreate them
with a guessed Compose project.

The service is enabled during provisioning, not started immediately. After a
real reboot, inspect it with:

```bash
sudo systemctl show dirextalk-split-recovery.service \
  -p Result -p ExecMainStatus -p ActiveState
```

Manual runtime-only recovery uses
`sudo /var/dirextalk-message-server/production-ops/recover-production.sh` and
the same three-state result contract. Use reconcile instead when edge or portal
bootstrap repair is also required.

## Recovery Acceptance Gate

Do not accept reboot recovery from container names or a green helper alone.
Require all of the following from the immutable node identity and the
receipt-bound stack:

- `dirextalk-split-recovery.service` reports `Result=success` and
  `ExecMainStatus=0`.
- The current `runner-preparation.env` still binds the receipt's exact stack
  and host identities. Its extension and Core parent `cgroup.procs` files are
  owned by `65531:65531` and `65530:65530`, respectively, and both delegated
  roots' `cgroup.subtree_control` contain `cpu`, `memory`, and `pids`.
- The exact receipt-recorded `agent`, `extension-runner`, and `core-runner`
  containers are running and healthy; the receipt-bound message server and
  protected edge are also healthy.
- Trusted HTTPS health succeeds through the deployed domain, not only through
  a container-local endpoint.
- Previously persisted configuration and product data still read back after
  reboot. At minimum, verify the active model profile, provider credential
  redaction/status, and a prior conversation context; include Knowledge or
  Memory readback when those capabilities were configured before reboot.

If any gate fails, preserve the node and receipts, isolate the smallest real
failure, and run the appropriate recovery or reconcile entrypoint. Do not fresh
deploy merely to clear reboot evidence.

## Destroy

Destroy recorded AWS resources while state exists:

```bash
DOMAIN=__DOMAIN__ bash scripts/destroy.sh
```

Destroy stops and uninstalls the local `dirextalk-connect` daemon only when its reported `WorkDir` matches the current service's `~/.dirextalk/nodes/<service_id>/dirextalk-connect` directory. It then cleans recorded EC2, EBS root volume, EIP, key pair, security group, Route53 records/zones created by the deployer, and current service directory best-effort. Before removing local state, it records AWS read-back cleanup evidence under `destroy.evidence`. User-managed DNS records and purchased domains remain the user's responsibility.

After destroy, read the redacted audit report at:

```text
~/.dirextalk/reports/<service_id>/operation-report.json
```

Use it to report which recorded AWS resources were processed, which AWS
read-back checks show released or deleted resources, and which external items
remain outside automatic destroy scope.

## Update / Reset Follow-Up

After `scripts/reset-app-data.sh`, rerun:

```bash
DIREXTALK_EXISTING_STATE_ACTION=continue DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
```

The reset script intentionally marks S4-S7 pending and clears stale local secret
fields. Do not copy old initialization codes or tokens from chat history,
`state.json`, or `credentials.json`; S5 must fetch fresh bootstrap data and S6
must rewrite service-scoped local credentials/MCP snippets and reinstall local
packages by default.

After `scripts/update.sh`, do not rerun S4-S7 just because the service was
restarted. Image-only update preserves local credentials, dirextalk-connect daemon
state, MCP artifacts, confirmations, and runtime checks unless a separate
verification shows the server regenerated bootstrap credentials.
