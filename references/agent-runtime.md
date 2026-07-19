# Optional Single-Tenant Agent Runtime

The Message Server remains the only public façade. Flutter continues to call
only the Message Server. The optional Agent runs on the private Docker network
and is disabled unless all three non-secret deployment inputs are present
before S3 provisions an instance:

```bash
DIREXTALK_MESSAGE_SERVER_RELEASE_IMAGE='dirextalk/message-server:v1.2.3@sha256:<64-lowercase-hex>' \
AGENT_IMAGE='<aws-account>.dkr.ecr.<aws-region>.amazonaws.com/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:<64-lowercase-hex>' \
AGENT_INSTANCE_ID='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
AGENT_MODEL_PROFILES_FILE='/absolute/path/model-profiles.json' \
bash scripts/orchestrate.sh
```

`AGENT_IMAGE` must have both a prerelease (`alpha`, `beta`, or `rc`) tag and a
lowercase `sha256` digest. `latest`, stable tags, tag-only references, malformed
references, and a changed image/identity/catalog after infrastructure creation
are rejected. The catalog is copied into the private runtime volume, hash-bound
in local state, and must be Agent's strict secret-free model-profile JSON. It
may name a credential only as `"secret_ref":"mounted:<ref>"`; raw `api_key`,
token, password, authorization/credential fields, common token-shaped values,
and private-key PEM content are rejected before the catalog enters cloud-init.
Do not put provider tokens, database passwords, TLS private keys, or registry
credentials in that catalog, `.env`, user-data, command arguments, or state.
An Agent-enabled deployment also requires that canonical public stable Message
Server reference. `latest`, the separate `MESSAGE_SERVER_IMAGE` debug override,
a digestless stable tag, and a noncanonical repository are rejected.

### Explicit Agent AWS-control opt-in

AWS control is EC2-only and advances through two explicit phases. Phase 1 is
the only supported initial deployment shape. Supply the normal immutable Agent
inputs above plus the exact AWS-control core, but keep managed preparation
false and do not provide a Worker-AMI publication:

```bash
DIREXTALK_CLOUD_PROVIDER=ec2 \
DOMAIN='service.example.test' \
DIREXTALK_MESSAGE_SERVER_RELEASE_IMAGE='dirextalk/message-server:v1.2.3@sha256:<64-lowercase-hex>' \
AGENT_IMAGE='<aws-account>.dkr.ecr.<aws-region>.amazonaws.com/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:<64-lowercase-hex>' \
AGENT_INSTANCE_ID='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
AGENT_MODEL_PROFILES_FILE='/absolute/path/model-profiles.json' \
AGENT_ENABLE_AWS_CONTROL=true \
AGENT_AWS_REAPER_IMAGE_URI='<registry>/<repository>:<immutable-tag>@sha256:<64-lowercase-hex>' \
AGENT_WORKER_CONTROL_ENDPOINT='grpcs://worker-control.__DOMAIN__:443' \
AGENT_ENABLE_MANAGED_PREPARATION_AWS=false \
bash scripts/orchestrate.sh
```

This phase renders the reaper image and credential-free Worker endpoint, with
`AGENT_ENABLE_MANAGED_PREPARATION_AWS=false`. It neither publishes nor mounts a
Worker-AMI record. The resulting Agent can complete Foundation/device approval
and build the Worker AMI while the original Agent release, instance identity,
model-profile catalog, reaper digest, and Worker endpoint remain frozen.

After the Agent has produced one reviewed publication, explicitly advance the
same EC2 deployment with the exact original runtime inputs:

```bash
DOMAIN='service.example.test' \
DIREXTALK_MESSAGE_SERVER_RELEASE_IMAGE='dirextalk/message-server:v1.2.3@sha256:<same-digest>' \
AGENT_IMAGE='<same-private-ecr-reference>@sha256:<same-digest>' \
AGENT_INSTANCE_ID='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' \
AGENT_MODEL_PROFILES_FILE='/absolute/path/same-model-profiles.json' \
AGENT_ENABLE_AWS_CONTROL=true \
AGENT_AWS_REAPER_IMAGE_URI='<same-reaper-reference>@sha256:<same-digest>' \
AGENT_WORKER_CONTROL_ENDPOINT='grpcs://worker-control.__DOMAIN__:443' \
AGENT_ENABLE_MANAGED_PREPARATION_AWS=true \
AGENT_WORKER_AMI_PUBLICATION_FILE='/absolute/path/worker-ami-publication.json' \
bash scripts/orchestrate.sh agent-aws-import
```

