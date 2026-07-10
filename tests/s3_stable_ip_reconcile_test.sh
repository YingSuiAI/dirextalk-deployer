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
next_owner() {
  local count_file=$1 attached_file=$2 current=$3
  local count=0
  [ -f "$count_file" ] && count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [ -f "$attached_file" ] && [ "$count" -ge 3 ]; then printf '%s\n' "$current"; else printf 'old-owner\n'; fi
}
case "${1:-} ${2:-}" in
  "ec2 describe-addresses")
    case "$*" in
      *InstanceId*)
        case "$*" in
          *eipalloc-never*) printf 'old-owner\n' ;;
          *) next_owner "$EC2_READS" "$EC2_ATTACHED" i-current ;;
        esac ;;
      *PublicIp*) printf '203.0.113.31\n' ;;
    esac
    ;;
  "ec2 associate-address") touch "$EC2_ATTACHED" ;;
  "lightsail get-static-ip")
    case "$*" in
      *attachedTo*)
        case "$*" in
          *static-never*) printf 'old-owner\n' ;;
          *) next_owner "$LIGHTSAIL_READS" "$LIGHTSAIL_ATTACHED" node-current ;;
        esac ;;
      *ipAddress*) printf '203.0.113.32\n' ;;
    esac
    ;;
  "lightsail attach-static-ip") touch "$LIGHTSAIL_ATTACHED" ;;
  *) echo "unexpected aws command: $*" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH" EC2_ATTACHED="$tmp/ec2.attached" LIGHTSAIL_ATTACHED="$tmp/lightsail.attached"
export EC2_READS="$tmp/ec2.reads" LIGHTSAIL_READS="$tmp/lightsail.reads"
export DIREXTALK_STABLE_IP_RECONCILE_ATTEMPTS=3 DIREXTALK_STABLE_IP_RECONCILE_DELAY=0

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

# One helper call must repair, tolerate delayed consistency, prove the new owner,
# and only then read/return the public IP.
[ "$(_ensure_ec2_eip_attachment i-current eipalloc-current)" = 203.0.113.31 ]
[ "$(grep -c '^aws ec2 associate-address' "$CALLS")" = 1 ]
[ "$(grep -c 'InstanceId' "$CALLS")" = 3 ]
[ "$(grep -c 'PublicIp' "$CALLS")" = 1 ]

[ "$(_ensure_lightsail_static_ip_attachment node-current static-current)" = 203.0.113.32 ]
[ "$(grep -c '^aws lightsail attach-static-ip' "$CALLS")" = 1 ]
[ "$(grep -c 'attachedTo' "$CALLS")" = 3 ]
[ "$(grep -c 'ipAddress' "$CALLS")" = 1 ]

# A mutation request that never becomes observable must fail closed without
# returning/reading a public IP.
before_public=$(grep -c 'PublicIp\|ipAddress' "$CALLS")
if _ensure_ec2_eip_attachment i-never eipalloc-never >/dev/null 2>&1; then
  echo "EC2 reconciliation must fail when ownership never converges" >&2
  exit 1
fi
if _ensure_lightsail_static_ip_attachment node-never static-never >/dev/null 2>&1; then
  echo "Lightsail reconciliation must fail when ownership never converges" >&2
  exit 1
fi
after_public=$(grep -c 'PublicIp\|ipAddress' "$CALLS")
[ "$before_public" = "$after_public" ]

echo "s3 stable IP reconciliation ok"
