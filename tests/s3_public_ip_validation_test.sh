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
exit 97
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >> "$CALLS"
printf '%s\n' "${!#}" > "$REMOTE_COMMAND"
cat >/dev/null
printf 'v1.0.10\ta8971d7b04e8fef29b35ef889cc1b70d7ceca7a5\t730f3d1e4c6f604069e1b6eed60121bffb47f32d2f1d960cb3f8a0121974b6b8\n'
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
lightsail_bootstrap="$tmp/lightsail-bootstrap.sh"
printf '#!/bin/bash\nset -eu\nexit 0\n' > "$lightsail_bootstrap"
lightsail_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for ip in "${invalid_ips[@]}"; do
  : > "$CALLS"
  if _resume_host_bootstrap "$ip" "$tmp/key.pem" >/dev/null 2>&1; then
    echo "invalid public IP reached uploader: [$ip]" >&2
    exit 1
  fi
  [ ! -s "$CALLS" ] || { echo "invalid public IP invoked scp/ssh: [$ip]" >&2; exit 1; }

  : > "$CALLS"
  if _bootstrap_lightsail_host "$ip" "$tmp/key.pem" "$lightsail_bootstrap" "$lightsail_nonce" >/dev/null 2>&1; then
    echo "invalid public IP reached Lightsail root bootstrap: [$ip]" >&2
    exit 1
  fi
  [ ! -s "$CALLS" ] || { echo "invalid public IP invoked Lightsail root bootstrap SSH: [$ip]" >&2; exit 1; }
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
printf '203.0.113.44 ssh-ed25519 pinned-test-key\n' > "$tmp/known_hosts"
res_set lightsail_ssh_known_hosts "$tmp/known_hosts"
_resume_host_bootstrap 203.0.113.44 "$tmp/key.pem"
[ "$(grep -c '^scp$' "$CALLS")" = 0 ]
[ "$(grep -c '^ssh$' "$CALLS")" = 1 ]
grep -F -q 'tar -xzf -' "$REMOTE_COMMAND"
grep -F -q 'reconcile-host.sh' "$REMOTE_COMMAND"
grep -F -q "'203.0.113.44'" "$REMOTE_COMMAND"

echo "s3 public IP validation ok"
