# Deployment Workflow

## Preflight

1. Confirm `DOMAIN`, `DOMAIN_MODE`, and `CONFIRM_DOMAIN_BINDING=1`.
2. Confirm AWS region, credentials, billing, instance type, and costs.
3. Check dependencies with the OS-specific commands in `tooling.md`.
4. Check current DNS provider. Use `DOMAIN_MODE=user` unless Route53 hosts the zone and the user confirms Route53 changes.
5. Check state:

```bash
bash scripts/orchestrate.sh status
```

If state has resources, require one:

```bash
P2P_EXISTING_STATE_ACTION=continue
P2P_EXISTING_STATE_ACTION=destroy
P2P_WORKDIR=$HOME/.direxio/deploy-new
```

## Destroy

From the repository root:

```bash
bash scripts/destroy.sh
```

Destroy terminates the recorded EC2 instance, releases the Elastic IP, deletes the security group and key pair, then removes the corresponding local deploy workdir under `~/.direxio`. This prevents stale `state.json` files from being treated as active deployments later.

Use `P2P_KEEP_WORKDIR=1 bash scripts/destroy.sh` only when preserving local state files for debugging; if used, report that the workdir still exists.

## Run

From the repository root:

```bash
AWS_PROFILE=p2p-matrix \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=im.example.com \
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

## Manual DNS Mode

|...

When S3 emits an Elastic IP, ask the user to set:

```text
<DOMAIN>  A  <PUBLIC_IP>
```

For Cloudflare, use DNS-only, not proxied. For Alibaba/HiChina, edit the A record in Alibaba Cloud DNS.

After authoritative DNS returns the new IP:

```bash
DNS_READY=1 \
AWS_PROFILE=p2p-matrix \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=im.example.com \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
P2P_EXISTING_STATE_ACTION=continue \
bash scripts/orchestrate.sh
```

## Password Field

Current backend delivery uses `password` for the client login password, a unified user `access_token`, and an agent-only `agent_token`.

State fields after S5:

```text
password
agent_token
access_token
as_url
```

All fields are written to `~/.direxio/nodes/<service_id>/credentials.json` with mode `0600`.
