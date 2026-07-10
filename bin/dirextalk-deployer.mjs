#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageJson = JSON.parse(readFileSync(path.join(packageRoot, "package.json"), "utf8"));
const packageName = packageJson.name || "dirextalk-deployer";
const packageVersion = packageJson.version || "0.0.0";

const skillFiles = [
  "AGENTS.md",
  "LICENSE",
  "README.md",
  "README_zh.md",
  "SKILL.md",
  "agents",
  "bin",
  "package.json",
  "references",
  "scripts"
];

const projectTargets = {
  acp: [".agents", "skills", "dirextalk-deployer"],
  antigravity: [".antigravity", "skills", "dirextalk-deployer"],
  claudecode: [".claude", "skills", "dirextalk-deployer"],
  codex: [".codex", "skills", "dirextalk-deployer"],
  copilot: [".github", "copilot", "skills", "dirextalk-deployer"],
  cursor: [".cursor", "skills", "dirextalk-deployer"],
  devin: [".devin", "skills", "dirextalk-deployer"],
  gemini: [".gemini", "skills", "dirextalk-deployer"],
  hermes: [".hermes", "skills", "dirextalk-deployer"],
  iflow: [".iflow", "skills", "dirextalk-deployer"],
  kimi: [".kimi", "skills", "dirextalk-deployer"],
  opencode: [".opencode", "skills", "dirextalk-deployer"],
  openclaw: [".openclaw", "skills", "dirextalk-deployer"],
  pi: [".pi", "agent", "skills", "dirextalk-deployer"],
  qoder: [".qoder", "skills", "dirextalk-deployer"],
  reasonix: [".reasonix", "skills", "dirextalk-deployer"],
  tmux: [".agent", "skills", "dirextalk-deployer"],
  generic: [".agent", "skills", "dirextalk-deployer"],
  unknown: [".agent", "skills", "dirextalk-deployer"]
};

