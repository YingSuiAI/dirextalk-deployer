# Optional Single-Tenant Agent Runtime

The Message Server remains the only public façade. Flutter continues to call
only the Message Server. The optional Agent runs on the private Docker network
and is disabled unless all three non-secret deployment inputs are present
before S3 provisions an instance:

```bash
AGENT_IMAGE='registry.example/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:<64-lowercase-hex>' \
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

### One-time mounted provider secret (verified Lightsail only)

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
or reports. After the Lightsail host's nonce-verified key is pinned and the
normal updater reconciliation succeeds, the deployer streams the file only on
SSH stdin into `agent-runtime`'s private `mounted-secrets` directory with
atomic `65532:65532`/`0400` ownership. The Agent reads it on each provider
request; no public port, container environment variable, or restart is needed.

This narrow transport deliberately rejects EC2 and unpinned hosts. On destroy,
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
  and `runtime.chat` for the owner-only runtime-profile façade and remote Chat;
  it is not an `admin` credential.
- `agent` has no `ports` entry, no Docker socket, a read-only root filesystem,
  dropped Linux capabilities, and `AGENT_ENABLE_AWS_CONTROL=false`. Its image
  health check performs TLS 1.3 gRPC health only against its own loopback
  listener with the `agent` SAN.

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

## Published Image and z3 Lightsail Preconditions

The local `dirextalk-agent-local:*` Docker build is not deployable input. The
minimum release closure before a real z3 Lightsail acceptance is:

1. Publish the reviewed linux/amd64 Agent artifact to a registry and record the
   immutable `repository:prerelease-tag@sha256:digest` reference.
2. Make that exact digest pullable by a freshly created Lightsail host **before
   the authenticated SSH bootstrap starts Compose**.
3. Supply only the digest-pinned reference to `AGENT_IMAGE`; do not substitute a
   tag or publish a gRPC host port.

For a local Compose contract test, supply a Message Server image built from the
target source revision and verify that revision before treating
`cloud.deployments.list` as evidence. A pre-existing `:dev` or `:latest` image
tag is not evidence by itself. This is a local test-image prerequisite; it does
not change the deployment image policy.

The current EC2 cloud-init and Lightsail SSH-bootstrap paths deliberately do not write `docker login` data,
ECR passwords, AWS credentials, or registry tokens to user-data, `.env`, or
state. Therefore the supported fresh-z3 path is an anonymously pullable
registry digest. A private ECR reference is not sufficient by itself: without a
separately reviewed preboot credential-delivery design, `docker compose pull`
fails closed before the Agent starts. Do not work around that failure by putting
an ECR password in deployment inputs. A later private-registry feature must
establish credential delivery and expiry separately, then retain this same
digest validation and no-public-gRPC boundary.

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
