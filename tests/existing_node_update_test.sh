#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_WORKDIR="$tmp/node" CALLS="$tmp/calls"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
: >"$CALLS"
printf 'key\n' >"$DIREXTALK_WORKDIR/key.pem"
chmod 0600 "$DIREXTALK_WORKDIR/key.pem"
printf 'host-key\n' >"$DIREXTALK_WORKDIR/known_hosts"
chmod 0600 "$DIREXTALK_WORKDIR/known_hosts"

source "$ROOT/scripts/cloud-init/split/release.env"
source "$ROOT/scripts/updater/release.env"
old_revision=5969693b213c52a355159a697a8e759e8808ae0c
machine_id=ec2879f4b555f3ccac4531e9fe4cc127
docker_engine_id=ABCDEFGH12345678
account=066107820442
region=ap-east-1
public_ip=203.0.113.44
provider_id=cdf05b44-473e-46dd-8703-b9631d5cbba8
provider_arn="arn:aws:lightsail:$region:$account:Instance/$provider_id"
support_code=989571800832/i-0d222799a0431b5ed
bundle_sha=$(awk 'NF == 2 && $2 == "canonical-bundle.tar.gz" {print $1}' \
  "$ROOT/scripts/cloud-init/split/canonical-bundle.tar.gz.sha256")

write_state() {
  local include_identity=${1:-true}
  node_identity='{}'
  if [ "$include_identity" = true ]; then
    node_identity=$(printf '{"aws_account_id":"%s","region":"%s","cloud_provider":"lightsail","provider_instance_id":"%s","provider_instance_arn":"%s","provider_support_code":"%s","public_ip":"%s","machine_id":"%s","docker_engine_id":"%s"}' \
      "$account" "$region" "$provider_id" "$provider_arn" "$support_code" "$public_ip" "$machine_id" "$docker_engine_id")
  fi
  printf '{"run_id":"update-test","domain":"update.example.test","region":"%s","cloud_provider":"lightsail","resources":{"key_file":"%s","public_ip":"%s","lightsail_instance_name":"dirextalk-update-test"},"node_identity":%s,"server_release":{"source":"production_split","version":"%s","image":"docker.io/dirextalk/message-server:%s","digest":"%s","image_ref":"%s","manifest_digest":"%s"},"split_release":{"message_version":"%s","message_image":"%s","message_source_revision":"%s","split_source_revision":"%s","agent_version":"%s","agent_image":"%s","agent_source_revision":"%s","caddy_image":"%s","coturn_image":"%s"},"updater_release":{"version":"v0.0.1"}}\n' \
    "$region" "$DIREXTALK_WORKDIR/key.pem" "$public_ip" "$node_identity" \
    "$DIREXTALK_MESSAGE_SERVER_VERSION" "$DIREXTALK_MESSAGE_SERVER_VERSION" \
    "${DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE##*@}" "$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" \
    "${DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE##*@}" "$DIREXTALK_MESSAGE_SERVER_VERSION" \
    "$DIREXTALK_MESSAGE_SERVER_IMAGE_IMMUTABLE" "$DIREXTALK_MESSAGE_SOURCE_REVISION" "$old_revision" \
    "$DIREXTALK_AGENT_VERSION" "$DIREXTALK_AGENT_IMAGE_IMMUTABLE" "$DIREXTALK_AGENT_SOURCE_REVISION" \
    "$DIREXTALK_CADDY_IMAGE_IMMUTABLE" "$DIREXTALK_COTURN_IMAGE_IMMUTABLE" >"$DIREXTALK_WORKDIR/state.json"
  chmod 0600 "$DIREXTALK_WORKDIR/state.json"
}

cat >"$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf 'aws:%s\n' "$*" >>"$CALLS"
case "$*" in
  *'sts get-caller-identity'*) printf '%s\n' "${ACTUAL_ACCOUNT:-$EXPECTED_ACCOUNT}" ;;
  *'lightsail get-instance'*)
    printf '%s\t%s\t%s\n' "${ACTUAL_ARN:-$EXPECTED_ARN}" "$EXPECTED_SUPPORT" "$EXPECTED_IP"
    ;;
  *) exit 91 ;;
