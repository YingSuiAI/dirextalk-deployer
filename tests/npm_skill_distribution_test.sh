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
NODE_DIR=$(dirname "$NODE_BIN")
case "$(uname -s 2>/dev/null || printf unknown)" in
  *MINGW*|*MSYS*|*CYGWIN*) NODE_DIR=$(cygpath -u "$NODE_DIR") ;;
esac
export PATH="$NODE_DIR:$PATH"

# Native WSL runs Linux Node.js and follows the normal POSIX skill path. Merely
# exporting WSL variables inside Git Bash does not turn Windows Node.js into a
# WSL process, so exercise this contract only on Linux hosts (including WSL).
case "$(uname -s 2>/dev/null || printf unknown)" in
  Linux*)
    for skill_command in install update refresh; do
      wsl_home="$tmp/wsl-$skill_command"
      WSL_INTEROP=1 WSL_DISTRO_NAME=Ubuntu "$NODE_BIN" bin/dirextalk-deployer.mjs skill "$skill_command" --agent codex --home "$wsl_home" --dry-run >"$tmp/wsl-$skill_command.out" 2>"$tmp/wsl-$skill_command.err" || {
        echo "skill $skill_command must accept native WSL as a Linux host" >&2
        cat "$tmp/wsl-$skill_command.err" >&2
        exit 1
      }
      if [ -e "$wsl_home" ]; then
        echo "WSL dry-run must not create a skill target" >&2
        exit 1
      fi
    done
    ;;
esac

case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*)
    no_git_bin="$tmp/no-git-bin"
    mkdir "$no_git_bin"
    if PATH="$no_git_bin" "$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --home "$tmp/no-git-home" --dry-run >"$tmp/no-git.out" 2>"$tmp/no-git.err"; then
      echo "skill install must reject Git Bash without Git for Windows tools" >&2
      exit 1
    fi
    assert_contains "$tmp/no-git.err" 'Install Git for Windows'
    if EXEPATH='C:\msys64\usr\bin' "$NODE_BIN" bin/dirextalk-deployer.mjs skill install --agent codex --home "$tmp/not-git-bash-home" --dry-run >"$tmp/not-git-bash.out" 2>"$tmp/not-git-bash.err"; then
      echo "skill install must reject a MINGW shell outside the Git for Windows installation" >&2
      exit 1
    fi
    assert_contains "$tmp/not-git-bash.err" 'Git Bash only'
    ;;
esac

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
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const isRecord = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const normalizePackResult = (value) => {
  let results;
  if (Array.isArray(value)) {
    results = value;
  } else if (isRecord(value)) {
    const entries = Object.entries(value);
    if (entries.length !== 1 || !isRecord(entries[0][1]) || entries[0][1].name !== entries[0][0]) {
      throw new Error("npm pack must return exactly one package-name-keyed result");
    }
    results = [entries[0][1]];
  } else {
    throw new Error("npm pack returned an unsupported result shape");
  }
  if (results.length !== 1 || !isRecord(results[0]) || typeof results[0].name !== "string" || results[0].name.length === 0 || !Array.isArray(results[0].files) || results[0].files.length === 0) {
    throw new Error("npm pack must return exactly one valid result");
  }
  const result = results[0];
  if (!result.files.every((entry) => isRecord(entry) && typeof entry.path === "string" && entry.path.length > 0)) {
    throw new Error("npm pack result contains an invalid file entry");
  }
  return result;
};
const fixture = { name: "fixture", files: [{ path: "fixture.txt" }] };
if (normalizePackResult([fixture]) !== fixture || normalizePackResult({ fixture }) !== fixture) {
  throw new Error("npm pack result normalization failed");
}
for (const invalid of [null, [], [fixture, fixture], {}, { wrong: fixture }, { fixture, other: fixture }, fixture]) {
  try {
    normalizePackResult(invalid);
    throw new Error("npm pack result normalization accepted an invalid shape");
  } catch (error) {
    if (error.message === "npm pack result normalization accepted an invalid shape") throw error;
  }
}
const pack = normalizePackResult(payload);
const files = pack.files.map((entry) => entry.path);
for (const required of [
  "SKILL.md",
  "assets/dirextalk-platform.png",
  "bin/dirextalk-deployer.mjs",
  "scripts/json.mjs",
  "scripts/orchestrate.sh",
  "scripts/run-tests.mjs",
  "scripts/lib/test-runner.mjs",
  "scripts/lib/git-bash.sh",
  "scripts/lib/server-release.sh",
  "scripts/updater/release.env",
  "scripts/cloud-init/split/bootstrap-production.sh",
  "scripts/cloud-init/split/authorize-split-source-revision.sh",
  "scripts/cloud-init/split/advance-split-source-revision.sh",
  "scripts/cloud-init/split/production-ops-common.sh",
  "scripts/cloud-init/split/recover-production.sh",
  "scripts/cloud-init/split/reconcile-production.sh",
  "scripts/cloud-init/split/reset-production.sh",
  "scripts/cloud-init/split/dirextalk-split-recovery.service",
  "scripts/cloud-init/split/Caddyfile",
  "scripts/cloud-init/split/edge-compose.override.yaml",
  "scripts/cloud-init/split/release.env",
  "scripts/cloud-init/split/canonical-bundle.tar.gz",
  "scripts/cloud-init/split/canonical-bundle.tar.gz.sha256",
]) {
  if (!files.includes(required)) throw new Error(`missing package file: ${required}`);
}
if (files.includes("README_zh.md")) {
  throw new Error("npm package must not include the removed Chinese README");
}
if (files.some((file) => file.startsWith("scripts/connection-stack-v2/"))) {
  throw new Error("Connection Stack must not be distributed with dirextalk-deployer");
}
if (files.some((file) => file === "tests" || file.startsWith("tests/"))) {
  throw new Error("npm package must not include tests/");
}
if (files.some((file) => file.startsWith("scripts/cloud-init/split/runtime/"))) {
  throw new Error("npm package must not duplicate the canonical split runtime source");
}
if (files.some((file) => file.endsWith(".ps1"))) {
  throw new Error("Git-Bash-only deployer package must not include PowerShell wrappers");
}
for (const developmentOnly of ["references/bug-history.md", "references/deployment-optimization-audit.md"]) {
  if (files.includes(developmentOnly)) throw new Error(`npm skill package must exclude development-only reference: ${developmentOnly}`);
}
if (files.some((file) => file === "updater" || file.startsWith("updater/")) || files.includes("scripts/updater/build.sh")) {
  throw new Error("deployer package must not embed updater Go source/build logic");
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
assert_contains "$tmp/dry-run.out" '"fileCount": 9'
assert_contains "$tmp/dry-run.out" '.gemini'
if [ -e "$tmp/home2/.gemini" ]; then
  echo "dry-run should not create global target directories" >&2
  exit 1
fi

assert_contains "$ROOT/agents/openai.yaml" '^interface:$'
assert_contains "$ROOT/agents/openai.yaml" 'display_name: "Dirextalk Deployer"'
assert_contains "$ROOT/agents/openai.yaml" '^policy:$'
assert_contains "$ROOT/agents/openai.yaml" 'allow_implicit_invocation: true'

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
