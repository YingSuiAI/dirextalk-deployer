#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR"

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

json_test_check "$STATE_JSON" "data.resources.root_volume_id === 'vol-root-test'"

echo "root volume tracking ok"
