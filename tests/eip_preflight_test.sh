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
  "ec2 describe-vpcs")
    printf 'vpc-preflight\n'
    ;;
  "service-quotas get-service-quota")
    case "$*" in
      *L-1216C47A*) printf '8.0\n' ;;
      *L-0263D0A3*) printf '5.0\n' ;;
      *) echo "unexpected quota command: $*" >&2; exit 1 ;;
    esac
    ;;
  "ec2 describe-addresses")
    printf '5\n'
    ;;
  "ssm get-parameters")
    printf 'ami-preflight\n'
    ;;
  "configure get")
    printf 'ap-northeast-1\n'
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fakebin/aws"
export PATH="$fakebin:$PATH"
export AWS_DEFAULT_REGION=ap-northeast-1
export DIREXTALK_CLOUD_PROVIDER=ec2

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s1_preflight.sh"

set +e
run_phase > "$tmp/preflight.out" 2>&1
rc=$?
set -e

[ "$rc" -eq 2 ] || {
  echo "S1 should wait before provisioning when EIP quota is exhausted" >&2
  cat "$tmp/preflight.out" >&2
  exit 1
}
grep -q 'no available Elastic IP quota' "$tmp/preflight.out"
json_test_check "$STATE_JSON" "data.phases.S1_PREFLIGHT.status === 'waiting_user' && data.resources.eip_quota === '5.0' && data.resources.eip_allocated === '5' && data.resources.eip_available === '0'"

echo "eip preflight ok"
