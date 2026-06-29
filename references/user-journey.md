# Operator Journey

This document is the operator-facing reference for the deployment journey described in the root `SKILL.md`.

The important policy is simple:

> Direxio deployments require a real, long-lived domain before infrastructure is created.

## Before Running Ops

Confirm these items before calling `scripts/orchestrate.sh`:

1. The final Matrix domain is selected, for example `__DOMAIN__`.
2. The user understands that Matrix `server_name` is bound to that domain.
3. The user has confirmed `CONFIRM_DOMAIN_BINDING=1`.
4. AWS CLI v2, `jq`, `ssh`, `scp`, and `curl` are available.
5. AWS credentials are configured through `AWS_PROFILE` or environment variables.
6. `AWS_DEFAULT_REGION` is explicit.
7. `MESSAGE_SERVER_IMAGE` is selected, or the default `direxio/message-server:latest` is accepted.
8. Existing state handling is explicit: continue, destroy, or new workdir.

On Windows, first verify that `bash` is a usable POSIX shell:

```powershell
Get-Command bash.exe -All
bash -lc 'echo ok; command -v aws; command -v jq; command -v ssh; command -v scp; command -v curl'
```

## Domain Modes

| Mode | Meaning | DNS behavior |
|---|---|---|
| `route53` | User authorizes AWS Route53 automation | S3 reuses or creates the hosted zone, records NS, upserts the A record, and waits for DNS to resolve |
| `user` | Fallback when no DNS provider automation is available | S3 emits the EIP and waits until the domain A record resolves to it |

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

## Token Initialization

S5 reads `/opt/p2p/bootstrap.json` from the instance. Current message-server builds initialize on startup and write the backend `password` field plus owner, Matrix, and agent tokens. User-facing delivery should call `password` the eight-digit app initialization code.

## Delivery

When all phases complete, report:

- App domain
- eight-digit app initialization code, sourced from the backend `password` field
- `access_token`, `agent_token`, and real `agent_room_id` in local credentials
- local node credential file status
- persisted `DIREXIO_DOMAIN`, `DIREXIO_AGENT_TOKEN`, `DIREXIO_AGENT_ROOM_ID`, `DIREXIO_AGENT_NODE_ID`
- `cc_connect_config`, `cc_connect_matrix_user`, `cc_connect_matrix_device`, and `cc_connect_matrix_homeserver`
- install policy/mode/status from `DIREXIO_AGENT_INSTALL` and `DIREXIO_AGENT_INSTALL_MODE`
- manual command: `npm install -g @direxio/connent@1.3.10 && direxio-connect daemon install --config <cc_connect_config> --service-name <service_id> --force`
- region, instance ID, public IP, and `state.json` path
- SSH command
- stop-billing guidance: ask the agent to destroy this node when finished
- which gates are automated and which still need user confirmation, because S7 green is not the final product-complete state

After delivery, verify the local bridge by checking `direxio-connect daemon status --service-name <service_id>` when installed, or by running the recorded `agent_install_command` if the policy was `recommend`.

Destroying AWS resources removes deployer-created Route53 A records and
attempts to delete hosted zones that state marks as deployer-created. It does
not remove registered domains, third-party DNS records, or user-owned hosted
zones.
