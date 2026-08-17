# Production split runtime

This directory is the deployer-owned source for the production Message Server,
Agent, PostgreSQL, runner, TURN, and edge topology. Application repositories
publish their own formal image tags; this runtime deploys and updates those
immutable version references.

`compose.yaml` defines the application topology,
`compose.production.yaml` fixes production resources and restart behavior, and
`edge-compose.yaml` owns the canonical Caddy edge project.

The host lifecycle is intentionally small:

- `provision-local.sh` renders a fresh root-owned production receipt and
  protected environment. It requires the verified deployment host region and
  writes the same value exactly once to the Cloud Worker config and its
  protected receipt. Despite the retained installed filename, it accepts only
  `DIREXTALK_SPLIT_COMPOSE_MODE=production`.
- `start-local.sh` establishes Message Server health first, then starts the
  explicit Agent init/migrate/runner path. `cleanup-local.sh` and
  `cleanup-provision-failure.sh` clean only receipt-bound resources.
- `update-message-server-local.sh` and `update-agent-local.sh` apply exact
  `vX.Y.Z` targets and restore the receipt-bound original image after failure.
  Agent update success, interrupted recovery, and rollback preserve and
  repeatedly revalidate the exact Message Server container; they never resolve
  a replacement by Compose name or recreate it. Before an Agent update starts
  or recreates the three long-running Agent services, it refreshes protected
  config material, migrates, stops the exact receipt-bound trio, and reruns
  runner cgroup preparation. A digest-bound config transaction restores and
  rematerializes the exact previous YAML with the old image on rollback or an
  interrupted retry.
- `stop-agent-local.sh` and `restart-agent-local.sh` provide the updater's
  fixed Agent recovery boundary. `prepare-agent-start-local.sh` provides the
  stop-and-prepare half for update flows; restart repairs and revalidates
  delegated cgroup ownership before starting extension runner, Core runner,
  and Agent. If a restart of an originally healthy trio fails during cgroup
  preparation or startup, it re-prepares and restores that exact trio.
- The remaining helpers materialize protected configuration, prepare runner
  isolation and the small Ubuntu host dependency set, verify formal images,
  and export the portal bootstrap receipt.

The deployer renders these files into `canonical-bundle.tar.gz` under the
installed path `deploy/split-agent`. `SOURCE_REVISION` is the Git tree identity
of this directory and `SOURCE_FILES.sha256` binds every bundled file. Target
hosts never clone Message Server, Agent, updater, or deployer source.

Operational tests live in `tests/split-runtime`; they are not packaged into the
server runtime bundle.
