#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"
# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"
: "${DIREXTALK_TEST_ROOT:?run this test through tests/lib/run_isolated.sh}"
dirextalk_test_assert_isolated_homes "$DIREXTALK_TEST_ROOT"

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

tmp=$(mktemp -d "$DIREXTALK_TEST_ROOT/npm-skill-distribution.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export CODEX_HOME="$tmp/home/.codex"
export GEMINI_HOME="$tmp/home2/.gemini"
dirextalk_test_assert_isolated_homes "$DIREXTALK_TEST_ROOT"

NODE_BIN=$(json_node)
export PATH="$(dirname "$NODE_BIN"):$PATH"

"$NODE_BIN" -e '
const pkg = require("./package.json");
if (pkg.name !== "dirextalk-deployer") throw new Error("unexpected package name");
if (!pkg.bin || pkg.bin["dirextalk-deployer"] !== "bin/dirextalk-deployer.mjs") {
  throw new Error("missing dirextalk-deployer bin");
}
'

npm pack --dry-run --json > "$tmp/pack.json"
"$NODE_BIN" - "$tmp/pack.json" <<'NODE'
const fs = require("node:fs");
const pack = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))[0];
const files = pack.files.map((entry) => entry.path);
for (const required of ["SKILL.md", "bin/dirextalk-deployer.mjs", "scripts/json.mjs", "scripts/orchestrate.sh"]) {
  if (!files.includes(required)) throw new Error(`missing package file: ${required}`);
}
if (files.some((file) => file === "tests" || file.startsWith("tests/"))) {
  throw new Error("npm package must not include tests/");
}
NODE

project="$tmp/project"
mkdir -p "$project"

"$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --home "$tmp/home" > "$tmp/default-global.out"
global_target="$tmp/home/.codex/skills/dirextalk-deployer"
assert_file_exists "$global_target/SKILL.md"
assert_file_exists "$global_target/.dirextalk-skill-install.json"
assert_contains "$global_target/.dirextalk-skill-install.json" '"scope": "global"'

"$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --scope project --project "$project" > "$tmp/install.out"
target="$project/.codex/skills/dirextalk-deployer"
assert_file_exists "$target/SKILL.md"
assert_file_exists "$target/references/agent-targets.md"
assert_file_exists "$target/scripts/orchestrate.sh"
assert_file_exists "$target/.dirextalk-skill-install.json"
[ ! -e "$target/tests" ] || {
  echo "installed skill should not include tests/" >&2
  exit 1
}
assert_contains "$target/.dirextalk-skill-install.json" '"agent": "codex"'
assert_contains "$target/.dirextalk-skill-install.json" '"scope": "project"'

printf 'stale\n' > "$target/STALE.txt"
"$NODE_BIN" bin/dirextalk-deployer.mjs skill update --agent codex --scope project --project "$project" > "$tmp/update.out"
if [ -f "$target/STALE.txt" ]; then
  echo "managed update should replace stale target contents" >&2
  exit 1
fi

printf 'busy stale\n' > "$target/STALE_BUSY.txt"
DIREXTALK_DEPLOYER_TEST_RM_EBUSY=1 "$NODE_BIN" bin/dirextalk-deployer.mjs skill update --agent codex --scope project --project "$project" > "$tmp/update-busy.out"
assert_file_exists "$target/SKILL.md"
assert_contains "$tmp/update-busy.out" 'installed-in-place'
if [ -f "$target/STALE_BUSY.txt" ]; then
  echo "managed update should clear stale files when root removal is busy" >&2
  exit 1
fi

unmanaged_project="$tmp/unmanaged"
mkdir -p "$unmanaged_project/.codex/skills/dirextalk-deployer"
printf 'manual\n' > "$unmanaged_project/.codex/skills/dirextalk-deployer/manual.txt"
if "$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --scope project --project "$unmanaged_project" >"$tmp/unmanaged.out" 2>"$tmp/unmanaged.err"; then
  echo "unmanaged install should require --force" >&2
  exit 1
fi
assert_contains "$tmp/unmanaged.err" 'refusing to overwrite unmanaged target'

"$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --scope project --project "$unmanaged_project" --force > "$tmp/force.out"
assert_file_exists "$unmanaged_project/.codex/skills/dirextalk-deployer/SKILL.md"
if [ -f "$unmanaged_project/.codex/skills/dirextalk-deployer/manual.txt" ]; then
  echo "forced install should replace unmanaged contents" >&2
  exit 1
fi

"$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent gemini --home "$tmp/home2" --dry-run > "$tmp/dry-run.out"
assert_contains "$tmp/dry-run.out" '"dryRun": true'
assert_contains "$tmp/dry-run.out" '.gemini'
if [ -e "$tmp/home2/.gemini" ]; then
  echo "dry-run should not create global target directories" >&2
  exit 1
fi

PI_CODING_AGENT_DIR="$tmp/pi-agent-root" "$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent pi --scope global --dry-run > "$tmp/pi-global.out"
assert_contains "$tmp/pi-global.out" 'pi-agent-root'
assert_contains "$tmp/pi-global.out" 'skills'
if grep -q 'pi-agent-root.*/agent/skills' "$tmp/pi-global.out"; then
  echo "PI_CODING_AGENT_DIR already points at the agent root and must not append another agent segment" >&2
  exit 1
fi

custom_target="$tmp/custom target/skill"
"$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --target "$custom_target" > "$tmp/custom-target.out"
assert_file_exists "$custom_target/SKILL.md"
assert_file_exists "$custom_target/.dirextalk-skill-install.json"

"$NODE_BIN" bin/dirextalk-deployer.mjs skill refresh --agent codex --home "$tmp/home" --dry-run > "$tmp/refresh.out"
assert_contains "$tmp/refresh.out" '"command": "refresh"'
assert_contains "$tmp/refresh.out" '"target"'

echo "npm skill distribution ok"
