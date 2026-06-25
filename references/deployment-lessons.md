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

Never prefer root access keys for deployment. If a root key was used to unblock a
deployment, delete or disable it after the deployment succeeds and replace it
with a dedicated IAM user/role based on `references/iam-policy.json`.

Do not store AWS AK/SK in skill files, docs, or committed repo files. Treat
`state.json`, `outputs.json`, and `~/.direxio/nodes/<service_id>/credentials.json` as local
secrets because they contain the portal/agent token after S5.

## Route53 Delegation From Third-Party Registrar

Symptom:

- User chose `DOMAIN_MODE=route53` but the domain is registered at Alibaba Cloud / GoDaddy / Cloudflare (not AWS Route53 registrar).
- `_find_route53_zone()` returns empty → S3 fails with "Route53 hosted zone not found".
- The script does NOT create the hosted zone — it only looks up existing ones.

Cause:

The `_find_route53_zone()` function in `scripts/phases/s3_provision.sh` calls
`aws route53 list-hosted-zones` and searches for a matching name. It never
calls `create-hosted-zone`. When the domain administrator is a third party, no
zone exists yet.

Fix procedure (must happen BEFORE `scripts/orchestrate.sh`):

1. Create the Route53 hosted zone:
   ```bash
   aws route53 create-hosted-zone --name <DOMAIN> \
     --caller-reference "direxio-deploy-$(date -u +%Y%m%d%H%M%S)"
   ```
2. Extract the 4 NS servers from the response.
3. Ask the user to update their domain's NS records at their current registrar
   (e.g. Alibaba Cloud DNS console → "修改DNS" → paste the 4 NS nameservers).
4. Wait for the user to confirm they made the change.
5. **Only then** run `scripts/orchestrate.sh` with `DOMAIN_MODE=route53`.

Do NOT run orchestrate.sh before the NS records are submitted. The Route53
hosted zone must exist before S3_PROVISION, or S3 fails immediately.

DNS propagation of new NS records can take minutes to hours. After the user
confirms the change, verify with `nslookup -type=NS <DOMAIN>` or
`dig NS <DOMAIN> +short`. The S3 phase's `_require_user_dns_ready()` will
handle the A-record wait loop.

Always report:

- IM URL.
- Portal token or where it was written.
- `~/.direxio/nodes/<service_id>/credentials.json` status and profile shape.
- AWS region, EC2 instance ID, public IP, security group, state path, SSH command.
- Destroy command and billing reminder.
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

- Use a separate subdomain per deployment cycle (e.g. `test1.example.com`, `test2.example.com`) when doing repeated test deployments within 7 days.
- Preserve the old `caddy-data` Docker volume on redeploy to carry forward the existing certificate.

## Route53 Duplicate Zone Detection

Symptom: A new hosted zone was created via `aws route53 create-hosted-zone` for a domain that already had a Route53 zone from a prior deployment. The NS records of the new zone do not match the NS records configured at the registrar, so DNS resolution still uses the old zone's servers.

Fix:

1. List all existing zones first: `aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]'`
2. Check which zone's NS servers match DNS: `nslookup -type=NS <domain>`
3. If the domain is already delegated to Route53, use the matching existing zone.
4. Delete the duplicate: `aws route53 delete-hosted-zone --id /hostedzone/<DUPLICATE_ID>`

Prevention:

- Before deployment, check for existing zones. If one exists and its NS records match current DNS delegation, no new zone is needed — `_find_route53_zone()` in S3 will find it.
- Only create a new hosted zone when deploying to a domain with no existing Route53 zone or when migrating DNS delegation for the first time.
