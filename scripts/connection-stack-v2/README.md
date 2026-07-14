# Dirextalk Connection Stack V2 — durable registration, quote, and isolated Worker create

This directory implements the V2 signed-command and Flutter-device-approval
**durable fence**, plus one deliberately narrow cloud mutation:
`deployment.create` can launch one dedicated EC2 Worker from a Stack-pinned
AMI and a durable approved quote. It is not a generic cloud executor. It is
deliberately separate from `scripts/connection-stack` (V1), which must not be
extended in place because V1 approvals do not bind the Flutter device signature
scope required by the Cloud Orchestrator.

The SAM template may be deployed only as a Connection Stack control-plane
prerequisite. Its regional Broker API verifies a bounded signed command,
persists immutable receipts and one-time approvals in DynamoDB, and returns a
de-secretsed response. It can attest its own CloudFormation stack identity for
a pending Connection registration and issue a read-only on-demand quote. After
a separate, valid Flutter `ApprovalV1` proof, it can create exactly one quoted,
isolated Worker instance.

It has no generic AWS API, IAM/PassRole, SSH/key-pair, instance-profile,
user-data, secret-read, public-ingress, or public-IP capability. It does not
yet grant a Worker bootstrap/session, command execution, health/event channel,
or lifecycle mutation such as stop, start, observe, or destroy.

## Bootstrap boundary

V2 accepts a bootstrap identity only through `validateBootstrapIdentity`. It
accepts an STS `assumed-role` identity and rejects an AWS root identity and IAM
user identity. The intended caller is a short-lived, least-privilege bootstrap
role that can create/update only this Stack.

CloudFormation templates cannot reliably inspect the caller's STS identity.
Therefore the ProductCore/bootstrap service must validate STS identity **before**
issuing a V2 stack request and must never issue one for a root credential.
Manually deploying this template with root in the console is unsupported and
does not make that account eligible for a Dirextalk V2 connection.

No AWS access key, secret access key, session token, service secret, or private
key is a template parameter, output, Lambda environment variable, receipt, or
test fixture.

## Command and approval boundary

Only `dirextalk.aws.command/v2` is a valid Broker envelope. The closed action
set is:

- `approval.challenge.request`
- `connection.registration.verify`
- `quote.request`
- `artifact.put`
- `deployment.create`
- `deployment.observe`
- `deployment.destroy`

There is no generic AWS action, arbitrary API name, shell command, IAM action,
or raw EC2 specification in the protocol. `artifact.put` carries only a typed
content reference in this skeleton; it does not upload bytes.

Only `deployment.create` has a provider-side mutation in this stage. Its
payload is exact and contains no caller-selected instance type, disk size,
security group, key pair, instance profile, user data, Worker token, bootstrap
URL, or secret:

```text
schema
deployment_id
connection_generation
plan_hash + plan_revision
quote_id + quote_digest + candidate_id
resource_manifest_digest
worker_artifact = { kind: fixed_ami, ami_id }
network = { vpc_id, subnet_id, availability_zone }
```

The Stack requires the artifact, resource-manifest digest, and network object
to exactly equal its private registered Worker configuration. It derives the
instance type and gp3 volume size solely from the durable quote candidate.

## Stack-derived registration attestation

`connection.registration.verify` is a read-only, no-approval command that
binds a pending ProductCore bootstrap to the deployed Stack. Its canonical JSON
payload has exactly three fields:

```text
bootstrap_id
requested_region
stack_arn
```

The Broker never accepts account, endpoint, connection id, node key, or
generation values from this payload. It compares `requested_region` and
`stack_arn` with CloudFormation pseudo-parameter values injected into the
Lambda. It derives the direct API Gateway command URL from its own API Gateway
request context and configured Stack stage. A mismatched Region, Stack ARN,
stage, or endpoint fails closed.

A committed or exact idempotent response has status `connection_registered` or
`idempotent`, a receipt whose action remains
`connection.registration.verify`, and exactly this de-secretsed registration
object:

