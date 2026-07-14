import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";

import {
  approvalProofPayloadSHA256,
  canonicalApprovalProofPayload,
  validateApprovalProof,
  validateApprovalProofAgainstDeployment,
} from "../scripts/connection-stack-v2/src/approval-proof.mjs";

const DIGEST = (value) => `sha256:${value}`;
const proof = {
  schema_version: "cloud-orchestrator/v1",
  approval_id: "approval-1",
  challenge_id: "challenge-1",
  signer_key_id: "owner-device-1",
  plan_id: "plan-1",
  plan_hash: DIGEST("46fa830ad4e9d6bfd9328ba982c073da24e3ebabd0e1306a257ea73f970f90c2"),
  plan_revision: 7,
  quote_id: "quote-1",
  quote_digest: DIGEST("d9782ce2f66a9f87433281fd5e3f41e25a1a81d43920945e8d4ac866e8384931"),
  quote_valid_until: "2026-07-14T10:15:00Z",
  cloud_connection_id: "connection-1",
  recipe_digest: DIGEST("4659c83391aa67fff264e0b840c383feb327dd75d066f8445588402dd71a9606"),
  resource_scope: {
    region: "us-east-1",
    availability_zones: ["us-east-1b", "us-east-1a"],
    instance_type: "m7i.xlarge",
    architecture: "amd64",
    vcpu: 4,
    memory_mib: 16384,
    disk_gib: 80,
    purchase_option: "on_demand",
  },
  network_scope: {
    public_ingress: false,
    entry_point: "none",
    tls_required: false,
    authentication_required: false,
  },
  secret_scope: [
    { secret_ref: "secret_ref:model-token", purpose: "model-access", delivery: "file" },
    { secret_ref: "secret_ref:github-app", purpose: "source-access", delivery: "file" },
  ],
  integration_scope: [
    { kind: "web", name: "web-ui" },
    { kind: "mcp", name: "mcp" },
  ],
  expires_at: "2026-07-14T10:10:00Z",
  signature: "",
};

const wantPayloadBase64 = "s2dwbGFuX2lkZnBsYW4tMWhxdW90ZV9pZGdxdW90ZS0xaXBsYW5faGFzaHhHc2hhMjU2OjQ2ZmE4MzBhZDRlOWQ2YmZkOTMyOGJhOTgyYzA3M2RhMjRlM2ViYWJkMGUxMzA2YTI1N2VhNzNmOTcwZjkwYzJqZXhwaXJlc19hdHQyMDI2LTA3LTE0VDEwOjEwOjAwWmthcHByb3ZhbF9pZGphcHByb3ZhbC0xbGNoYWxsZW5nZV9pZGtjaGFsbGVuZ2UtMWxxdW90ZV9kaWdlc3R4R3NoYTI1NjpkOTc4MmNlMmY2NmE5Zjg3NDMzMjgxZmQ1ZTNmNDFlMjVhMWE4MWQ0MzkyMDk0NWU4ZDRhYzg2NmU4Mzg0OTMxbHNlY3JldF9zY29wZYKjZ3B1cnBvc2Vtc291cmNlLWFjY2Vzc2hkZWxpdmVyeWRmaWxlanNlY3JldF9yZWZ1c2VjcmV0X3JlZjpn aXRodWItYXBwo2dwdXJwb3NlbG1vZGVsLWFjY2Vzc2hkZWxpdmVyeWRmaWxlanNlY3JldF9yZWZ2c2VjcmV0X3JlZjptb2RlbC10b2tlbm1uZXR3b3JrX3Njb3BlpGtlbnRyeV9wb2ludGRub25lbHRsc19yZXF1aXJlZPRucHVibGljX2luZ3Jlc3P0d2F1dGhlbnRpY2F0aW9uX3JlcXVpcmVk9G1wbGFuX3JldmlzaW9uB21yZWNpcGVfZGlnZXN0eEdzaGEyNTY6NDY1OWM4MzM5MWFhNjdmZmYyNjRlMGI4NDBjMzgzZmViMzI3ZGQ3NWQwNjZmODQ0NTU4ODQwMmRkNzFhOTYwNm1zaWduZXJfa2V5X2lkbm93bmVyLWRldmljZS0xbmhhc2hfYWxnb3JpdGhteBlkZXRlcm1pbmlzdGljLWNib3Itc2hhMjU2bnJlc291cmNlX3Njb3BlqGR2Y3B1BGZyZWdpb25pdXMtZWFzdC0xaGRpc2tfZ2liGFBqbWVtb3J5X21pYhlAAGxhcmNoaXRlY3R1cmVlYW1kNjRtaW5zdGFuY2VfdHlwZWptN2kueGxhcmdlb3B1cmNoYXNlX29wdGlvbmlvbl9kZW1hbmRyYXZhaWxhYmlsaXR5X3pvbmVzgmp1cy1lYXN0LTFhanVzLWVhc3QtMWJuc2NoZW1hX3ZlcnNpb251Y2xvdWQtb3JjaGVzdHJhdG9yL3Yxb3BheWxvYWRfdmVyc2lvbngbYXBwcm92YWwtc2lnbmluZy1wYXlsb2FkL3YxcWludGVncmF0aW9uX3Njb3BlgqJka2luZGNtY3BkbmFtZWNtY3CiZGtpbmRjd2ViZG5hbWVmd2ViLXVpcXF1b3RlX3ZhbGlkX3VudGlsdDIwMjYtMDctMTRUMTA6MTU6MDBac2Nsb3VkX2Nvbm5lY3Rpb25faWRsY29ubmVjdGlvbi0x".replace(" ", "");

