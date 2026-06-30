#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

assert_file_exists() {
  [ -f "$1" ] || {
    echo "missing expected file: $1" >&2
    exit 1
  }
}

assert_contains() {
  local path=$1 pattern=$2
  grep -q "$pattern" "$path" || {
    echo "expected $path to contain: $pattern" >&2
    exit 1
  }
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

NODE_BIN=${NODE:-node}

"$NODE_BIN" -e '
const pkg = require("./package.json");
if (pkg.name !== "direxio-deployer") throw new Error("unexpected package name");
if (!pkg.bin || pkg.bin["direxio-deployer"] !== "bin/direxio-deployer.mjs") {
  throw new Error("missing direxio-deployer bin");
}
'

project="$tmp/project"
mkdir -p "$project"

"$NODE_BIN" bin/direxio-deployer.mjs skill install --agent codex --scope project --project "$project" > "$tmp/install.out"
target="$project/.codex/skills/direxio-deployer"
assert_file_exists "$target/SKILL.md"
assert_file_exists "$target/references/agent-targets.md"
assert_file_exists "$target/scripts/orchestrate.sh"
assert_file_exists "$target/.direxio-skill-install.json"
assert_contains "$target/.direxio-skill-install.json" '"agent": "codex"'
assert_contains "$target/.direxio-skill-install.json" '"scope": "project"'

printf 'stale\n' > "$target/STALE.txt"
"$NODE_BIN" bin/direxio-deployer.mjs skill update --agent codex --scope project --project "$project" > "$tmp/update.out"
if [ -f "$target/STALE.txt" ]; then
  echo "managed update should replace stale target contents" >&2
  exit 1
fi

unmanaged_project="$tmp/unmanaged"
mkdir -p "$unmanaged_project/.codex/skills/direxio-deployer"
printf 'manual\n' > "$unmanaged_project/.codex/skills/direxio-deployer/manual.txt"
if "$NODE_BIN" bin/direxio-deployer.mjs skill install --agent codex --scope project --project "$unmanaged_project" >"$tmp/unmanaged.out" 2>"$tmp/unmanaged.err"; then
  echo "unmanaged install should require --force" >&2
  exit 1
fi
assert_contains "$tmp/unmanaged.err" 'refusing to overwrite unmanaged target'

"$NODE_BIN" bin/direxio-deployer.mjs skill install --agent codex --scope project --project "$unmanaged_project" --force > "$tmp/force.out"
assert_file_exists "$unmanaged_project/.codex/skills/direxio-deployer/SKILL.md"
if [ -f "$unmanaged_project/.codex/skills/direxio-deployer/manual.txt" ]; then
  echo "forced install should replace unmanaged contents" >&2
  exit 1
fi

"$NODE_BIN" bin/direxio-deployer.mjs skill install --agent gemini --scope global --home "$tmp/home" --dry-run > "$tmp/dry-run.out"
assert_contains "$tmp/dry-run.out" '"dryRun": true'
assert_contains "$tmp/dry-run.out" '.gemini'
if [ -e "$tmp/home/.gemini" ]; then
  echo "dry-run should not create global target directories" >&2
  exit 1
fi

PI_CODING_AGENT_DIR="$tmp/pi-agent-root" "$NODE_BIN" bin/direxio-deployer.mjs skill install --agent pi --scope global --dry-run > "$tmp/pi-global.out"
assert_contains "$tmp/pi-global.out" 'pi-agent-root'
assert_contains "$tmp/pi-global.out" 'skills'
if grep -q 'pi-agent-root.*/agent/skills' "$tmp/pi-global.out"; then
  echo "PI_CODING_AGENT_DIR already points at the agent root and must not append another agent segment" >&2
  exit 1
fi

custom_target="$tmp/custom target/skill"
"$NODE_BIN" bin/direxio-deployer.mjs skill install --agent codex --target "$custom_target" > "$tmp/custom-target.out"
assert_file_exists "$custom_target/SKILL.md"
assert_file_exists "$custom_target/.direxio-skill-install.json"

"$NODE_BIN" bin/direxio-deployer.mjs skill refresh --agent codex --scope project --project "$project" --dry-run > "$tmp/refresh.out"
assert_contains "$tmp/refresh.out" '"command": "refresh"'
assert_contains "$tmp/refresh.out" '"target"'

echo "npm skill distribution ok"