esac
EOF
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
command=${!#}
case "$command" in
  *'apply-host-integration.sh'*)
    printf 'ssh:integration\n' >>"$CALLS"
    cat >"$TEST_TRANSPORT"
    [ "${INTEGRATION_STATUS:-0}" -eq 0 ] || exit "$INTEGRATION_STATUS"
    printf 'integration output\n%s\t%s\t%s\n' "$EXPECTED_MACHINE" "$EXPECTED_DOCKER" "$EXPECTED_BUNDLE_SHA"
    ;;
  *'/etc/machine-id'*)
    printf 'ssh:identity\n' >>"$CALLS"
    printf '%s\t%s\n' "${ACTUAL_MACHINE:-$EXPECTED_MACHINE}" "$EXPECTED_DOCKER"
    ;;
  *) printf 'unexpected ssh command: %s\n' "$command" >&2; exit 92 ;;
esac
EOF
chmod 0755 "$tmp/bin/aws" "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH"
export EXPECTED_ACCOUNT=$account EXPECTED_ARN=$provider_arn EXPECTED_SUPPORT=$support_code EXPECTED_IP=$public_ip
export EXPECTED_MACHINE=$machine_id EXPECTED_DOCKER=$docker_engine_id EXPECTED_BUNDLE_SHA=$bundle_sha
export TEST_TRANSPORT="$tmp/transport.tar.gz"

# Missing immutable identity is a local contract failure and must not perform
# any external read or mutation.
write_state false
if bash "$ROOT/scripts/update.sh" "$DIREXTALK_WORKDIR/state.json" >/dev/null 2>&1; then
  echo 'existing-node update accepted state without immutable identity' >&2
  exit 1
fi
[ ! -s "$CALLS" ]

# The real update consumer stages the released canonical bundle. The staged
# host integration performs the receipt-bound reconcile before returning;
# update.sh then revalidates identity and atomically records both releases.
write_state true
: >"$CALLS"
bash "$ROOT/scripts/update.sh" "$DIREXTALK_WORKDIR/state.json" >/dev/null
[ "$(grep -c '^ssh:identity$' "$CALLS")" -eq 2 ]
[ "$(grep -c '^ssh:integration$' "$CALLS")" -eq 1 ]
transport_listing=$(tar -tzf "$TEST_TRANSPORT")
grep -Fxq 'cloud-init/split/apply-host-integration.sh' <<<"$transport_listing"
grep -Fxq 'canonical-bundle.tar.gz' <<<"$transport_listing"
node "$ROOT/scripts/json.mjs" check "$DIREXTALK_WORKDIR/state.json" \
  "data.split_release.split_source_revision === '$DIREXTALK_SPLIT_SOURCE_REVISION' && data.updater_release.version === '$UPDATER_PIN_VERSION' && data.updater_release.commit === '$UPDATER_PIN_COMMIT' && data.updater_release.sha256 === '$UPDATER_PIN_SHA256'"

# An expected-negative integration result remains exit 3 and leaves both local
# release records untouched.
write_state true
: >"$CALLS"
if INTEGRATION_STATUS=3 bash "$ROOT/scripts/update.sh" "$DIREXTALK_WORKDIR/state.json" >/dev/null 2>&1; then
  echo 'existing-node update accepted expected-negative host integration' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
node "$ROOT/scripts/json.mjs" check "$DIREXTALK_WORKDIR/state.json" \
  "data.split_release.split_source_revision === '$old_revision' && data.updater_release.version === 'v0.0.1'"

write_state true
: >"$CALLS"
if INTEGRATION_STATUS=17 bash "$ROOT/scripts/update.sh" "$DIREXTALK_WORKDIR/state.json" >/dev/null 2>&1; then
  echo 'existing-node update accepted an infrastructure integration failure' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
node "$ROOT/scripts/json.mjs" check "$DIREXTALK_WORKDIR/state.json" \
  "data.split_release.split_source_revision === '$old_revision' && data.updater_release.version === 'v0.0.1'"

# Provider or host mismatch fails before the next mutation and does not update
# local provenance.
write_state true
: >"$CALLS"
if ACTUAL_MACHINE=ffffffffffffffffffffffffffffffff \
    bash "$ROOT/scripts/update.sh" "$DIREXTALK_WORKDIR/state.json" >/dev/null 2>&1; then
  echo 'existing-node update accepted a different machine identity' >&2
  exit 1
fi
if grep -Eq '^ssh:integration$' "$CALLS"; then
  echo 'identity mismatch reached an update mutation' >&2
  exit 1
fi

echo 'existing node update ok'
