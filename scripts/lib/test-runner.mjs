import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const moduleDir = dirname(fileURLToPath(import.meta.url));
const defaultRoot = resolve(moduleDir, "../..");

const runnerTest = "tests/test_runner_entry_test.mjs";
const packagingTests = [
  "tests/tracked_text_lf_test.sh",
  "tests/npm_skill_distribution_test.sh",
  "tests/skill_structure_test.sh",
];

const quickTests = [
  "tests/tracked_text_lf_test.sh",
  runnerTest,
  "tests/npm_skill_distribution_test.sh",
  "tests/skill_structure_test.sh",
  "tests/atomic_write_test.sh",
  "tests/json_helper_test.sh",
  "tests/local_paths_test.sh",
  "tests/git_bash_windows_contract_test.sh",
  "tests/private_file_permissions_test.sh",
  "tests/region_recommendation_test.sh",
  "tests/updater_platform_contract_test.sh",
  "tests/updater_atomic_install_test.sh",
];

const stageTests = [
  "tests/aws_credentials_test.sh",
  "tests/s3_lightsail_provision_test.sh",
  "tests/s5_init_tokens_test.sh",
  "tests/s6_run_phase_failure_test.sh",
  "tests/destroy_lightsail_test.sh",
  "tests/destroy_host_mcp_cleanup_test.sh",
  "tests/s7_http_mcp_acceptance_test.sh",
  "tests/operation_report_test.sh",
];

const slowTests = [
  "tests/s6_run_phase_failure_test.sh::extended",
  "tests/orchestrate_status_recovery_test.sh",
  "tests/orchestrate_region_env_test.sh",
  "tests/domain_dns_mode_detection_test.sh",
  "tests/domain_route53_default_test.sh",
  "tests/domain_authoritative_dns_test.sh",
  "tests/route53_zone_required_test.sh",
  "tests/s1_lightsail_availability_fallback_test.sh",
  "tests/lightsail_static_ip_quota_test.sh",
  "tests/eip_preflight_test.sh",
  "tests/root_volume_size_test.sh",
  "tests/s3_ec2_updater_upload_test.sh",
  "tests/s3_stable_ip_reconcile_test.sh",
  "tests/s3_public_ip_validation_test.sh",
  "tests/s3_updater_integration_migration_test.sh",
  "tests/legacy_adopt_test.sh",
  "tests/destroy_local_bridge_test.sh",
  "tests/destroy_root_identity_test.sh",
  "tests/server_release_test.sh",
  "tests/agent_runtime_contract_test.sh",
  "tests/agent_aws_control_reconcile_test.sh",
  "tests/agent_worker_control_reconcile_test.sh",
  "tests/agent_worker_control_privatelink_test.sh",
  "tests/agent_ecr_pull_test.sh",
  "tests/mcp_tools_runtime_check_test.sh",
  "tests/runtime_summary_check_test.sh",
  "tests/final_delivery_runtime_gate_test.sh",
  "tests/s6_wire_local_test.sh",
  "tests/render_userdata_remote_nodes_test.sh",
  "tests/init_tokens_resume_test.sh",
  "tests/updater_release_pin_test.sh",
  "tests/updater_bundle_test.sh",
  "tests/updater_bootstrap_resume_test.sh",
  "tests/updater_release_download_test.sh",
  "tests/pricing_estimate_test.sh",
  "tests/update_reset_ops_test.sh",
];

