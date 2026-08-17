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

`release.env` is the only production release selection. Release preparation
discovers `latest` once, verifies the corresponding stable version tags, and
records those image/version/revision identities. It also fixes the single Message Server-owned release catalog origin at
`https://imadmin.dirextalk.ai`, pins the independent Caddy and Alpine coturn images, and records a separate split
deployer-owned runtime tree revision so deployment-only fixes do not misstate
either application image's provenance.
Existing node state without `split_release.release_catalog_origin` is obsolete
and fails closed. This release does not seed, migrate, or infer that field;
redeploy the node through the fresh-state path.
`reconcile-production.sh` and
`reset-production.sh` consume the protected split and edge receipts; they do
not fall back to a root-level or standard Compose project.