const globalTargets = {
  acp: { env: null, defaultSegments: [".agents", "skills", "dirextalk-deployer"] },
  antigravity: { env: "ANTIGRAVITY_HOME", defaultSegments: [".antigravity", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  claudecode: { env: "CLAUDE_HOME", defaultSegments: [".claude", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  codex: { env: "CODEX_HOME", defaultSegments: [".codex", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  copilot: { env: null, defaultSegments: [".github", "copilot", "skills", "dirextalk-deployer"] },
  cursor: { env: "CURSOR_HOME", defaultSegments: [".cursor", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  devin: { env: "DEVIN_HOME", defaultSegments: [".devin", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  gemini: { env: "GEMINI_HOME", defaultSegments: [".gemini", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  hermes: { env: "HERMES_HOME", defaultSegments: [".hermes", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  iflow: { env: "IFLOW_HOME", defaultSegments: [".iflow", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  kimi: { env: "KIMI_HOME", defaultSegments: [".kimi", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  opencode: { env: "OPENCODE_HOME", defaultSegments: [".opencode", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  openclaw: { env: "OPENCLAW_HOME", defaultSegments: [".openclaw", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  pi: { env: "PI_CODING_AGENT_DIR", defaultSegments: [".pi", "agent", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  qoder: { env: "QODER_HOME", defaultSegments: [".qoder", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  reasonix: { env: "REASONIX_HOME", defaultSegments: [".reasonix", "skills", "dirextalk-deployer"], envSuffix: ["skills", "dirextalk-deployer"] },
  tmux: { env: null, defaultSegments: [".agent", "skills", "dirextalk-deployer"] },
  generic: { env: null, defaultSegments: [".agent", "skills", "dirextalk-deployer"] },
  unknown: { env: null, defaultSegments: [".agent", "skills", "dirextalk-deployer"] }
};

const aliases = {
  "claude": "claudecode",
  "claude-code": "claudecode",
  "open-code": "opencode",
  "qodercli": "qoder",
  "agy": "antigravity"
};

main();

function main() {
  const [area, command, ...rawArgs] = process.argv.slice(2);
  if (!area || area === "--help" || area === "-h") usage(0);
  if (area === "--version" || area === "-v") {
    console.log(packageVersion);
    return;
  }
  if (area !== "skill") usage(1);
  if (!["install", "update", "refresh"].includes(command)) usage(1);

  const options = parseArgs(rawArgs);
  const result = runSkillCommand(command, options);
  console.log(JSON.stringify(result, null, 2));
}

function usage(exitCode) {
  const output = `Usage:
  dirextalk-deployer skill install --agent <runtime> [--scope global|project] [--project <path>]
  dirextalk-deployer skill update --agent <runtime> [--scope global|project] [--project <path>]
  dirextalk-deployer skill refresh --agent <runtime> [--scope global|project] [--project <path>]

Options:
  --agent <runtime>   Target agent runtime. Default: codex
  --scope <scope>     global or project. Default: global
  --project <path>    Project root for explicit project installs. Default: current directory
  --target <path>     Explicit install target override
  --home <path>       Home directory override for global installs
  --dry-run           Resolve and print without writing
  --force             Replace an unmanaged existing target
`;
  const stream = exitCode === 0 ? process.stdout : process.stderr;
  stream.write(output);
  process.exit(exitCode);
}

function parseArgs(args) {
  const options = {
    agent: "codex",
    scope: "global",
    project: process.cwd(),
    home: homedir(),
    target: null,
    dryRun: false,
    force: false,
    skipNpmCheck: process.env.DIREXTALK_DEPLOYER_REFRESH_CHILD === "1"
  };

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
      case "--agent":
        options.agent = requiredValue(args, ++i, arg);
        break;
      case "--scope":
        options.scope = requiredValue(args, ++i, arg);
        break;
      case "--project":
        options.project = requiredValue(args, ++i, arg);
        break;
      case "--home":
        options.home = requiredValue(args, ++i, arg);
        break;
      case "--target":
        options.target = requiredValue(args, ++i, arg);
        break;
      case "--dry-run":
        options.dryRun = true;
        break;
      case "--force":
        options.force = true;
        break;
      case "--skip-npm-check":
        options.skipNpmCheck = true;
        break;
      default:
        throwUserError(`unknown option: ${arg}`);
    }
  }

  return options;
}

function requiredValue(args, index, flag) {
  const value = args[index];
  if (!value || value.startsWith("--")) throwUserError(`${flag} requires a value`);
  return value;
}

function runSkillCommand(command, options) {
  const agent = normalizeAgent(options.agent);
  const scope = normalizeScope(options.scope);
  const target = options.target
    ? path.resolve(options.target)
    : resolveTarget({ agent, scope, project: options.project, home: options.home });

  const base = {
    command,
    package: packageName,
    version: packageVersion,
    agent,
    scope,
    target,
    dryRun: options.dryRun
  };

  if (command === "refresh") {
    const freshness = checkFreshness(options);
    if (options.dryRun) return { ...base, freshness };
    if (freshness.updateCommand) runNpmUpdateAndChildInstall({ agent, scope, target, options, freshness });
    return { ...base, freshness, installed: installSkill({ agent, scope, target, dryRun: false, force: options.force }) };
  }

  return { ...base, installed: installSkill({ agent, scope, target, dryRun: options.dryRun, force: options.force }) };
}

function normalizeAgent(agent) {
  const normalized = aliases[String(agent).toLowerCase()] || String(agent).toLowerCase();
  if (!projectTargets[normalized]) {
    const supported = Object.keys(projectTargets).filter((name) => name !== "unknown").join(", ");
    throwUserError(`agent must be one of: ${supported}`);
  }
  return normalized;
}

function normalizeScope(scope) {
  if (scope !== "project" && scope !== "global") throwUserError("scope must be project or global");
  return scope;
}

function resolveTarget({ agent, scope, project, home }) {
  if (scope === "project") return path.resolve(project, ...projectTargets[agent]);
  const entry = globalTargets[agent];
  const configuredHome = entry.env ? process.env[entry.env] : null;
  if (configuredHome) {
    const suffix = entry.envSuffix || entry.defaultSegments;
    return path.resolve(configuredHome, ...suffix);
  }
  return path.resolve(home, ...entry.defaultSegments);
}

function installSkill({ agent, scope, target, dryRun, force }) {
  if (dryRun) return { action: "would-install", fileCount: skillFiles.length };

  let action = "installed";
  if (existsSync(target)) {
    const entries = readdirSync(target);
    const managed = isManagedTarget(target);
    if (entries.length > 0 && !managed && !force) {
      throwUserError(`refusing to overwrite unmanaged target: ${target}. Re-run with --force if this is intentional.`);
    }
    if (removeInstallTarget(target) === "in-place") action = "installed-in-place";
  }

  mkdirSync(target, { recursive: true });
  for (const relative of skillFiles) {
    const source = path.join(packageRoot, relative);
    if (!existsSync(source)) continue;
    copyRecursive(source, path.join(target, relative));
  }

  const manifest = {
    package: packageName,
    version: packageVersion,
    agent,
    scope,
    source: packageRoot,
    installedAt: new Date().toISOString()
  };
  writeFileSync(path.join(target, ".dirextalk-skill-install.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return { action, manifest: path.join(target, ".dirextalk-skill-install.json") };
}

function removeInstallTarget(target) {
  try {
    if (process.env.DIREXTALK_DEPLOYER_TEST_RM_EBUSY === "1") {
      const error = new Error(`simulated busy target: ${target}`);
      error.code = "EBUSY";
      throw error;
    }
    rmSync(target, { recursive: true, force: true });
    return "removed";
  } catch (error) {
    if (!isBusyRemovalError(error)) throw error;
    clearTargetContents(target);
    return "in-place";
  }
}

function clearTargetContents(target) {
  for (const entry of readdirSync(target)) {
    rmSync(path.join(target, entry), { recursive: true, force: true });
  }
}

function isBusyRemovalError(error) {
  return process.platform === "win32" || process.env.DIREXTALK_DEPLOYER_TEST_RM_EBUSY === "1"
    ? ["EBUSY", "EPERM", "ENOTEMPTY"].includes(error?.code)
    : false;
}

function isManagedTarget(target) {
  const manifestPath = path.join(target, ".dirextalk-skill-install.json");
  if (!existsSync(manifestPath)) return false;
  try {
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    return manifest.package === packageName;
  } catch {
    return false;
  }
}

function copyRecursive(source, destination) {
  const stat = statSync(source);
  if (stat.isDirectory()) {
    mkdirSync(destination, { recursive: true });
    for (const entry of readdirSync(source)) {
      if (shouldSkip(entry)) continue;
      copyRecursive(path.join(source, entry), path.join(destination, entry));
    }
    return;
  }
  mkdirSync(path.dirname(destination), { recursive: true });
  copyFileSync(source, destination);
}

function shouldSkip(entry) {
  return new Set([
    ".dirextalk-connect",
    ".codegraph",
    ".dirextalk-skill-install.json",
    ".git",
    ".idea",
    "node_modules"
  ]).has(entry);
}

function checkFreshness(options) {
  if (options.skipNpmCheck) return { status: "skipped", reason: "child refresh install" };
  if (options.dryRun) {
    return {
      status: "dry-run",
      currentVersion: packageVersion,
      latestVersion: null,
      updateCommand: null
    };
  }
  const npmView = spawnSync("npm", ["view", `${packageName}@latest`, "version"], {
    encoding: "utf8",
    shell: process.platform === "win32"
  });
  if (npmView.status !== 0) {
    return {
      status: "unavailable",
      currentVersion: packageVersion,
      latestVersion: null,
      reason: (npmView.stderr || npmView.stdout || "npm view failed").trim()
    };
  }
  const latestVersion = npmView.stdout.trim();
  if (!isNewerVersion(latestVersion, packageVersion)) {
    return { status: "current", currentVersion: packageVersion, latestVersion, updateCommand: null };
  }
  return {
    status: "update-available",
    currentVersion: packageVersion,
    latestVersion,
    updateCommand: `npm install -g ${packageName}@latest`
  };
}

function runNpmUpdateAndChildInstall({ agent, scope, target, options, freshness }) {
  const installResult = spawnSync("npm", ["install", "-g", `${packageName}@latest`], {
    stdio: "inherit",
    shell: process.platform === "win32"
  });
  if (installResult.status !== 0) {
    throwUserError(`npm update failed for ${packageName}@latest`);
  }

  const childArgs = [
    "skill",
    "update",
    "--agent",
    agent,
    "--scope",
    scope,
    "--target",
    target,
    "--skip-npm-check"
  ];
  if (options.force) childArgs.push("--force");
  const child = spawnSync("dirextalk-deployer", childArgs, {
    env: { ...process.env, DIREXTALK_DEPLOYER_REFRESH_CHILD: "1" },
    stdio: "inherit",
    shell: process.platform === "win32"
  });
  if (child.status === 0) process.exit(0);
  freshness.childRefresh = "failed; falling back to current package copy";
}

function isNewerVersion(candidate, current) {
  const left = parseVersion(candidate);
  const right = parseVersion(current);
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    const a = left[i] || 0;
    const b = right[i] || 0;
    if (a > b) return true;
    if (a < b) return false;
  }
  return false;
}

function parseVersion(version) {
  return String(version)
    .replace(/^v/, "")
    .split(/[.-]/)
    .map((part) => Number.parseInt(part, 10))
    .filter((part) => Number.isFinite(part));
}

function throwUserError(message) {
  console.error(message);
  process.exit(1);
}
