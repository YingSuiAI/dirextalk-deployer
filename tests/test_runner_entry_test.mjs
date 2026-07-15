import assert from "node:assert/strict";

import { buildTestInvocation, runTestSuite } from "../scripts/lib/test-runner.mjs";

assert.deepEqual(buildTestInvocation("quick"), {
  command: "bash",
  args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh"],
});
assert.deepEqual(buildTestInvocation("extended"), {
  command: "bash",
  args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh", "extended"],
});
assert.deepEqual(buildTestInvocation("extended-only"), {
  command: "bash",
  args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh", "extended-only"],
});
assert.deepEqual(buildTestInvocation("release"), {
  command: "bash",
  args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh", "release"],
});
assert.deepEqual(buildTestInvocation("release-only"), {
  command: "bash",
  args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh", "release-only"],
});
assert.throws(() => buildTestInvocation("unexpected"), /unsupported test mode/);

const calls = [];
runTestSuite({
  mode: "quick",
  platform: "win32",
  env: { DIREXTALK_GIT_BASH: "C:\\Tools\\Git\\bin\\bash.exe" },
  root: "C:\\repo",
  exists: (candidate) => candidate === "C:\\Tools\\Git\\bin\\bash.exe",
  spawn(command, args, options) {
    calls.push({ command, args, options });
    return { status: 0 };
  },
});
assert.deepEqual(calls, [{
  command: "C:\\Tools\\Git\\bin\\bash.exe",
  args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh"],
  options: { cwd: "C:\\repo", stdio: "inherit", shell: false },
}]);
assert.doesNotMatch(JSON.stringify(calls), /wsl(?:\.exe)?/i, "Windows tests must never invoke WSL");

assert.throws(() => runTestSuite({
  platform: "win32",
  env: {},
  exists: () => false,
  spawn() { throw new Error("must not spawn without Git Bash"); },
}), /Git for Windows Bash/);

assert.throws(() => runTestSuite({
  platform: "linux",
  spawn() { return { status: 23 }; },
}), (error) => error?.exitCode === 23);

console.log("npm test runner entry ok");
