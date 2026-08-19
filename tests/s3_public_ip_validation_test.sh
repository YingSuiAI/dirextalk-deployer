#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/tests/lib/split-release.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_WORKDIR="$tmp/work" CALLS="$tmp/calls" REMOTE_COMMAND="$tmp/remote-command"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
dirextalk_test_prepare_split_release "$tmp"
: > "$CALLS"
printf 'key\n' > "$tmp/key.pem"
printf '#!/bin/sh\nexit 0\n' > "$tmp/updater"
chmod 0755 "$tmp/updater"

cat > "$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp\n' >> "$CALLS"
exit 97
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >> "$CALLS"
printf '%s\n' "${!#}" > "$REMOTE_COMMAND"
cat >/dev/null
[ "${SSH_STATUS:-0}" -eq 0 ] || exit "$SSH_STATUS"
printf 'v1.0.19\t1e71b9d53c599e8fb9227050b8c9643ce723acc5\t882f5131697a3f232c5975420e866ab165e1bc7f92e865f33114ed20b79a14b3\n'
EOF
cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *InstanceId*) printf 'i-current\n' ;;
  *attachedTo*) printf 'node-current\n' ;;
  *PublicIp*|*ipAddress*) printf '%s\n' "$AWS_PUBLIC_IP" ;;
  *) exit 90 ;;
esac
EOF
chmod 0755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region us-east-1
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"
server_release_record_split_state
recorded_old_split_revision=f36099ef925a020f00432ab8b97f76fa902b066e
state_set split_release.split_source_revision "$recorded_old_split_revision"

invalid_ips=(
  ''
  ' 203.0.113.44'
  '203.0.113.44 '
  '203.0.113.044'
  '256.0.0.1'
  $'203.0.113.44\n touch /tmp/injected'
  '203.0.113.44;touch/tmp/injected'
  '$(touch /tmp/injected)'
)
for ip in "${invalid_ips[@]}"; do
  : > "$CALLS"
  if _resume_host_bootstrap "$ip" "$tmp/key.pem" >/dev/null 2>&1; then
    echo "invalid public IP reached uploader: [$ip]" >&2
    exit 1
  fi
  [ ! -s "$CALLS" ] || { echo "invalid public IP invoked scp/ssh: [$ip]" >&2; exit 1; }
done

for ip in '203.0.113.044' '999.0.0.1' $'203.0.113.44\nssh'; do
  export AWS_PUBLIC_IP=$ip
  if _ensure_ec2_eip_attachment i-current eipalloc-current >/dev/null 2>&1; then
    echo "invalid EC2 public IP was accepted: [$ip]" >&2
    exit 1
  fi
  if _ensure_lightsail_static_ip_attachment node-current static-current >/dev/null 2>&1; then
    echo "invalid Lightsail public IP was accepted: [$ip]" >&2
    exit 1
  fi
done

: > "$CALLS"
_resume_host_bootstrap 203.0.113.44 "$tmp/key.pem"
[ "$(grep -c '^scp$' "$CALLS")" = 0 ]
[ "$(grep -c '^ssh$' "$CALLS")" = 1 ]
grep -F -q 'tar --no-same-owner -xzf -' "$REMOTE_COMMAND"
grep -F -q 'bootstrap-host.sh" --record-stable-ip' "$REMOTE_COMMAND"
grep -F -q 'apply-host-integration.sh' "$REMOTE_COMMAND"
grep -F -q 'cloud-init status --wait' "$REMOTE_COMMAND"
grep -F -q 'cloud-init status --wait >/dev/null 2>&1 || :' "$REMOTE_COMMAND"
grep -F -q "/var/dirextalk-message-server '$recorded_old_split_revision'" "$REMOTE_COMMAND"
grep -F -q "'203.0.113.44'" "$REMOTE_COMMAND"
grep -F -q "'203.0.113.44' 'us-east-1'" "$REMOTE_COMMAND"
case "$(cat "$REMOTE_COMMAND")" in
  *'sudo mktemp -d '*'sudo tar --no-same-owner -xzf -'*'bootstrap-host.sh" --record-stable-ip'*'apply-host-integration.sh'*'cloud-init status --wait'*'printf '*) ;;
  *) echo 'split authorization must precede every canonical runtime/install mutation' >&2; exit 1 ;;
esac
[ "$(state_get split_release.split_source_revision)" = "$DIREXTALK_SPLIT_SOURCE_REVISION" ]

: >"$CALLS"
if SSH_STATUS=3 DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=3 \
    _resume_host_bootstrap 203.0.113.44 "$tmp/key.pem" >/dev/null 2>&1; then
  echo 'host bootstrap resume accepted an expected-negative tooling revision advance' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 3 ]
[ "$(grep -c '^ssh$' "$CALLS")" -eq 1 ]

: >"$CALLS"
if SSH_STATUS=17 DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=1 \
    _resume_host_bootstrap 203.0.113.44 "$tmp/key.pem" >/dev/null 2>&1; then
  echo 'host bootstrap resume accepted an infrastructure-failed tooling revision advance' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ "$(grep -c '^ssh$' "$CALLS")" -eq 1 ]

# A failed second staging allocation must clean the first bundle and never
# reach the uploader. Cleanup is deliberately limited to the two exact
# literal leftovers; unrelated files and symlinks remain untouched.
known_integration="$DIREXTALK_WORKDIR/.updater-integration.XXXXXX.tar.gz"
known_split="$DIREXTALK_WORKDIR/.split-agent-runtime.XXXXXX.tar.gz"
printf 'stale integration\n' >"$known_integration"
printf 'stale split\n' >"$known_split"
printf 'unrelated\n' >"$DIREXTALK_WORKDIR/.split-agent-runtime.other.tar.gz"
ln -s unrelated "$DIREXTALK_WORKDIR/.updater-integration.XXXXXX.tar.gz.link"
cat >"$tmp/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'.split-agent-runtime.XXXXXX.tar.gz') exit 77 ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
EOF
chmod 700 "$tmp/bin/mktemp"
: >"$CALLS"
if _resume_host_bootstrap 203.0.113.44 "$tmp/key.pem" >/dev/null 2>&1; then
  echo 'host bootstrap accepted a failed second transport allocation' >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 1 ]
[ ! -e "$known_integration" ]
[ ! -e "$known_split" ]
[ -f "$DIREXTALK_WORKDIR/.split-agent-runtime.other.tar.gz" ]
[ -L "$DIREXTALK_WORKDIR/.updater-integration.XXXXXX.tar.gz.link" ]
[ ! -s "$CALLS" ]
find "$DIREXTALK_WORKDIR" -maxdepth 1 -type f -name '.updater-integration.*.tar.gz' -print -quit | grep -q . && {
  echo 'failed second allocation leaked the first transport bundle' >&2
  exit 1
} || :

echo "s3 public IP validation ok"