const affectedRules = [
  [/^scripts\/lib\/git-bash\.sh$/, ["tests/git_bash_windows_contract_test.sh", "tests/local_paths_test.sh"]],
  [/^scripts\/lib\/local-paths\.sh$|^scripts\/lib\/paths\.sh$/, ["tests/local_paths_test.sh", "tests/git_bash_windows_contract_test.sh"]],
  [/^scripts\/lib\/json(?:-worker)?\.mjs$|^scripts\/lib\/json\.sh$|^scripts\/json\.mjs$/, ["tests/json_helper_test.sh", "tests/atomic_write_test.sh"]],
  [/^scripts\/lib\/atomic-write\.sh$/, ["tests/atomic_write_test.sh", "tests/private_file_permissions_test.sh"]],
  [/^scripts\/lib\/private-files\.sh$/, ["tests/private_file_permissions_test.sh", "tests/atomic_write_test.sh"]],
  [/^scripts\/lib\/region\.sh$/, ["tests/region_recommendation_test.sh", "tests/orchestrate_region_env_test.sh", "tests/s1_lightsail_availability_fallback_test.sh"]],
  [/^scripts\/lib\/aws\.sh$|^scripts\/aws-credentials\.sh$|^scripts\/phases\/s0_/, ["tests/aws_credentials_test.sh", "tests/eip_preflight_test.sh", "tests/lightsail_static_ip_quota_test.sh"]],
  [/^scripts\/lib\/domain\.sh$|^scripts\/phases\/s2_/, ["tests/domain_dns_mode_detection_test.sh", "tests/domain_route53_default_test.sh", "tests/domain_authoritative_dns_test.sh", "tests/route53_zone_required_test.sh"]],
  [/^scripts\/lib\/state\.sh$/, ["tests/orchestrate_status_recovery_test.sh", "tests/operation_report_test.sh", "tests/final_delivery_runtime_gate_test.sh"]],
  [/^scripts\/lib\/operation_report\.sh$|^scripts\/json\.mjs$/, ["tests/operation_report_test.sh", "tests/final_delivery_runtime_gate_test.sh"]],
  [/^scripts\/lib\/(?:connect-agent-adapters|mcp-client-adapters|connect-daemon-logs|remote-mcp-contract)\.sh$/, ["tests/s6_wire_local_test.sh", "tests/s6_run_phase_failure_test.sh", "tests/mcp_tools_runtime_check_test.sh", "tests/destroy_host_mcp_cleanup_test.sh"]],
  [/^scripts\/lib\/server-release\.sh$/, ["tests/server_release_test.sh", "tests/s3_lightsail_provision_test.sh"]],
  [/^scripts\/lib\/agent-(?:release|ecr-pull|secret-delivery)\.sh$/, ["tests/agent_runtime_contract_test.sh", "tests/agent_ecr_pull_test.sh", "tests/agent_mounted_secret_root_delivery_test.sh", "tests/s3_lightsail_provision_test.sh", "tests/s3_ec2_updater_upload_test.sh", "tests/destroy_lightsail_test.sh", "tests/destroy_root_identity_test.sh"]],
  [/^scripts\/lib\/agent-aws-import-lock\.mjs$/, ["tests/agent_runtime_contract_test.sh"]],
  [/^scripts\/lib\/updater-release\.sh$|^scripts\/updater\//, ["tests/updater_platform_contract_test.sh", "tests/updater_atomic_install_test.sh", "tests/updater_release_pin_test.sh", "tests/updater_bundle_test.sh", "tests/updater_bootstrap_resume_test.sh", "tests/updater_release_download_test.sh", "tests/s3_updater_integration_migration_test.sh", "tests/agent_aws_control_reconcile_test.sh", "tests/agent_worker_control_reconcile_test.sh"]],
  [/^scripts\/lib\/agent-worker-control\.sh$/, ["tests/agent_worker_control_privatelink_test.sh", "tests/agent_worker_control_reconcile_test.sh", "tests/destroy_root_identity_test.sh"]],
  [/^scripts\/pricing-estimate\.sh$/, ["tests/pricing_estimate_test.sh", "tests/s1_lightsail_availability_fallback_test.sh"]],
  [/^scripts\/phases\/s1_/, ["tests/s1_lightsail_availability_fallback_test.sh", "tests/lightsail_static_ip_quota_test.sh", "tests/eip_preflight_test.sh", "tests/root_volume_size_test.sh", "tests/pricing_estimate_test.sh"]],
  [/^scripts\/phases\/s3_/, ["tests/s3_lightsail_provision_test.sh", "tests/s3_ec2_updater_upload_test.sh", "tests/s3_stable_ip_reconcile_test.sh", "tests/s3_public_ip_validation_test.sh", "tests/s3_updater_integration_migration_test.sh", "tests/root_volume_size_test.sh"]],
  [/^scripts\/phases\/s4_|^scripts\/cloud-init\/|^scripts\/render\//, ["tests/render_userdata_remote_nodes_test.sh", "tests/updater_bundle_test.sh", "tests/updater_bootstrap_resume_test.sh", "tests/agent_runtime_contract_test.sh", "tests/s3_ec2_updater_upload_test.sh"]],
  [/^scripts\/phases\/s5_/, ["tests/s5_init_tokens_test.sh", "tests/init_tokens_resume_test.sh"]],
  [/^scripts\/phases\/s6_/, ["tests/s6_run_phase_failure_test.sh", "tests/s6_wire_local_test.sh", "tests/mcp_tools_runtime_check_test.sh", "tests/runtime_summary_check_test.sh", "tests/destroy_host_mcp_cleanup_test.sh"]],
  [/^scripts\/phases\/s7_/, ["tests/s7_http_mcp_acceptance_test.sh", "tests/mcp_tools_runtime_check_test.sh", "tests/runtime_summary_check_test.sh", "tests/final_delivery_runtime_gate_test.sh"]],
  [/^scripts\/destroy\.sh$/, ["tests/destroy_lightsail_test.sh", "tests/destroy_local_bridge_test.sh", "tests/destroy_root_identity_test.sh", "tests/destroy_host_mcp_cleanup_test.sh"]],
  [/^scripts\/(?:update|reset-app-data)\.sh$/, ["tests/update_reset_ops_test.sh", "tests/operation_report_test.sh"]],
  [/^scripts\/adopt-legacy-node\.sh$/, ["tests/legacy_adopt_test.sh", "tests/updater_bundle_test.sh"]],
  [/^scripts\/orchestrate\.sh$/, ["tests/orchestrate_status_recovery_test.sh", "tests/orchestrate_region_env_test.sh", "tests/final_delivery_runtime_gate_test.sh", "tests/s3_ec2_updater_upload_test.sh"]],
  [/^scripts\/lib\/test-runner\.mjs$|^scripts\/run-tests\.mjs$|^tests\/npm_test_suite\.sh$|^tests\/lib\/run_isolated\.sh$/, [runnerTest, "tests/skill_structure_test.sh"]],
  [/^bin\/dirextalk-deployer\.mjs$/, ["tests/npm_skill_distribution_test.sh", "tests/skill_structure_test.sh"]],
  [/^(?:AGENTS\.md|README\.md|SKILL\.md|package(?:-lock)?\.json|agents\/|references\/|\.openclaw\/|\.github\/)/, ["tests/npm_skill_distribution_test.sh", "tests/skill_structure_test.sh", "tests/tracked_text_lf_test.sh"]],
];

function orderedUnique(values) {
  return [...new Set(values)];
}

function normalizeChangedFile(file) {
  return String(file || "").trim().replaceAll("\\", "/").replace(/^\.\//, "");
}

export function selectAffectedTests(changedFiles, { release = false } = {}) {
  const selected = [runnerTest];
  if (release) selected.push(...packagingTests);

  for (const rawFile of changedFiles || []) {
    const file = normalizeChangedFile(rawFile);
    if (!file) continue;
    let matched = false;

    if (/^tests\/.+_test\.(?:sh|mjs)$/.test(file)) {
      selected.push(file);
      matched = true;
    }
    for (const [pattern, tests] of affectedRules) {
      if (pattern.test(file)) {
        selected.push(...tests);
        matched = true;
      }
    }
    if (!matched && /^(?:scripts|bin)\//.test(file)) {
      selected.push(...quickTests);
    }
  }

  return orderedUnique(selected);
}

function gitOutput(args, { root, env, spawn }) {
  const result = spawn("git", args, { cwd: root, env, encoding: "utf8", shell: false });
  return result.status === 0 ? String(result.stdout || "") : "";
}

export function discoverChangedFiles({ root = defaultRoot, env = process.env, spawn = spawnSync } = {}) {
  if (env.DIREXTALK_TEST_CHANGED_FILES) {
    return orderedUnique(env.DIREXTALK_TEST_CHANGED_FILES.split(/[\r\n,]+/).map(normalizeChangedFile).filter(Boolean));
  }

  const head = gitOutput(["rev-parse", "--verify", "HEAD"], { root, env, spawn }).trim();
  if (!head) return null;

  const files = [];
  files.push(...gitOutput(["diff", "--name-only", "--diff-filter=ACMRTUXB", "HEAD", "--"], { root, env, spawn }).split(/\r?\n/));
  files.push(...gitOutput(["ls-files", "--others", "--exclude-standard"], { root, env, spawn }).split(/\r?\n/));

  const base = env.DIREXTALK_TEST_BASE || "origin/main";
  const baseExists = gitOutput(["rev-parse", "--verify", "--quiet", base], { root, env, spawn }).trim();
  if (baseExists) {
    files.push(...gitOutput(["diff", "--name-only", "--diff-filter=ACMRTUXB", `${base}...HEAD`, "--"], { root, env, spawn }).split(/\r?\n/));
  }
  return orderedUnique(files.map(normalizeChangedFile).filter(Boolean));
}

function fullTests() {
  const normalStage = stageTests.filter((test) => test !== "tests/s6_run_phase_failure_test.sh");
  return orderedUnique([...quickTests, ...normalStage, ...slowTests]);
}

export function buildTestInvocation(mode = "affected", options = {}) {
  let tests;
  switch (mode) {
    case "affected": {
      const changedFiles = options.changedFiles ?? discoverChangedFiles(options);
      tests = changedFiles === null ? quickTests : selectAffectedTests(changedFiles);
      break;
    }
    case "release": {
      const changedFiles = options.changedFiles ?? discoverChangedFiles(options);
      tests = changedFiles === null ? quickTests : selectAffectedTests(changedFiles, { release: true });
      break;
    }
    case "quick":
      tests = quickTests;
      break;
    case "stage":
      tests = stageTests;
      break;
    case "full":
      tests = fullTests();
      break;
    default:
      throw new Error(`unsupported test mode: ${mode}`);
  }
  return {
    command: "bash",
    args: ["tests/lib/run_isolated.sh", "tests/npm_test_suite.sh", ...tests],
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
  mode = "affected",
  changedFiles,
  platform = process.platform,
  env = process.env,
  exists = existsSync,
  root = defaultRoot,
  spawn = spawnSync,
} = {}) {
  const shell = resolveTestShell({ platform, env, exists });
  const invocation = buildTestInvocation(mode, { changedFiles, root, env, spawn });
  const selected = invocation.args.slice(2).map((test) => test.replace(/::extended$/, ""));
  console.log(`Selected ${selected.length} ${mode} test(s): ${selected.join(", ")}`);
  const result = spawn(shell, invocation.args, { cwd: root, stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const error = new Error(`deployer test suite failed with exit code ${result.status ?? 1}`);
    error.exitCode = result.status ?? 1;
    throw error;
  }
}
