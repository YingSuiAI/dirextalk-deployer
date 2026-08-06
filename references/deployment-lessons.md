# Production Deployment Lessons

This note captures reusable lessons from deploying `<domain>` on AWS from a
Windows workstation. Keep it short and practical:
symptom, cause, and what the next operator or agent should do.

## Message Server Bootstrap Initialization

Symptom:

```text
S5_INIT_TOKENS failed: read bootstrap.json timed out
/var/dirextalk-message-server/p2p/bootstrap.json was missing or incomplete
```

Cause:

The production application is the protected canonical split project. Its
message-server atomically creates complete Portal/Agent bootstrap credentials,
including the real Agent Matrix room, inside the owned `message_server_data`
volume. The deployer does not repair or synthesize that server-owned state.

Fix now in ops:

- `bootstrap-production.sh` provisions and starts the canonical split stack
  from `/var/dirextalk-message-server/deploy/split-agent/compose.yaml` with
  protected `/var/dirextalk-message-server/split/.env`.
- Canonical `deploy/split-agent/scripts/export-portal-bootstrap.sh` verifies
  the running container belongs to that immutable stack and copies its
  complete bootstrap file to a fresh mode-0400 host path.
- Local S5 reads the sealed host export at
  `/var/dirextalk-message-server/p2p/bootstrap.json`, normalizes it into local
  `outputs.json`, and stores the current credentials in state.

Portal owner discovery is served by message-server's dynamic
`/.well-known/portal/owner.json` handler. Do not reintroduce deployer-written
`owner.json` files or Caddy static file mounts for this endpoint.

## Windows Runtime Pitfalls

Native Windows deployment uses Git for Windows Git Bash only. Native WSL is a
separate supported Linux host and runs Bash directly. From Git Bash, verify the
Windows installation before running a lifecycle command:

```bash
case "$(uname -s)" in
  MINGW*) git_root=$(git --exec-path 2>/dev/null | sed 's#/mingw64/libexec/git-core$##'); command -v git >/dev/null && command -v cygpath >/dev/null && git --version | grep -q '\.windows\.' && [ -n "$git_root" ] && [ "$(cygpath -m "${EXEPATH:-}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s/bin' "$git_root" | tr '[:upper:]' '[:lower:]')" ] ;;
  Linux*|Darwin*) true ;;
  *) false ;;
esac
command -v node aws ssh curl
```

If the Git Bash preflight fails, install Git for Windows from
<https://git-scm.com/download/win>, reopen Git Bash, and stop. Do not substitute
PowerShell, MSYS2, or Cygwin. Do not switch the same service state between
native Windows Git Bash and WSL.

The orchestrator uses the repository's Node.js JSON helper for local JSON
processing, so Git Bash must be able to run `node` against the same path style
it passes to the scripts.

Prefer the `ssh` that belongs to Git Bash. Windows OpenSSH can reject EC2
private keys because inherited ACLs make the `.pem` look too open, even when
Git Bash OpenSSH accepts it. If using a Windows-native tool for a separate
diagnostic, fix the key ACL instead of disabling SSH checks.

## Local Polling Can Hang While The Server Is Healthy

Symptom:

- `state.json` stays at `S4_BOOTSTRAP_STACK=polling`.
- `https://<domain>/_p2p/health` returns `{"status":"ok"}` from another shell.
- A leftover local `curl -skf https://<domain>/_p2p/health` or SSH child process is
  still running after the agent/operator interrupted the deployment turn.

Cause:

The cloud side may have completed successfully, but a local network call can
hang long enough that the state machine never records the successful phase. This
is especially confusing on Windows when proxy settings, direct TCP reachability,
or interrupted terminal sessions leave child processes behind.

Fix now in ops:

- S4 health checks use per-attempt curl timeouts:
  `HEALTH_CURL_CONNECT_TIMEOUT` and `HEALTH_CURL_MAX_TIME`.
- S5 SSH reads use non-interactive SSH options plus `SSH_COMMAND_TIMEOUT` when
  the local `timeout` command is available.
- If a deployment was interrupted, inspect `scripts/orchestrate.sh status`,
  stop only leftover local `orchestrate.sh`/`curl`/`ssh` children for that run,
  and resume with `DIREXTALK_EXISTING_STATE_ACTION=continue`.
- If SSH to the instance is blocked but AWS access still works, attach a
  temporary SSM role and use SSM Run Command to read `/var/dirextalk-message-server/p2p/bootstrap.json`
  without printing secrets. Remove or audit the temporary role after recovery.

## DNS And State Handling

For `DOMAIN_MODE=user`, S3 intentionally stops after allocating the EIP and waits
until the real DNS A record points at that EIP. Continue only after public DNS
resolves correctly. This avoids Caddy and Let's Encrypt racing DNS propagation.

When rerunning after a resource was created, set:

```bash
DIREXTALK_EXISTING_STATE_ACTION=continue
```

This is deliberate. It prevents accidental duplicate EC2/EIP creation or unsafe
reuse of an old deployment state.

## Credential Safety