```text
schema = dirextalk.aws.connection-registration/v1
bootstrap_id
connection_id
account_id
region
broker_command_url
node_key_id
connection_generation
stack_arn
command_id
request_sha256
```

The registration is stored in the immutable DynamoDB receipt, so retrying the
same signed request after its short command window returns the original
attestation rather than recalculating a caller-provided claim. This action has
no EC2/EBS/IAM/S3 mutation and no Flutter approval path.

## Read-only on-demand quote

`quote.request` accepts one to three ordered candidates. Each candidate binds a
stable id, `economy`/`recommended`/`performance` tier, EC2 instance type,
`on_demand` purchase option, and estimated disk size. Spot is deliberately
rejected with `spot_quote_not_enabled`: it requires a separately validated
checkpoint/resume and interruption contract and cannot reuse this quote path.

For a fresh signed quote command, the Broker first verifies that every requested
instance type is offered in at least one availability zone in the requested
region. It then obtains the immutable instance metadata through
`DescribeInstanceTypes`: the canonical Dirextalk architecture (`amd64` or
`arm64`), default vCPU count, memory in MiB, GPU count, and total GPU memory in
MiB. A response that does not bind exactly one supported Dirextalk architecture
or a complete capacity record is rejected before price lookup; legacy `i386` is
ignored when the same type also declares `x86_64`. It then queries the
AWS Price List using the Linux, Shared-tenancy, used-capacity on-demand product
filters. The Pricing client uses the `us-east-1`
endpoint while the product filter retains the requested region; the EC2 client
uses the Stack region. It accepts only an unambiguous hourly USD price and
stores the result with the immutable command receipt. An exact idempotent replay
returns that stored result, including after the short signed-command window has
expired, without another AWS provider lookup.

The returned `dirextalk.aws.quote/v1` is valid for fifteen minutes and contains
USD minor-unit estimates rounded upward: `hourly_minor` and
`thirty_day_minor` (720 hours). It currently includes only
`ec2_linux_ondemand`; it explicitly excludes CloudWatch logs, data transfer,
gp3 EBS, public IPv4, snapshots, and taxes. `startup_upper_minor: 0` means no
one-off cost is modeled in this stage, **not** that the account has a hard
spending cap. A quote never creates an approval, opens a network endpoint, or
authorizes `deployment.create`.

The public Broker quote remains unchanged. The Stack maps that quote to the Go
`cloudorchestrator.QuoteV1` deterministic-CBOR form and writes its SHA-256 as a
private `quote_digest` with the issued quote. ProductCore independently writes
the same digest into the final `ApprovalV1`; it is carried by
`deployment.create` but is never added to the public quote response. The
quote's `plan_digest` is the pre-price `QuoteRequestV1` digest and is
intentionally not compared to the later final `plan_hash`.

The Dirextalk node signs each canonical command with its Stack-registered
Ed25519 public key. `deployment.create` must carry the existing full
`cloud-orchestrator/v1` Flutter `ApprovalV1` as top-level `approval_proof`.
It must not carry the older V2 `approval_binding` or `approval` fields. The
Broker validates the deterministic-CBOR Ed25519 proof against the registered
Flutter device key, binds it to the final plan, quote id/digest, recipe,
resource/network/secret/integration scopes, and requires its initial network
scope to have no public ingress or entry point.

The node-signature base retains its legacy empty approval rows and appends
`approval_proof_payload_sha256=<sha256 of deterministic-CBOR proof signing
payload>`. A Dynamo conditional write consumes the proof's `approval_id` once
with the command receipt and counter advance. Replays can return only the
already-bound immutable receipt; a proof cannot authorize another deployment.
The legacy challenge/binding form remains confined to its pre-existing action
contracts and cannot authorize `deployment.create`.

`createV2ChallengeApprovalService` is an offline adapter used by the Node
contract test. Its injected `receiptStore.commit` is the required atomic
boundary for every signed command. It receives the signed
`connection_id`, `expected_generation`, `node_counter`, `command_id`, request
digest, and action, plus the challenge issue/consume data when applicable.

