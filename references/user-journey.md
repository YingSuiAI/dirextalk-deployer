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
7. Legacy/no-Agent deployment can pull `dirextalk/message-server:latest`. An
   Agent-enabled production deployment has the exact public stable
   `DIREXTALK_MESSAGE_SERVER_RELEASE_IMAGE` digest, and EC2 has the immutable
   same-account/same-region private ECR `dirextalk-agent` digest plus an
   eligible root/IAM-user caller or explicit same-account pull role.
8. Existing state handling is explicit: continue, destroy, or new workdir.

On native Windows, first open Git Bash and verify Git before a lifecycle
action. Native WSL follows the Linux path and runs Bash directly:

```bash
case "$(uname -s)" in
  MINGW*) git_root=$(git --exec-path 2>/dev/null | sed 's#/mingw64/libexec/git-core$##'); command -v git >/dev/null && command -v cygpath >/dev/null && git --version | grep -q '\.windows\.' && [ -n "$git_root" ] && [ "$(cygpath -m "${EXEPATH:-}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s/bin' "$git_root" | tr '[:upper:]' '[:lower:]')" ] ;;
  Linux*|Darwin*) true ;;
  *) false ;;
esac
command -v node aws ssh curl
```

If the Git Bash preflight fails, install Git for Windows from
<https://git-scm.com/download/win>, reopen Git Bash, and stop. Do not use
PowerShell as the native Windows lifecycle shell, and do not switch the same
service state between Git Bash and WSL.

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
- deployment completion status after S7 and automated runtime/MCP verification pass

Final delivery verifies the local bridge automatically. For diagnostics, check `dirextalk-connect daemon status --service-name <service_id>` and `dirextalk-connect daemon logs --service-name <service_id> -n 120` when installed, or run the recorded `connect_install_command` if the policy was `recommend`. In the default `auto` mode, S6 waits for `dirextalk-connect is running` and fails on local Agent startup errors before reporting deployment completion.

Destroying AWS resources removes deployer-created Route53 A records and
attempts to delete hosted zones that state marks as deployer-created. It does
not remove registered domains, third-party DNS records, or user-owned hosted
zones.
