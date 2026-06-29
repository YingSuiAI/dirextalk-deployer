#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export P2P_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$P2P_WORKDIR"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "ec2 describe-instances")
    printf 'vol-root-test\n'
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fakebin/aws"
export PATH="$fakebin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

_record_root_volume_id i-root-test

jq -e '.resources.root_volume_id == "vol-root-test"' "$STATE_JSON" >/dev/null

echo "root volume tracking ok"