`DynamoV2ReceiptStore` executes the command fence in one conditional
transaction:

- Same connection + command id + request digest/action/generation/counter:
  return the immutable receipt idempotently without consuming a challenge again,
  including after the short command/approval window has expired.
- Same connection + command id with any different signed identity field: reject
  as a command-id conflict.
- New command: require the active generation, a still-live command/approval,
  and a strictly advancing counter, then write the immutable receipt. For a
  quote, resolve the read-only provider result before that transaction and
  persist the exact validated quote and its private `quote_digest`. For
  registration, persist the exact Stack-derived attestation with that same
  counter advance.
- For a challenge request: write the one-time challenge with the receipt. For a
  `deployment.create`: conditionally write the one-time `ApprovalV1` proof
  reference (`connection_id`, `approval_id`, proof-payload digest, expiry) and
  reserve `(connection_id, deployment_id) -> request_sha256` with that same
  counter advance and receipt write. A different signed request for that
  deployment id is rejected before the handler can invoke EC2. The legacy
  challenge form remains only for its pre-existing actions.

If a conditional command response is lost or ambiguous, the Broker performs a
consistent receipt read and returns that exact receipt only when its signed
request identity matches. For an accepted `deployment.create`, the typed
provisioner treats the accepted reservation as non-receipt, then reads the
durable quote, uses the command digest as EC2 `ClientToken`, and conditionally
promotes only that same-request reservation to the immutable deployment
receipt. This covers retries without a second worker purchase. A same-id
mismatch, stale counter, expired fresh request, expired/replayed proof, quote
mismatch, or unavailable durable store fails closed.

The Lambda role has scoped DynamoDB reads/conditional transactions and a direct
conditional update only for deployment receipt promotion. Its EC2 surface is closed to descriptions,
`CreateSecurityGroup`, `RevokeSecurityGroupEgress`,
`AuthorizeSecurityGroupEgress`, `RunInstances`, and creation-time tagging in
the Stack Region. It has no `PassRole`, instance profile, key-pair, public-IP,
EIP, VPC, NAT, terminate, or generic EC2 permission. The Lambda source pins
DynamoDB, EC2, and Pricing SDK dependencies in
`src/package-lock.json`; do not rely on a runtime-provided SDK version for a
release build. The SAM function sets `BuildProperties.UseNpmCi: true`, so a
release must build artifacts before packaging/deployment:

```bash
sam build --template-file scripts/connection-stack-v2/template.json
# Deploy only the generated .aws-sam/build/template.yaml artifact.
```

Do not deploy the source template directly. `sam build` installs the exact
lockfile dependency into the Lambda artifact; the source-tree `.npmignore` only
keeps local `node_modules` out of the published `dirextalk-deployer` package.

## Pinned non-root deployment helper

The supported create/update entry point is `deploy.sh`, not an ad hoc `sam
deploy` command. ProductCore first creates a strict
`dirextalk.aws.connection-stack-deploy-request/v1` containing the opaque
bootstrap id, connection values, Ed25519 **public** keys, requested Region,
stage, stack name, and exact `sha256:` digests for both this template and the
complete Connection Stack source tree. It contains no AWS credentials or
service secrets.

```bash
bash scripts/connection-stack-v2/deploy.sh --apply \
  --request <connection-stack-deploy-request.json> \
  --artifact-bucket <existing-private-sam-artifact-bucket> \
  --output <connection-registration-manifest.json>
```

Before `sam build` or `sam deploy`, the helper verifies both pinned digests and
both Ed25519 public keys, calls `aws sts get-caller-identity`, and rejects root
and IAM-user identities. It requires a pre-existing explicit artifact bucket,
then verifies that the bucket is in the requested Region, has default SSE
encryption, and enables all four S3 public-access blocks. It never uses
`--resolve-s3` or creates a hidden SAM managed bucket. The caller must therefore
use a short-lived assumed role with the scoped CloudFormation/SAM artifact
permissions plus read-only bucket configuration checks required for this Stack.

