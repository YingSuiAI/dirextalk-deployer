import assert from "node:assert/strict";

import { buildTestInvocation, runTestSuite, selectAffectedTests } from "../scripts/lib/test-runner.mjs";

const wslAffected = selectAffectedTests([
  "scripts/lib/git-bash.sh",
  "bin/dirextalk-deployer.mjs",
  "SKILL.md",
]);
assert.deepEqual(wslAffected, [
  "tests/test_runner_entry_test.mjs",
  "tests/git_bash_windows_contract_test.sh",
  "tests/local_paths_test.sh",
  "tests/npm_skill_distribution_test.sh",
  "tests/skill_structure_test.sh",
  "tests/tracked_text_lf_test.sh",
]);
assert.doesNotMatch(wslAffected.join("\n"), /s6_|lightsail|legacy|updater_bundle/);

const releaseAffected = selectAffectedTests(["scripts/lib/git-bash.sh"], { release: true });
for (const required of [
  "tests/tracked_text_lf_test.sh",
  "tests/test_runner_entry_test.mjs",
  "tests/npm_skill_distribution_test.sh",
  "tests/skill_structure_test.sh",
  "tests/git_bash_windows_contract_test.sh",
  "tests/local_paths_test.sh",
]) {
  assert.ok(releaseAffected.includes(required), `release selection must include ${required}`);
}
assert.doesNotMatch(releaseAffected.join("\n"), /s6_|lightsail|legacy|updater_bundle/);

const s6Affected = selectAffectedTests(["scripts/phases/s6_wire_local.sh"]);
for (const required of [
  "tests/s6_run_phase_failure_test.sh",
  "tests/s6_wire_local_test.sh",
  "tests/mcp_tools_runtime_check_test.sh",
]) {
  assert.ok(s6Affected.includes(required), `S6 selection must include ${required}`);
}
assert.doesNotMatch(s6Affected.join("\n"), /legacy_adopt|root_volume_size/);

const affectedInvocation = buildTestInvocation("affected", {
  changedFiles: ["scripts/lib/git-bash.sh"],
});
assert.equal(affectedInvocation.command, "bash");
assert.deepEqual(affectedInvocation.args.slice(0, 2), [
  "tests/lib/run_isolated.sh",
  "tests/npm_test_suite.sh",
]);
assert.ok(affectedInvocation.args.includes("tests/git_bash_windows_contract_test.sh"));
assert.ok(!affectedInvocation.args.includes("tests/s6_wire_local_test.sh"));

const fullInvocation = buildTestInvocation("full");
assert.ok(fullInvocation.args.includes("tests/s6_run_phase_failure_test.sh::extended"));
assert.ok(fullInvocation.args.includes("tests/legacy_adopt_test.sh"));
const noGitInvocation = buildTestInvocation("affected", {
  root: "C:\\source-archive",
  env: {},
  spawn() { return { status: 1, stdout: "" }; },
});
assert.ok(noGitInvocation.args.includes("tests/atomic_write_test.sh"), "missing Git metadata must fall back to the quick safety lane");
assert.throws(() => buildTestInvocation("unexpected"), /unsupported test mode/);

const calls = [];
runTestSuite({
  mode: "affected",
  changedFiles: ["scripts/lib/git-bash.sh"],
  platform: "win32",
  env: { DIREXTALK_GIT_BASH: "C:\\Tools\\Git\\bin\\bash.exe" },
  root: "C:\\repo",
  exists: (candidate) => candidate === "C:\\Tools\\Git\\bin\\bash.exe",
  spawn(command, args, options) {
    calls.push({ command, args, options });
    return { status: 0 };
  },
});
assert.equal(calls.length, 1);
assert.equal(calls[0].command, "C:\\Tools\\Git\\bin\\bash.exe");
assert.deepEqual(calls[0].args.slice(0, 2), ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh"]);
assert.ok(calls[0].args.includes("tests/git_bash_windows_contract_test.sh"));
assert.deepEqual(calls[0].options, { cwd: "C:\\repo", stdio: "inherit", shell: false });
assert.doesNotMatch(JSON.stringify(calls), /wsl(?:\.exe)?/i, "Windows tests must never invoke WSL");

assert.throws(() => runTestSuite({
  platform: "win32",
  env: {},
  exists: () => false,
  spawn() { throw new Error("must not spawn without Git Bash"); },
}), /Git for Windows Bash/);

assert.throws(() => runTestSuite({
  mode: "quick",
  platform: "linux",
  spawn() { return { status: 23 }; },
}), (error) => error?.exitCode === 23);

console.log("npm affected test runner ok");
