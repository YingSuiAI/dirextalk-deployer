# Operator Journey

This document is the operator-facing reference for the deployment journey
described in the root `SKILL.md`.

The important policy is simple:

> P2P-IM deployments require a real, long-lived domain before infrastructure is
> created. Temporary `sslip.io` domains are not part of the production path.

## Before Running Ops

Confirm these items before calling `scripts/orchestrate.sh`:

1. The final Matrix domain is selected, for example `__DOMAIN__`.
2. The user understands that Matrix `server_name` is bound to that domain.
3. The user has confirmed `CONFIRM_DOMAIN_BINDING=1`.
4. AWS CLI v2, `jq`, `ssh`, `scp`, and `curl` are available.
5. AWS credentials are configured through `AWS_PROFILE` or environment
   variables.
6. `AWS_DEFAULT_REGION` is explicit.
7. `MESSAGE_SERVER_IMAGE` is selected, or the default `direxio/message-server:latest` is accepted.
8. Existing state handling is explicit: continue, destroy, or new workdir.

On Windows, first verify that `bash` is a usable POSIX shell, not just the WSL
launcher with no installed distro:

```powershell
Get-Command bash.exe -All
bash -lc 'echo ok; command -v aws; command -v jq; command -v ssh; command -v scp; command -v curl'
```

Do not assume a fixed Git Bash path. Git Bash, MSYS2, Cygwin, or WSL are all
acceptable when the command above succeeds. Prefer the `ssh` and `scp` from the
same environment as `bash`; Windows OpenSSH may reject generated `.pem` files
because of inherited ACLs. See `references/deployment-lessons.md` for details.

## Domain Modes

| Mode | Meaning | DNS behavior |
|---|---|---|
| `user` | User owns DNS outside ops automation | S3 emits the EIP and waits until the domain A record resolves to it |
| `route53` | Domain is hosted in Route53 | S3 upserts the A record and waits for DNS to resolve |

`ec2`/`sslip.io` is removed from the production interface. `buy` is disabled;
domain purchase must be done manually before deployment.

## Minimal Command

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

## AWS Credential Setup

Recommended local setup:

```bash
aws configure --profile p2p-matrix
export AWS_PROFILE=p2p-matrix
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity
```

Use `references/iam-policy.json` as the starting least-privilege policy. The
Route53 permissions are needed only when `DOMAIN_MODE=route53`.

## DNS Timing

For `DOMAIN_MODE=user`, S3 stops after allocating the EIP and prints the A record
the user must set:

```text
__DOMAIN__  A  <EC2 Elastic IP>
```

The script will not proceed to cloud-init bootstrap until DNS actually resolves
to that IP. This avoids Caddy/Let's Encrypt attempts before public DNS is ready.

For Cloudflare-hosted DNS, use DNS only mode for the IM record.

## Token Initialization

S5 reads `/opt/p2p/bootstrap.json` from the instance. Current message-server
builds initialize on startup and write password plus admin, Matrix, and agent
tokens. The ops engine no longer calls the bootstrap HTTP endpoint.

## Delivery

When all phases complete, report:

- IM URL
- `password`
- `access_token`, `agent_token`, and `agent_room_id` in local credentials
- local node credential file status
- persisted `DIREXIO_DOMAIN`, `DIREXIO_AGENT_TOKEN`, `DIREXIO_AGENT_ROOM_ID` status
- detected agent runtime plus `@direxio/local-mcp` and `@direxio/agent-plugins` installation targets
- agent install policy/mode/status from `DIREXIO_AGENT_INSTALL` and `DIREXIO_AGENT_INSTALL_MODE`
- native gateway send command: `npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "$DIREXIO_AGENT_ROOM_ID" --message "hello"`
- OpenClaw/Hermes generated passive gateway helper paths when those runtimes are detected
- region, instance ID, public IP, and `state.json` path
- SSH command
- destroy command

After reporting delivery, ask whether to automatically install/configure the Direxio plugin and MCP service for the detected runtime unless `DIREXIO_AGENT_INSTALL=auto` was already set. Only mutate the user's agent config after they agree or explicitly set auto install. OpenClaw and Hermes should use their generated native gateway helpers for passive replies; platforms without local long-process support use MCP-only or an external gateway.

Destroying AWS resources does not remove DNS records or registered domains.
