#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DIREXTALK_WORKDIR="$tmp/work"
mkdir -p "$DIREXTALK_WORKDIR" "$tmp/scripts/updater" "$tmp/bin"

cat > "$tmp/scripts/updater/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ $# -gt 0 ]; do
  case "$1" in --output) output=$2; shift 2 ;; *) shift ;; esac
done
count=0
[ -f "$BUILD_COUNT" ] && count=$(cat "$BUILD_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$BUILD_COUNT"
printf '#!/bin/sh\nprintf %s\n' "$count" > "$output"
chmod 0755 "$output"
printf '%s\n' "$output" >> "$BUILD_OUTPUTS"
EOF
chmod 0755 "$tmp/scripts/updater/build.sh"
cat > "$tmp/bin/go" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "env GOOS") printf 'linux\n' ;;
  "env GOARCH") printf 'amd64\n' ;;
  *) exit 90 ;;
esac
EOF
chmod 0755 "$tmp/bin/go"
export PATH="$tmp/bin:$PATH"
export BUILD_COUNT="$tmp/build.count" BUILD_OUTPUTS="$tmp/build.outputs"

warn() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/server-release.sh"
SERVER_RELEASE_SCRIPTS_DIR="$tmp/scripts"

first=$(server_release_updater_binary)
second=$(server_release_updater_binary)
[ "$first" = "$second" ]
[ "$(cat "$BUILD_COUNT")" = 2 ] || { echo "Linux updater must rebuild for current source" >&2; exit 1; }
[ "$("$second")" = 2 ]

: > "$BUILD_COUNT"
: > "$BUILD_OUTPUTS"
first=$(server_release_resolver_binary)
second=$(server_release_resolver_binary)
[ "$first" = "$second" ]
[ "$(cat "$BUILD_COUNT")" = 2 ] || { echo "host resolver must rebuild for current source" >&2; exit 1; }
[ "$("$second")" = 2 ]
if grep -Fx -q "$first" "$BUILD_OUTPUTS"; then
  echo "builders must write a temporary file and atomically replace the final binary" >&2
  exit 1
fi

echo "updater binaries rebuild atomically ok"
