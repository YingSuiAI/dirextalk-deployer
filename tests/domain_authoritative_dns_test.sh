#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "+short" ] && [ "${2:-}" = "A" ] && [ "${3:-}" = "app.example.test" ]; then
  printf '203.0.113.88\n'
  exit 0
fi

if [ "${1:-}" = "+short" ] && [ "${2:-}" = "NS" ] && [ "${3:-}" = "app.example.test" ]; then
  exit 0
fi

if [ "${1:-}" = "+short" ] && [ "${2:-}" = "NS" ] && [ "${3:-}" = "example.test" ]; then
  printf 'ns1.example.test.\n'
  exit 0
fi

if [ "${1:-}" = "+short" ] && [ "${2:-}" = "@ns1.example.test" ] && [ "${3:-}" = "A" ] && [ "${4:-}" = "app.example.test" ]; then
  printf '%s\n' "${AUTHORITATIVE_A:-198.51.100.10}"
  exit 0
fi

echo "unexpected dig call: $*" >&2
exit 1
EOF
chmod 700 "$fakebin/dig"

PATH="$fakebin:$PATH"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/domain.sh"

if AUTHORITATIVE_A=198.51.100.10 domain_resolves_to_ip app.example.test 203.0.113.88; then
  echo "recursive DNS alone must not pass when authoritative DNS still points at a different IP" >&2
  exit 1
fi

AUTHORITATIVE_A=203.0.113.88 domain_resolves_to_ip app.example.test 203.0.113.88

echo "domain authoritative dns ok"
