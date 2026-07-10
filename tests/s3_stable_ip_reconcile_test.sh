#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_WORKDIR="$tmp/work" CALLS="$tmp/calls"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
: > "$CALLS"

cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"; printf ' %q' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"
case "${1:-} ${2:-}" in
  "ec2 describe-addresses")
    case "$*" in
      *InstanceId*) [ -f "$EC2_ATTACHED" ] && printf 'i-current\n' || printf 'i-old\n' ;;
      *PublicIp*) printf '203.0.113.31\n' ;;
    esac
    ;;
  "ec2 associate-address") touch "$EC2_ATTACHED" ;;
  "lightsail get-static-ip")
    case "$*" in
      *attachedTo*) [ -f "$LIGHTSAIL_ATTACHED" ] && printf 'node-current\n' || printf 'node-old\n' ;;
      *ipAddress*) printf '203.0.113.32\n' ;;
    esac
    ;;
  "lightsail attach-static-ip") touch "$LIGHTSAIL_ATTACHED" ;;
  *) echo "unexpected aws command: $*" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH" EC2_ATTACHED="$tmp/ec2.attached" LIGHTSAIL_ATTACHED="$tmp/lightsail.attached"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

[ "$(_ensure_ec2_eip_attachment i-current eipalloc-current)" = 203.0.113.31 ]
[ "$(_ensure_ec2_eip_attachment i-current eipalloc-current)" = 203.0.113.31 ]
[ "$(grep -c '^aws ec2 associate-address' "$CALLS")" = 1 ]
[ "$(grep -c 'InstanceId' "$CALLS")" = 2 ]

[ "$(_ensure_lightsail_static_ip_attachment node-current static-current)" = 203.0.113.32 ]
[ "$(_ensure_lightsail_static_ip_attachment node-current static-current)" = 203.0.113.32 ]
[ "$(grep -c '^aws lightsail attach-static-ip' "$CALLS")" = 1 ]
[ "$(grep -c 'attachedTo' "$CALLS")" = 2 ]

echo "s3 stable IP reconciliation ok"
