# Dirextalk Connection Stack V2 — durable command fence

This directory implements the V2 signed-command and Flutter-device-approval
**durable fence**, not a cloud executor. It is deliberately separate from
`scripts/connection-stack` (V1), which must not be extended in place because
V1 approvals do not bind the Flutter device signature scope required by the
Cloud Orchestrator.

The SAM template may be deployed only as a Connection Stack control-plane
prerequisite. Its regional Broker API verifies a bounded signed command,
persists an immutable receipt and a one-time approval challenge in DynamoDB,
and returns a de-secretsed receipt. It has no EC2/EBS/IAM/PassRole/SSH/S3
mutation, no worker bootstrap execution, and no secret-read capability. It
cannot provision, observe, stop, start, or destroy cloud resources.

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
- `quote.request`
- `artifact.put`
- `deployment.create`
- `deployment.observe`
- `deployment.destroy`

There is no generic AWS action, arbitrary API name, shell command, IAM action,
or raw EC2 specification in the protocol. `artifact.put` carries only a typed
content reference in this skeleton; it does not upload bytes.

The Dirextalk node signs each canonical command with its Stack-registered
Ed25519 public key. Mutating actions (`artifact.put`, `deployment.create`, and
`deployment.destroy`) additionally require a Flutter Ed25519 approval. The
approval is bound to a one-time challenge and to all of the following fields:

```text
connection_id
plan_hash + plan_revision + quote_id
recipe_digest + manifest_digest
resource_scope_digest + network_scope_digest
secret_scope_digest + integration_scope_digest
expires_at
```

The node signature also covers the approval-binding digest, challenge id, and
approval signature digest. Altering a plan, quote, recipe, resource, network,
secret, integration scope, manifest, expiry, or approval cannot be detached
from either signature.

`createV2ChallengeApprovalService` is an offline adapter used by the Node
contract test. Its injected `receiptStore.commit` is the required atomic
boundary for every signed command. It receives the signed
`connection_id`, `expected_generation`, `node_counter`, `command_id`, request
digest, and action, plus the challenge issue/consume data when applicable.

`DynamoV2ReceiptStore` executes the following in one conditional transaction:

- Same connection + command id + request digest/action/generation/counter:
  return the immutable receipt idempotently without consuming a challenge again,
  including after the short command/approval window has expired.
- Same connection + command id with any different signed identity field: reject
  as a command-id conflict.
- New command: require the active generation, a still-live command/approval,
  and a strictly advancing counter, then write the immutable receipt.
- For a challenge request: write the one-time challenge with the receipt. For a
  mutating command: conditionally consume that exact unexpired challenge with
  the counter advance and receipt write.

If a conditional transaction's response is lost or ambiguous, the Broker
performs a consistent receipt read and returns that exact receipt only when its
signed request identity matches. It never retries a cloud action because this
stage has no cloud action. A same-id mismatch, stale counter, expired fresh
request, expired/replayed challenge, or unavailable durable store fails closed.

The Lambda role has only `dynamodb:GetItem` and
`dynamodb:TransactWriteItems` against the three Stack-owned tables, plus its
CloudWatch Logs permissions. The Lambda source pins the DynamoDB SDK dependency
in `src/package-lock.json`; do not rely on a runtime-provided SDK version for a
release build. The SAM function sets `BuildProperties.UseNpmCi: true`, so a
release must build artifacts before packaging/deployment:

```bash
sam build --template-file scripts/connection-stack-v2/template.json
# Deploy only the generated .aws-sam/build/template.yaml artifact.
```

Do not deploy the source template directly. `sam build` installs the exact
lockfile dependency into the Lambda artifact; the source-tree `.npmignore` only
keeps local `node_modules` out of the published `dirextalk-deployer` package.

## Worker boundary

`schemas/worker-bootstrap-v1.schema.json` and `src/worker-contract.mjs` define
the future worker bootstrap manifest. It permits only a deployment id,
connection id, ephemeral session id, HTTPS bootstrap endpoint, immutable worker
image digest, artifact-manifest digest, and expiry. It forbids unknown fields,
including SSH keys, IAM/instance-profile configuration, AWS credentials, or
user-data commands.

The validator requires a verifier context with the expected connection id,
registered broker endpoint, current time, and a positive maximum lifetime no
greater than ten minutes. It rejects expired manifests, excessive TTLs, and a
broker endpoint that does not exactly match the registered HTTPS endpoint. A
future worker-session store must still atomically bind and consume
`bootstrap_session_id`; schema validation alone is not a session grant.

The eventual executor must launch one dedicated EC2 VM per deployment with no
instance profile, no SSH/key pair, no reusable cloud credential, zero public
inbound access by default, IMDSv2 enforcement, encrypted storage, and a
one-time worker session. That executor is a later, separately reviewed stage.

## Offline verification

No test invokes AWS or reads credentials:

```bash
bash tests/connection_stack_v2_test.sh
node --check scripts/connection-stack-v2/src/command-contract.mjs
node --check scripts/connection-stack-v2/src/dynamo-receipt-store.mjs
node --check scripts/connection-stack-v2/src/worker-contract.mjs
git diff --check
```

The tests include an in-process DynamoDB seam that proves atomic transaction
shape, counter/receipt/challenge fencing, idempotent expired reconciliation,
and a reused Flutter approval challenge failing even when an attacker supplies
a new node command id.
