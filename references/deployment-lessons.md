# Deployment Lessons From im2.jkmf.top

This note captures operational lessons from the production deployment of
`im2.jkmf.top` on AWS from a Windows workstation. Keep it short and practical:
symptom, cause, and what the next operator or agent should do.

## AS Bootstrap Initialization

Symptom:

```text
S5_INIT_TOKENS failed: read bootstrap.json timed out
/opt/p2p/bootstrap.json was missing or incomplete
```

Cause:

Current `p2p-matrix-as` builds initialize on service startup and write
`/opt/p2p/bootstrap.json` with the login `password`, `agent_token`, and owner
metadata. Calling the old bootstrap HTTP endpoint or scraping logs is no longer
part of the deploy path.

Fix now in ops:

- Cloud-side `scripts/cloud-init/init-tokens.sh` waits for AS `/healthz` and
  the credentials file.
- `docker-compose.yml` bind-mounts host `/opt/p2p` into the AS container so the
  file is readable from the EC2 host.
- Local S5 reads the file with `ssh ... sudo cat /opt/p2p/bootstrap.json`,
  normalizes it into local `outputs.json`, and stores `password`/`agent_token`
  in state.

## Windows Runtime Pitfalls

Do not hard-code a Git Bash path. Different machines install Git/MSYS/Cygwin in
different locations, and WSL may or may not be configured.

Use a POSIX shell that actually runs the deployment scripts:

```powershell
Get-Command bash.exe -All
bash -lc 'echo ok; command -v aws; command -v jq; command -v ssh; command -v scp; command -v curl'
```

If `bash` prints the Windows Subsystem for Linux installation prompt or exits
before running `echo ok`, it is only the Windows WSL launcher and cannot run ops
until a WSL distro is installed. Use another POSIX shell such as Git Bash, MSYS2,
Cygwin, or a working WSL distro.

The orchestrator now prepends workspace-local `.tools/bin` when present. This
directory is an optional local tool cache that may be downloaded by the operator
or system; it is not assumed to come from the original repo or from the skill.
When `.tools/bin/jq.exe` exists, compatible Windows POSIX shells can discover it
without manual PATH surgery.

Prefer the `ssh`/`scp` that belongs to the same POSIX environment used for
`bash`. Windows OpenSSH can reject EC2 private keys because inherited ACLs make
the `.pem` look too open, even when Git/MSYS OpenSSH accepts it. If using Windows
OpenSSH directly, fix the key ACL instead of disabling SSH checks.

## DNS And State Handling

For `DOMAIN_MODE=user`, S3 intentionally stops after allocating the EIP and waits
until the real DNS A record points at that EIP. Continue only after public DNS
resolves correctly. This avoids Caddy and Let's Encrypt racing DNS propagation.

When rerunning after a resource was created, set:

```bash
P2P_EXISTING_STATE_ACTION=continue
```

This is deliberate. It prevents accidental duplicate EC2/EIP creation or unsafe
reuse of an old deployment state.

## Credential Safety

Never use root access keys for deployment. If the active AWS CLI identity is
root, stop before mutating AWS resources and replace it with a temporary
`DirexioDeployer` IAM user or a dedicated IAM role.

Do not store AWS AK/SK in skill files, docs, or committed repo files. Treat
`state.json`, `outputs.json`, and `~/.direxio/nodes/<service_id>/credentials.json` as local
secrets because they contain the portal/agent token after S5.

## Route53 Delegation From Third-Party Registrar

Symptom:

- User chose `DOMAIN_MODE=route53` but the domain is registered at Alibaba Cloud / GoDaddy / Cloudflare (not AWS Route53 registrar).
- S3 creates or reuses a Route53 hosted zone and upserts the A record, but public
  DNS still does not resolve to the new IP.

Cause:

S3 can create the Route53 hosted zone, but Route53 does not become
authoritative until the current registrar delegates the zone's NS records. When
the domain administrator is a third party, the user or a provider-specific DNS
connector must update NS delegation outside AWS.

Fix procedure:

1. Read the created or reused zone details from `state.json`:
   ```bash
   jq '.resources | {route53_zone_id, route53_zone_name, route53_name_servers}' ~/.direxio/nodes/<service_id>/state.json
   ```
2. Delegate those NS servers at the current registrar, or use the provider API
   if credentials are available.
3. Wait for authoritative NS and A-record propagation.
4. Re-run `scripts/orchestrate.sh` with `P2P_EXISTING_STATE_ACTION=continue`.

DNS propagation of new NS records can take minutes to hours. After the user
confirms the change, verify with `nslookup -type=NS <DOMAIN>` or
`dig NS <DOMAIN> +short`. The S3 phase's `_require_user_dns_ready()` will
handle the A-record wait loop.

Always report:

- App domain and eight-digit app initialization code, with the code sourced from the backend `password` field.
- Portal token or where it was written.
- `~/.direxio/nodes/<service_id>/credentials.json` status and profile shape.
- AWS region, EC2 instance ID, public IP, security group, state path, SSH command.
- Stop-billing guidance: ask the agent to destroy this node when finished; AWS resources keep billing until teardown completes.
- Any manual DNS record the user owns outside Route53.

## Let's Encrypt Certificate Rate Limits

Symptom:

- S4_BOOTSTRAP_STACK health check times out after 5-10 minutes.
- SSH reveals all containers are up and healthy (caddy, message-server, postgres, coturn).
- `docker logs p2p-caddy-1` shows repeated errors:

  ```
  HTTP 429 urn:ietf:params:acme:error:rateLimited - too many certificates (5)
  already issued for this exact set of identifiers in the last 168h0m0s,
  retry after ...
  ```

Cause: Let's Encrypt allows at most 5 certificates per domain per 168 hours (7 days). Redeploying the same domain repeatedly within a week exhausts this quota.

Workaround (use when the health check is the only blocker and the rate limit is temporary):

1. **Add `tls internal` to the Caddyfile** so Caddy uses its built-in CA (self-signed). The directive goes on the line after the site block opener.

2. Write the modified Caddyfile to the remote host. Use base64+SSH to avoid shell escaping issues:
   ```bash
   echo '<base64-encoded-caddyfile>' | base64 -d | sudo tee /opt/p2p/Caddyfile
   sudo docker compose -f /opt/p2p/docker-compose.yml restart caddy
   ```

3. Wait 5 seconds, then verify HTTPS works:
   ```bash
   curl -sk --resolve <domain>:443:<EIP> https://<domain>/healthz
   # Expected: {"status":"ok"}
   ```

4. Resume orchestrate.sh with:
   ```bash
   P2P_EXISTING_STATE_ACTION=continue bash scripts/orchestrate.sh
   ```

5. **After deployment completes**, restore the original Caddyfile (remove `tls internal`) and restart Caddy. Caddy will retry the production Let's Encrypt cert when the rate limit resets. The self-signed cert is a temporary bridge; HTTPS will show a browser warning until the production cert is obtained.

Prevention:

- Use a separate subdomain per deployment cycle (e.g. `__DOMAIN_A__`, `__DOMAIN_B__`) when doing repeated test deployments within 7 days.
- Preserve the old `caddy-data` Docker volume on redeploy to carry forward the existing certificate.

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