The output is atomically written with restrictive permissions and has exactly
the private registration-manifest fields `schema`, `bootstrap_id`,
`connection_id`, `account_id`, `region`, `broker_command_url`, `node_key_id`,
`connection_generation`, `worker_artifact`, `worker_network`,
`worker_resource_manifest_digest`, and `stack_arn`. The three Worker fields
appear after `connection_generation` and before `stack_arn`; they are required
for Stack-side creation but must never enter a Cloud projection or client UI.
ProductCore must submit its `bootstrap_id`, `region`, and `stack_arn` through
the signed Broker action above before it treats this manifest as a registered
connection. The Stack exposes only corresponding nonsecret CloudFormation
outputs; table/key ARNs and public-key parameters are intentionally not output.

## Worker boundary

`deployment.create` launches one dedicated EC2 VM per deployment. Before that
call, the Broker read-backs the exact private subnet/VPC/AZ, rejects public-IP
or IPv6-capable subnets, verifies available private IPv4 capacity, and verifies
the immutable AMI is available and matches the selected quoted architecture.
It creates a deterministic, request-tagged security group with zero ingress;
the initial default egress is removed before attachment and only TCP 443 plus
VPC DNS (TCP/UDP 53) are allowed. A response-loss retry may repair only that
default rule, an empty rule set, or a safe subset; an unexpected group, ingress,
or egress fails closed.

`RunInstances` is strictly one instance from the Stack-pinned AMI and quote:
no instance profile, SSH/key pair, user data, public IPv4, IPv6, or caller
security group. It requires IMDSv2, disables instance-metadata tags, creates
encrypted retained gp3 storage, tags the instance/volume/ENI, and uses the
signed request digest as `ClientToken`. The only Broker-to-Orchestrator
deployment receipt has exactly:

```text
schema
connection_id
deployment_id
request_sha256
resource_status
instance_id
volume_ids
network_interface_ids
```

It contains no user data, Worker credentials, service secret, pairing material,
or log content.

`schemas/worker-bootstrap-v1.schema.json` and `src/worker-contract.mjs` still
define the future constrained bootstrap manifest. They are not an active Worker
claim/session endpoint: this stage does not issue or consume worker sessions,
accept Worker events/logs, or establish service readiness. Those remain a
separate follow-on contract.

## Offline verification

No test invokes AWS or reads credentials:

```bash
bash tests/connection_stack_v2_test.sh
node --check scripts/connection-stack-v2/src/command-contract.mjs
node --check scripts/connection-stack-v2/src/registration-contract.mjs
node --check scripts/connection-stack-v2/src/deploy-helper.mjs
node --check scripts/connection-stack-v2/src/dynamo-receipt-store.mjs
node --check scripts/connection-stack-v2/src/dynamo-deployment-store.mjs
node --check scripts/connection-stack-v2/src/quote-provider.mjs
node --check scripts/connection-stack-v2/src/approval-proof.mjs
node --check scripts/connection-stack-v2/src/deployment-contract.mjs
node --check scripts/connection-stack-v2/src/deployment-provisioner.mjs
node --check scripts/connection-stack-v2/src/worker-contract.mjs
bash -n scripts/connection-stack-v2/deploy.sh
git diff --check
```

The tests include in-process DynamoDB and AWS-provider seams that prove atomic
transaction shape, counter/receipt/challenge fencing, idempotent expired quote
reconciliation without a second provider call, upward minor-unit rounding,
read-only API command shape, availability checks, and Spot rejection before any
provider request. They also prove Go/Node deterministic-CBOR quote-digest
agreement, ApprovalV1 signature and one-time consumption, strict create/receipt
shapes, a private subnet, no caller-controlled EC2 settings, a response-lost
security-group recovery, and no public ingress/instance profile/user data.
Registration tests additionally prove exact three-field payloads,
Stack-derived endpoint/Region/ARN binding, immutable replay, root rejection,
template/source-digest pinning, the private Worker registration fields, and the
deploy helper's explicit existing-artifact-bucket path.