Offer two credential paths for first-time deployment. Root access keys are the
fastest path but are highly privileged; report that the identity is root,
remind the operator to save the CSV securely, and rotate or remove the key when
it is no longer needed. A temporary `DirextalkDeployer` IAM user or dedicated IAM
role is safer but requires more AWS console steps.

Do not store AWS AK/SK in skill files, docs, or committed repo files. Treat
`state.json`, `outputs.json`, and `~/.dirextalk/nodes/<service_id>/credentials.json` as local
secrets because they contain the portal/agent token after S5.

## Route53 Delegation From Third-Party Registrar

Symptom:

- User chose `DOMAIN_MODE=route53` but the domain is registered at Alibaba Cloud / GoDaddy / Cloudflare (not AWS Route53 registrar).
- A matching Route53 hosted zone already exists and S3 upserts the A record,
  but public DNS still does not resolve to the new IP.

Cause:

The deployer does not create hosted zones or change registrar delegation.
Route53 does not become authoritative until the current registrar delegates the
existing zone's NS records. When the domain administrator is a third party, the
user or a provider-specific DNS connector must update NS delegation outside AWS.

Fix procedure:

1. Read the detected zone details from `state.json`:
   ```bash
   node scripts/json.mjs get ~/.dirextalk/nodes/<service_id>/state.json resources
   ```
2. Delegate those NS servers at the current registrar, or use the provider API
   if credentials are available.
3. Wait for authoritative NS and A-record propagation.
4. Re-run `scripts/orchestrate.sh` with `DIREXTALK_EXISTING_STATE_ACTION=continue`.

DNS propagation of new NS records can take minutes to hours. After the user
confirms the change, verify with `nslookup -type=NS <DOMAIN>` or
`dig NS <DOMAIN> +short`. The S3 phase's `_require_user_dns_ready()` will
handle the A-record wait loop.

Always report:

- App domain and eight-digit app initialization code, with the code sourced from the backend `password` field.
- Portal token or where it was written.
- `~/.dirextalk/nodes/<service_id>/credentials.json` status and profile shape.
- AWS region, EC2 instance ID, public IP, security group, state path, SSH command.
- Stop-billing guidance: ask the agent to destroy this node when finished; AWS resources keep billing until teardown completes.
- Any manual DNS record the user owns outside Route53.

## Let's Encrypt Certificate Rate Limits

Symptom:

- S4_BOOTSTRAP_STACK health check times out after 5-10 minutes.
- SSH reveals all containers are up and healthy (caddy, message-server, postgres, coturn).
- the protected edge Compose `caddy` logs show repeated errors:

  ```
  HTTP 429 urn:ietf:params:acme:error:rateLimited - too many certificates (5)
  already issued for this exact set of identifiers in the last 168h0m0s,
  retry after ...
  ```

Cause: Let's Encrypt allows at most 5 certificates per domain per 168 hours (7 days). Redeploying the same domain repeatedly within a week exhausts this quota.

Recovery:

1. Confirm the failure in the protected edge project; do not bypass its
   canonical Compose plus root-owned override:
   ```bash
   sudo docker compose \
     --env-file /var/dirextalk-message-server/edge.env \
     -f /var/dirextalk-message-server/deploy/split-agent/edge-compose.yaml \
     -f /var/dirextalk-message-server/production-ops/edge-compose.override.yaml \
     logs --tail=120 caddy
   ```
2. Wait for the CA retry time, or choose a different permanent test domain.
   The production contract does not replace public TLS with `tls internal`.
3. Resume with
   `DIREXTALK_EXISTING_STATE_ACTION=continue bash scripts/orchestrate.sh`.
   The root-owned production bootstrap re-renders Caddy from its protected
   source and reuses the named Caddy data/config volumes.
4. Verify `https://<domain>/_p2p/health`; do not use `-k` as production acceptance.

Prevention:

- Use a separate subdomain per deployment cycle (e.g. `__DOMAIN_A__`, `__DOMAIN_B__`) when doing repeated test deployments within 7 days.
- Preserve the edge project's named Caddy data/config volumes; recovery and
  reconcile paths validate their ownership before reuse.

## Route53 Duplicate Zone Detection

Symptom: A new hosted zone was created via `aws route53 create-hosted-zone` for a domain that already had a Route53 zone from a prior deployment. The NS records of the new zone do not match the NS records configured at the registrar, so DNS resolution still uses the old zone's servers.

Fix:

1. List all existing zones first: `aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]'`
2. Check which zone's NS servers match DNS: `nslookup -type=NS <domain>`
3. If the domain is already delegated to Route53, use the matching existing zone.
4. Delete the duplicate: `aws route53 delete-hosted-zone --id /hostedzone/<DUPLICATE_ID>`

Prevention:

- Before deployment, check for existing zones. If one exists and its NS records
  match current DNS delegation, no new zone is needed; S3 will reuse it.
- Let S3 create a new hosted zone only when deploying a domain with no matching
  Route53 zone or when migrating DNS delegation for the first time.
- Destroy attempts to delete hosted zones recorded as created by the deployer;
  user-owned or pre-existing zones are retained.
