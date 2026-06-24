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

## What To Report At Handoff

Always report:

- IM URL.
- Portal token or where it was written.
- `~/.direxio/nodes/<service_id>/credentials.json` status and profile shape.
- AWS region, EC2 instance ID, public IP, security group, state path, SSH command.
- Destroy command and billing reminder.
- Any manual DNS record the user owns outside Route53.
