#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export CALLS="$tmp/calls"
: > "$CALLS"
cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf 'aws' >> "$CALLS"; printf ' %q' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"
case "${1:-} ${2:-}" in
  "ssm get-parameters") printf 'ami-noble-test\n' ;;
  *) exit 90 ;;
esac
EOF
chmod 0755 "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/aws.sh"
[ "$(aws_lookup_ubuntu_ami)" = ami-noble-test ]
grep -q '/ubuntu/server/24\.04/stable/current/amd64/' "$CALLS"
if grep -q '22\.04\|jammy\|arm64' "$ROOT/scripts/lib/aws.sh"; then
  echo "AWS host selection retained an unsupported platform" >&2
  exit 1
fi

unset DEFAULT_LIGHTSAIL_BLUEPRINT_ID
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"
[ "$DEFAULT_LIGHTSAIL_BLUEPRINT_ID" = ubuntu_24_04 ]
if [ -f "$ROOT/scripts/updater/build.sh" ] || { [ -d "$ROOT/updater" ] && find "$ROOT/updater" -type f -print -quit | grep -q .; }; then
  echo "deployer package still owns updater Go source/build logic" >&2
  exit 1
fi

echo "updater platform contract ok"
