# Operator Journey

This document is the operator-facing reference for the deployment journey described in the root `SKILL.md`.

The important policy is simple:

> Dirextalk deployments require a real, long-lived domain before infrastructure is created.

## Before Running Ops

Confirm these items before calling `scripts/orchestrate.sh`:

1. The final Matrix domain is selected, for example `__DOMAIN__`.
2. The user understands that Matrix `server_name` is bound to that domain.
3. The user has confirmed `CONFIRM_DOMAIN_BINDING=1`.
4. Node.js, AWS CLI v2, `ssh`, and `curl` are available. Go is not required.
5. AWS credentials are configured through `AWS_PROFILE` or environment variables.
6. `AWS_DEFAULT_REGION` is explicit.
7. The latest stable GitHub Release is available with a matching manifest and checksum; normal production state is pinned to its immutable image digest.
8. Existing state handling is explicit: continue, destroy, or new workdir.

On Windows, first open Git Bash and verify Git before a lifecycle action:

```bash
git_root=$(git --exec-path 2>/dev/null | sed 's#/mingw64/libexec/git-core$##')
case "$(uname -s)" in
  MINGW*) command -v git >/dev/null && command -v cygpath >/dev/null && git --version | grep -q '\.windows\.' && [ -n "$git_root" ] && [ "$(cygpath -m "${EXEPATH:-}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s/bin' "$git_root" | tr '[:upper:]' '[:lower:]')" ] ;;
  *) false ;;
esac
command -v node aws ssh curl
```

If the Git Bash preflight fails, install Git for Windows from
<https://git-scm.com/download/win>, reopen Git Bash, and stop. Do not use
PowerShell or WSL for deployer lifecycle commands.

## Domain Modes

| Mode | Meaning | DNS behavior |
|---|---|---|
| `route53` | S2 found a matching public hosted zone in the current AWS account, or the operator explicitly selected it | S3 reuses the hosted zone, upserts the A record, and waits for DNS to resolve |
| `user` | Fallback when no DNS provider automation is available | S3 emits the fixed public IP and waits until the domain A record resolves to it |

## Minimal Command

```bash
AWS_PROFILE=dirextalk-deployer \
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
CONFIRM_DOMAIN_BINDING=1 \
DIREXTALK_CLOUD_PROVIDER=lightsail \
bash scripts/orchestrate.sh
```

Use `DIREXTALK_CLOUD_PROVIDER=ec2 INSTANCE_TYPE=t3.small` only when the operator explicitly chooses the retained EC2 path.

## Token Initialization

S5 reads `/var/dirextalk-message-server/p2p/bootstrap.json` from the instance. Current message-server builds initialize on startup and write the backend `password` field plus owner, Matrix, and agent tokens. User-facing delivery should call `password` the eight-digit app initialization code.

## Delivery

When all phases complete, report:

- App domain
- eight-digit app initialization code, sourced from the backend `password` field
- `access_token`, `agent_token`, and real `agent_room_id` in local credentials
- local node credential file status
- persisted `DIREXTALK_DOMAIN`, `DIREXTALK_AGENT_TOKEN`, `DIREXTALK_AGENT_ROOM_ID`, `DIREXTALK_AGENT_NODE_ID`
- `connect_config`, `connect_matrix_user`, `connect_matrix_device`, and `connect_matrix_homeserver`
- connect install policy/mode/status from `connect_install_*` state fields; `DIREXTALK_AGENT_INSTALL` and `DIREXTALK_AGENT_INSTALL_MODE` are the operator selectors
- manual command: `npm install --prefix ~/.dirextalk/nodes/<service_id>/dirextalk-connect dirextalk-connect@latest && ~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon install --config <connect_config> --service-name <service_id> --force`
- region, cloud provider, instance ID, public IP, and `state.json` path
- SSH command
- stop-billing guidance: ask the agent to destroy this node when finished
- which gates are automated and which still need user confirmation, because S7 green is not the final product-complete state

After delivery, verify the local bridge by checking `dirextalk-connect daemon status --service-name <service_id>` and `dirextalk-connect daemon logs --service-name <service_id> -n 120` when installed, or by running the recorded `connect_install_command` if the policy was `recommend`. In the default `auto` mode, S6 already waits for `dirextalk-connect is running` and fails on local Agent startup errors before reporting automated deployment gates.

Destroying AWS resources removes deployer-created Route53 A records and
attempts to delete hosted zones that state marks as deployer-created. It does
not remove registered domains, third-party DNS records, or user-owned hosted
zones.