`AGENT_ENABLE_MANAGED_PREPARATION_AWS` must be exactly `true` or `false`. The
worker-control endpoint must be a credential-free TLS gRPC DNS target on port
443, with no user info or query. The reaper image must be digest-pinned. The
publication source must be one non-empty regular non-symlink file of at most
1 MiB containing exactly the Agent
`dirextalk.agent.worker-ami-publication/v1` object: the fixed top-level,
`image_manifest`, and `attestation` field allowlists; valid canonical
identifiers, digests, architecture, and timestamps; and matching identity and
artifact fields across manifest and attestation. Unknown fields—including
`aws_access_key_id`, `aws_secret_access_key`, and `aws_session_token`—arbitrary
JSON, duplicate object keys at any nesting level, malformed/trailing content,
symlinks, and cross-field mismatches are rejected. The Agent runtime remains
the final verifier of the publication's canonical cryptographic
`image_digest`; the deployer does not invent a second CBOR implementation.

Before SSH or any other remote side effect, `agent-aws-import` validates the
existing EC2/private-ECR state and every immutable core input, then freezes the
exact publication bytes through a private same-directory temporary file, file
and directory durability flushes, and an atomic no-clobber mode-0600 snapshot.
It durably records a `prepared` import with the publication and both rendered
Compose digests. State contains only public configuration, local snapshot
paths, digests, and transition status—not publication contents or credentials.

The command holds one private per-service local lock, while the pinned-SSH
helper holds a host `flock` across its complete inspect/mutate/readback or
rollback transaction. It installs the exact publication read-only at
`/run/dirextalk-agent/worker-ami-publication.json`, atomically changes Compose
to managed preparation, and reconciles only the Agent container with
`--no-deps`. Before local state advances from false to true, runtime readback
must prove the exact Agent image and instance, AWS core environment, exact
publication bind source and digest, and the mounted model-profile digest.
If the restart fails, the host restores the usable phase-1 Compose and removes
the attempted publication; rerunning the command is safe. If the response is
lost after success, the retry reads back the exact running target and records
success without replaying the mutation. Local prepared/applied journal writes
flush both the state file and its directory, and exact retries never downgrade
an applied journal. Once applied, the transition cannot be disabled, reverted,
or moved to different publication bytes or core wiring. Every retry requires
the source and frozen snapshot to remain regular, present, valid, and
byte-identical.

AWS control remains rejected for Lightsail. The legacy Agent-disabled path is
unchanged, and a normal deployment resume cannot bypass the explicit
`agent-aws-import` transition.

### One-time mounted provider secret (verified pinned SSH)

An actual provider-model acceptance can opt in to one external local source
file without weakening that boundary:

```bash
AGENT_MOUNTED_SECRET_NAME='deepseek-token' \
AGENT_MOUNTED_SECRET_FILE='/secure/local/path/deepseek-token' \
bash scripts/orchestrate.sh
```

Both variables are required together. The name must already appear as exactly
`"secret_ref":"mounted:deepseek-token"` in the reviewed catalog. The source
must be a regular non-symlink file outside the deployer repository and service
work directory, containing one non-empty single-line token of at most 16 KiB.
Its path and contents are never written to state, user-data, command arguments,
or reports. After the Lightsail or EC2 host's nonce-verified key is pinned and the
normal updater reconciliation succeeds, the deployer streams the file only on
SSH stdin into `agent-runtime`'s private `mounted-secrets` directory with
atomic `65532:65532`/`0400` ownership. The Agent reads it on each provider
request; no public port, container environment variable, or restart is needed.

This narrow transport deliberately rejects unpinned hosts. On destroy,
the deployer best-effort clears the private regular files through the same
pinned host key before deleting the instance; instance deletion remains the
final volume wipe. Keep the local source file under operator control and remove
it after testing. Never reuse a provider key that was pasted into chat; rotate
it first and mount the replacement through this file.

## Cloud Runtime Boundary

S3 renders these services only when the inputs above pass preflight:

- `agent-db-init` creates the separate `dirextalk_agent` PostgreSQL role and
  `dirextalk_agent` database in the existing PostgreSQL server. It never shares
  the Message Server role, database, schema, migration ledger, or DSN.
- `agent-runtime-init` creates the private Agent TLS material, service-key
  pepper, master key, and Message Server `DTX-Service-Key` in the named
  `agent-runtime` volume. Secret values are generated inside that private init
  container; they are not sent in arguments or logs. The serving Agent,
  migration, and bootstrap containers run as UID/GID `65532`.
  For this fixed single-tenant private Compose path, the Agent's self-signed
  `agent` SAN certificate is also copied verbatim to `agent-ca.crt`. That
  filename is the Message Server adapter's trust-anchor interface, not a
  signing CA: it pins the exact Agent leaf. A prior experimental pseudo-CA
  layout is rejected on resume because strict TLS clients reject its chain;
  recreate that Agent runtime volume before enabling this runtime.
