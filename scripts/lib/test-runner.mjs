import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const moduleDir = dirname(fileURLToPath(import.meta.url));
const defaultRoot = resolve(moduleDir, "../..");

const modeArguments = new Map([
  ["quick", []],
  ["extended", ["extended"]],
  ["extended-only", ["extended-only"]],
]);

export function buildTestInvocation(mode = "quick") {
  const modeArgs = modeArguments.get(mode);
  if (!modeArgs) {
    throw new Error(`unsupported test mode: ${mode}`);
  }
  return {
    command: "bash",
    args: ["tests/lib/run_isolated.sh", "bash", "tests/npm_test_suite.sh", ...modeArgs],
  };
}

function gitBashCandidates(env) {
  const candidates = [];
  const add = (value) => {
    if (typeof value === "string" && value.trim() !== "") candidates.push(value.trim());
  };
  const addFromDirectory = (directory) => {
    if (typeof directory === "string" && directory.trim() !== "") add(join(directory.trim(), "bash.exe"));
  };

  add(env.DIREXTALK_GIT_BASH);
  addFromDirectory(env.EXEPATH);
  for (const programFiles of [env.ProgramW6432, env.ProgramFiles, env.PROGRAMFILES, env["ProgramFiles(x86)"], env.PROGRAMFILES_X86]) {
    if (typeof programFiles === "string" && programFiles.trim() !== "") {
      add(join(programFiles.trim(), "Git", "bin", "bash.exe"));
    }
  }
  return [...new Set(candidates)];
}

export function resolveTestShell({ platform = process.platform, env = process.env, exists = existsSync } = {}) {
  if (platform !== "win32") return "bash";
  for (const candidate of gitBashCandidates(env)) {
    if (exists(candidate)) return candidate;
  }
  throw new Error("Git for Windows Bash is required to run Dirextalk deployer tests on Windows. Install Git for Windows from https://git-scm.com/download/win or set DIREXTALK_GIT_BASH to its bash.exe path.");
}

export function runTestSuite({
  mode = "quick",
  platform = process.platform,
  env = process.env,
  exists = existsSync,
  root = defaultRoot,
  spawn = spawnSync,
} = {}) {
  const invocation = buildTestInvocation(mode);
  const shell = resolveTestShell({ platform, env, exists });
  const result = spawn(shell, invocation.args, { cwd: root, stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const error = new Error(`deployer test suite failed with exit code ${result.status ?? 1}`);
    error.exitCode = result.status ?? 1;
    throw error;
  }
}
