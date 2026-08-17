# Split deployment sources

`scripts/cloud-init/split/runtime` is the deployer-owned canonical source for
the split Compose topology, host lifecycle adapters, and message/Agent
initialization helpers. It uses the canonical
`edge-terminated` mode and runs runner preparation, provision, and start from
the same root-owned staged bundle path.

Release preparation renders the runtime from this repository and records its
Git tree revision in `SOURCE_REVISION`. S3 transfers the resulting complete
runtime bundle after SSH host identity is fixed; it is never embedded in
size-limited user-data. A packaged Deployer release carries the generated
bundle and never requires a Message Server or Agent source checkout on the
operator or target host.

The target host never clones source. `bootstrap-production.sh` consumes the
staged bundle and prepared message-server and Agent `vX.Y.Z` release tags,
checks their version/revision labels and real binary versions, and keeps
PostgreSQL/pgvector, Caddy, and coturn fixed,
binds TURN's external address to the updater-recorded stable public IPv4,
prepares the two systemd-delegated runner cgroups, provisions one PostgreSQL
container and volume with distinct Message Server and Agent roles/databases,
starts the application stack, and then starts
the separate canonical Caddy edge project. The edge exposes no Agent host port:
same-origin `/agent/v1/*` requests are routed over the shared application
network to the healthy `agent:8082` service, with SSE proxy buffering disabled.
The Compose contract starts and verifies Message Server before it explicitly
starts Agent initialization, migration, both runners, and Agent. An Agent-only
failure preserves the healthy messaging service, starts Edge, exports bootstrap
credentials, and returns status `3` for receipt-bound Agent recovery.

`release.env` contains only Deployer-owned production inputs: the release
catalog origin, canonical split runtime revision, and fixed PostgreSQL/pgvector,
Caddy, and coturn digests. It does not pin Message Server or Agent releases.
For each fresh deployment, S3 resolves both Docker Hub `latest` tags, validates
their stable `vX.Y.Z` tag, source revision, and linux/amd64 manifest digest, and
atomically records the complete application snapshot before infrastructure
creation. Fresh retry/resume reuses that snapshot without another registry
read; existing nodes retain their recorded application versions.
Existing node state without `split_release.release_catalog_origin` is obsolete
and fails closed. This release does not seed, migrate, or infer that field;
redeploy the node through the fresh-state path.
`reconcile-production.sh` and
`reset-production.sh` consume the protected split and edge receipts; they do
not fall back to a root-level or standard Compose project.