- `agent-migrate` and `agent-bootstrap` run before `agent`. The bootstrap key
  is bound to the Message Server remote adapter's stable client ID
  `dirextalk-project:<lowercase-domain>` and receives only the scopes required
  by the current remote contract, including `runtime.read`, `runtime.write`,
  and `runtime.chat` for the owner-only runtime-profile façade and remote Chat,
  plus `knowledge.read`, `knowledge.write`, and `knowledge.search` for the
  owner-only Knowledge façade; it is not an `admin` credential.
- `agent` has no `ports` entry, no Docker socket, a read-only root filesystem,
  and dropped Linux capabilities. `AGENT_ENABLE_AWS_CONTROL=false` is the
  default and remains the disabled behavior; the separate explicit opt-in is
  defined in [Explicit Agent AWS-control opt-in](#explicit-agent-aws-control-opt-in).
  Its image health check performs TLS 1.3 gRPC health only against its own
  loopback listener with the `agent` SAN.

When enabled, the renderer writes the full Message Server remote tuple in one
Compose block: `P2P_AGENT_GRPC_ENABLED=true`, target `dns:///agent:9443`, CA
file, server name `agent`, mounted service-key file, and the exact Agent
instance ID. The Message Server waits for Agent health before it starts. The
current Message Server contract is TLS 1.3 server-identity verification plus a
protected mounted `DTX-Service-Key`; it does **not** define client-certificate
mTLS. Do not invent an inline service key or an unsupported mTLS bypass.

S5 then invokes `cloud.deployments.list` through the authenticated Message
Server P2P API on the host. It succeeds only when the enabled remote Agent
runner actually completes its gRPC call; a healthy Agent container alone is not
acceptance evidence, and a broken remote tuple cannot fall back to the local
runner.

## Published images and private ECR preconditions

The local `dirextalk-agent-local:*` Docker build is not deployable input. The
minimum release closure before a real acceptance is:

1. Publish the reviewed linux/amd64 Agent artifact to a registry and record the
   immutable `repository:prerelease-tag@sha256:digest` reference.
2. Publish the compatible Message Server as the canonical public stable
   `dirextalk/message-server:vX.Y.Z@sha256:<digest>` reference.
3. For EC2, publish Agent to the fixed private `dirextalk-agent` ECR repository
   in the exact deployment account and region.
4. Supply only the digest-pinned reference to `AGENT_IMAGE`; do not substitute a
   tag or publish a gRPC host port.

For a local Compose contract test, supply a Message Server image built from the
target source revision and verify that revision before treating
`cloud.deployments.list` as evidence. A pre-existing `:dev` or `:latest` image
tag is not evidence by itself. This is a local test-image prerequisite; it does
not change the deployment image policy.

EC2 launch user-data contains only a 64-hex identity nonce. After the Elastic IP
is attached, S3 reads the same nonce over first-contact SSH, pins that host key,
and streams the already-frozen bootstrap only through strict SSH. For a root or
IAM-user caller it obtains a one-hour STS federation session whose inline policy
allows `ecr:GetAuthorizationToken` on `*` and only
`BatchCheckLayerAvailability`, `BatchGetImage`, and
`GetDownloadUrlForLayer` on the exact repository ARN. An assumed-role caller
fails closed unless `DIREXTALK_ECR_PULL_ROLE_ARN` names an explicit same-account
role; that role selection is frozen.

Temporary STS credentials exist only in a private local temp file. Only the ECR
Docker password is streamed on SSH stdin into the fixed root-only
`/run/dirextalk-ecr-auth` config. Success, failure, and lost-response resume all
log out, remove that directory, and read back its absence; each retry obtains
fresh auth. No AWS credential or ECR password enters user-data, `.env`, Compose,
state, arguments, logs, or reports. `update.sh` and `reset-app-data.sh` currently
fail closed for this private-registry state because they do not yet implement
the same refresh boundary; resume the reviewed deployment workflow instead.

## Local Approval Cards

S6 writes `approval_owner_id = "@owner:<domain>"` under
`[projects.platforms.options]` from the same exact `admin_from` owner. This is
the fail-closed Matrix sender binding for non-YOLO approval-card responses.
The backward-compatible generated default remains `mode = "yolo"`; a z3
acceptance that needs real approval cards must explicitly set:

```bash
export DIREXTALK_CONNECT_AGENT_OPTIONS_TOML='mode = "default"'
```

Use another reviewed non-YOLO mode only when its approval semantics are known.
