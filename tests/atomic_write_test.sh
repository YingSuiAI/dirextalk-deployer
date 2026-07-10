#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"
dirextalk_test_isolate_homes "$tmp"

atomic_helper="$ROOT/scripts/lib/atomic-write.sh"
[ -f "$atomic_helper" ] || {
  echo "missing atomic write helper: $atomic_helper" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$atomic_helper"

render_value() {
  printf '%s\n' "$1"
}

target="$tmp/output/config.toml"
mkdir -p "$(dirname "$target")"
printf 'old\n' > "$target"
dirextalk_atomic_write "$target" 600 render_value replacement
[ "$(cat "$target")" = "replacement" ]
if find "$(dirname "$target")" -maxdepth 1 -name '.config.toml.tmp.*' | grep -q .; then
  echo "successful atomic write leaked a temporary file" >&2
  exit 1
fi

parent_file="$tmp/parent-file"
printf 'not a directory\n' > "$parent_file"
if dirextalk_atomic_write "$parent_file/config.toml" 600 render_value value 2>/dev/null; then
  echo "atomic write must propagate mkdir failure" >&2
  exit 1
fi

printf 'preserved\n' > "$target"
if dirextalk_atomic_write "$target" 600 false 2>/dev/null; then
  echo "atomic write must propagate renderer/write failure" >&2
  exit 1
fi
[ "$(cat "$target")" = "preserved" ]

mkdir -p "$tmp/chmod-fail-bin"
cat > "$tmp/chmod-fail-bin/chmod" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 700 "$tmp/chmod-fail-bin/chmod"
if PATH="$tmp/chmod-fail-bin:$PATH" dirextalk_atomic_write "$target" 600 render_value value 2>/dev/null; then
  echo "atomic write must propagate chmod failure" >&2
  exit 1
fi
[ "$(cat "$target")" = "preserved" ]

mkdir -p "$tmp/rename-fail-bin"
cat > "$tmp/rename-fail-bin/mv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 700 "$tmp/rename-fail-bin/mv"
if PATH="$tmp/rename-fail-bin:$PATH" dirextalk_atomic_write "$target" 600 render_value value 2>/dev/null; then
  echo "atomic write must propagate rename failure" >&2
  exit 1
fi
[ "$(cat "$target")" = "preserved" ]

mkdir -p "$tmp/directory-target"
if dirextalk_atomic_write "$tmp/directory-target" 600 render_value value 2>/dev/null; then
  echo "atomic write must reject a directory target" >&2
  exit 1
fi

echo "atomic write ok"