const canonical = canonicalApprovalProofPayload(proof);
assert.equal(canonical.toString("base64"), wantPayloadBase64, "Node CBOR must exactly match the Go ApprovalV1 golden vector");
assert.equal(approvalProofPayloadSHA256(proof), createHash("sha256").update(canonical).digest("hex"));
assert.deepEqual(
  canonicalApprovalProofPayload({ ...proof, secret_scope: [], integration_scope: [] }),
  canonicalApprovalProofPayload({ ...proof, secret_scope: null, integration_scope: null }),
  "Go normalizePlan canonicalizes empty optional scopes to nil, so Stack CBOR must preserve null rather than transport []",
);

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
proof.signature = sign(null, canonical, privateKey).toString("base64url");
const publicKeySpkiBase64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");
const verified = validateApprovalProof(proof, {
  deviceKeyId: proof.signer_key_id,
  devicePublicKeySpkiBase64: publicKeySpkiBase64,
  nowMs: Date.parse("2026-07-14T10:00:00.000Z"),
});
assert.equal(verified.approval_id, "approval-1");
validateApprovalProofAgainstDeployment(verified, {
  connectionId: "connection-1",
  payload: {
    plan_hash: proof.plan_hash,
    plan_revision: proof.plan_revision,
    quote_id: proof.quote_id,
    quote_digest: proof.quote_digest,
  },
  nowMs: Date.parse("2026-07-14T10:00:00.000Z"),
});

assert.throws(
  () => validateApprovalProof({ ...proof, plan_hash: DIGEST("f".repeat(64)) }, {
    deviceKeyId: proof.signer_key_id,
    devicePublicKeySpkiBase64: publicKeySpkiBase64,
    nowMs: Date.parse("2026-07-14T10:00:00.000Z"),
  }),
  (error) => error?.code === "invalid_approval_proof_signature",
  "altering any signed ApprovalV1 field must invalidate the one device signature",
);
assert.throws(
  () => validateApprovalProofAgainstDeployment(verified, {
    connectionId: "connection-elsewhere",
    payload: {
      plan_hash: proof.plan_hash,
      plan_revision: proof.plan_revision,
      quote_id: proof.quote_id,
      quote_digest: proof.quote_digest,
    },
    nowMs: Date.parse("2026-07-14T10:00:00.000Z"),
  }),
  (error) => error?.code === "approval_proof_mismatch",
);

console.log("connection stack v2 ApprovalV1 proof boundary ok");
