#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_WORKDIR="$tmp/work" CALLS="$tmp/calls" REMOTE_COMMAND="$tmp/remote-command"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
: > "$CALLS"
printf 'key\n' > "$tmp/key.pem"
printf '#!/bin/sh\nexit 0\n' > "$tmp/updater"
chmod 0755 "$tmp/updater"

cat > "$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp\n' >> "$CALLS"
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >> "$CALLS"
printf '%s\n' "${!#}" > "$REMOTE_COMMAND"
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
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

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
  if _upload_updater_binary "$ip" "$tmp/key.pem" "$tmp/updater" >/dev/null 2>&1; then
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
_upload_updater_binary 203.0.113.44 "$tmp/key.pem" "$tmp/updater"
[ "$(grep -c '^scp$' "$CALLS")" = 2 ]
[ "$(grep -c '^ssh$' "$CALLS")" = 1 ]
grep -F -q "bootstrap-host '203.0.113.44'" "$REMOTE_COMMAND"

echo "s3 public IP validation ok"
