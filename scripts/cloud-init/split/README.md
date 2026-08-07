# Split deployment sources

`dirextalk-message-server/deploy/split-agent` is the canonical source for the
split Compose topology and all message/Agent initialization helpers. This
directory owns only the first-fresh production consumer. It uses the canonical
`edge-terminated` mode and runs runner preparation, provision, and start from
the same root-owned staged bundle path.

During development, run `scripts/render/render-split-bundle.sh` from a checkout next to
`dirextalk-message-server`, or set `DIREXTALK_MESSAGE_SERVER_ROOT` to that
repository. S3 transfers the resulting complete runtime bundle after SSH host
identity is fixed; it is never embedded in size-limited user-data. A packaged
Deployer release must carry the same generated bundle plus its
`SOURCE_REVISION` rather than requiring a sibling checkout on the operator or
target host.

The target host never clones source. `bootstrap-production.sh` consumes the
staged bundle, requires immutable message-server, Agent, Caddy, and coturn digests,
binds TURN's external address to the updater-recorded stable public IPv4,
prepares the two systemd-delegated runner cgroups, provisions the two databases
and Qdrant in production mode, starts the application stack, and then starts
the separate canonical Caddy edge project.

`release.env` is the only production release selection. It binds the
message-server and Agent versions to immutable image digests and full source
revisions, fixes the single Message Server-owned release catalog origin at
`https://imadmin.dirextalk.ai`, pins the independent Caddy and Alpine coturn images, and records a separate split
deployment revision so deployment-only fixes do not misstate image provenance.
Existing node state without `split_release.release_catalog_origin` is obsolete
and fails closed. This release does not seed, migrate, or infer that field;
redeploy the node through the fresh-state path.
`reconcile-production.sh` and
`reset-production.sh` consume the protected split and edge receipts; they do
not fall back to a root-level or standard Compose project.
