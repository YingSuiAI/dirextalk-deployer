#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

node_bin=$(command -v node || command -v node.exe)
export NODE="$node_bin"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

for arg in "$@"; do
  case "$arg" in
    *public.example.test*)
      printf '{"Status":0,"Answer":[{"name":"public.example.test.","type":1,"TTL":60,"data":"203.0.113.90"}]}\n'
      exit 0
      ;;
  esac
done

printf '{"Status":3}\n'
EOF
chmod 700 "$fakebin/curl"
export CALLS="$tmp/curl.calls"
export PATH="$fakebin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/json.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/domain.sh"

domain_authoritative_resolves_to_ip() { return 1; }
if domain_resolves_to_ip public.example.test 203.0.113.90; then
  echo "DoH fallback must not override an authoritative DNS IP mismatch" >&2
  exit 1
fi
if [ -s "$CALLS" ]; then
  echo "DoH fallback should not run after an authoritative DNS mismatch" >&2
  cat "$CALLS" >&2
  exit 1
fi

domain_authoritative_resolves_to_ip() { return 2; }
domain_resolves_to_ip public.example.test 203.0.113.90
grep -q 'cloudflare-dns.com' "$CALLS" || { cat "$CALLS" >&2; exit 1; }

echo "domain public doh ok"
