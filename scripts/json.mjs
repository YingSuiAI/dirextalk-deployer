#!/usr/bin/env node
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

const [command, ...args] = process.argv.slice(2);

try {
  switch (command) {
    case "get":
      cmdGet(args);
      break;
    case "stdin-get":
      cmdStdinGet(args);
      break;
    case "assert":
      cmdAssert(args);
      break;
    case "stdin-assert":
      cmdStdinAssert(args);
      break;
    case "check":
      cmdCheck(args);
      break;
    case "entries":
      cmdEntries(args);
      break;
    case "stdin-tsv":
      cmdStdinTsv(args);
      break;
    case "stdin-join":
      cmdStdinJoin(args);
      break;
    case "stdin-route53-a-values":
      cmdStdinRoute53AValues(args);
      break;
    case "stdin-route53-a-present":
      cmdStdinRoute53APresent(args);
      break;
    case "stdin-price-usd":
      cmdStdinPriceUsd();
      break;
    case "length":
      cmdLength(args);
      break;
    case "type":
      cmdType(args);
      break;
    case "build":
      cmdBuild(args);
      break;
    case "mutate":
      cmdMutate(args);
      break;
    case "operation-report":
      cmdOperationReport(args);
      break;
    case "valid":
      readJsonFile(required(args, 0, "file"));
      break;
    default:
      usage(command ? `unknown command: ${command}` : "missing command");
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

function cmdGet(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  const fallback = args.length > 2 ? args[2] : "";
  printValue(getPath(readJsonFile(file), jsonPath, fallback));
}

function cmdStdinGet(args) {
  const jsonPath = required(args, 0, "path");
  const fallback = args.length > 1 ? args[1] : "";
  printValue(getPath(readJsonStdin(), jsonPath, fallback));
}

function cmdAssert(args) {
  const file = required(args, 0, "file");
  const preset = required(args, 1, "preset");
  const data = readJsonFile(file);
  assertPreset(data, preset, args.slice(2));
}

function cmdStdinAssert(args) {
  const preset = required(args, 0, "preset");
  const data = readJsonStdin();
  assertPreset(data, preset, args.slice(1));
}

function assertPreset(data, preset, rest) {
  let ok = false;

  switch (preset) {
    case "path-equals": {
      const jsonPath = required(rest, 0, "path");
      const expected = required(rest, 1, "expected");
      ok = String(getPath(data, jsonPath, "")) === expected;
      break;
    }
    case "path-missing": {
      const jsonPath = required(rest, 0, "path");
      ok = !hasPath(data, jsonPath);
      break;
    }
    case "messages-list":
      ok = Array.isArray(data.messages) && typeof data.room_id === "undefined";
      if (!ok && Array.isArray(data.messages) && typeof data.room_id === "string") ok = true;
      break;
    case "messages-response":
      ok = Array.isArray(data.messages) && typeof data.room_id === "string";
      break;
    case "tools-list":
      ok = Array.isArray(data.tools) && typeof data.tool_count === "number";
      break;
    case "matrix-session":
      ok = Boolean(data.access_token && data.device_id && data.user_id && data.homeserver);
      break;
    case "well-known-server": {
      const expected = required(rest, 0, "expected");
      ok = data["m.server"] === expected;
      break;
    }
    case "turn-credentials":
      ok = Array.isArray(data.uris) &&
        data.uris.length > 0 &&
        data.uris.some((uri) => /^turns?:/.test(String(uri))) &&
        String(data.username || "").length > 0 &&
        String(data.password || "").length > 0 &&
        Number(data.ttl) > 0;
      break;
    case "bootstrap-normalized":
      ok = typeof data.password === "string" &&
        /^[0-9]{8}$/.test(data.password) &&
        typeof data.agent_token === "string" &&
        data.agent_token.length > 0 &&
        typeof data.access_token === "string" &&
        data.access_token.length > 0;
      break;
    default:
      usage(`unknown assert preset: ${preset}`);
  }

  if (!ok) process.exit(1);
}

function cmdCheck(args) {
  const file = required(args, 0, "file");
  const expression = required(args, 1, "expression");
  const data = readJsonFile(file);
  const ok = Boolean(Function("data", `"use strict"; return (${expression});`)(data));
  if (!ok) process.exit(1);
}

function cmdEntries(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  const value = getPath(readJsonFile(file), jsonPath, {});
  if (!isObject(value)) return;
  for (const [key, entryValue] of Object.entries(value)) {
    printLine(`${key}=${formatEntryValue(entryValue)}`);
  }
}

function cmdStdinTsv(args) {
  const arrayPath = required(args, 0, "array_path");
  const fields = args.slice(1);
  if (fields.length === 0) usage("stdin-tsv requires at least one field");
  const value = getPath(readJsonStdin(), arrayPath, []);
  if (!Array.isArray(value)) return;
  for (const entry of value) {
    printLine(fields.map((field) => stringValue(getPath(entry, field, ""))).join("\t"));
  }
}

function cmdStdinJoin(args) {
  const jsonPath = required(args, 0, "path");
  const separator = args.length > 1 ? args[1] : ",";
  const value = getPath(readJsonStdin(), jsonPath, []);
  if (!Array.isArray(value)) return;
  printLine(value.map((item) => stringValue(item)).join(separator));
}

function cmdStdinRoute53AValues(args) {
  const name = required(args, 0, "record_name");
  const data = readJsonStdin();
  const rrsets = Array.isArray(data.ResourceRecordSets) ? data.ResourceRecordSets : [];
  const values = [];
  for (const rrset of rrsets) {
    if (rrset?.Name !== name || rrset?.Type !== "A") continue;
    for (const record of Array.isArray(rrset.ResourceRecords) ? rrset.ResourceRecords : []) {
      if (typeof record?.Value !== "undefined") values.push(String(record.Value));
    }
  }
  printLine(values.join(","));
}

function cmdStdinRoute53APresent(args) {
  const name = required(args, 0, "record_name");
  const ip = required(args, 1, "ip");
  const data = readJsonStdin();
  const rrsets = Array.isArray(data.ResourceRecordSets) ? data.ResourceRecordSets : [];
  const present = rrsets.some((rrset) =>
    rrset?.Name === name &&
    rrset?.Type === "A" &&
    (Array.isArray(rrset.ResourceRecords) ? rrset.ResourceRecords : []).some((record) => String(record?.Value) === ip)
  );
  printLine(String(present));
}

function cmdStdinPriceUsd() {
  const data = readJsonStdin();
  const firstPrice = data.PriceList?.[0];
  if (typeof firstPrice !== "string") return;
  const product = JSON.parse(firstPrice);
  const onDemand = Object.values(product.terms?.OnDemand || {})[0];
  const dimension = Object.values(onDemand?.priceDimensions || {})[0];
  printValue(dimension?.pricePerUnit?.USD || "");
}

function cmdLength(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  const value = getPath(readJsonFile(file), jsonPath, null);
  if (Array.isArray(value) || typeof value === "string") {
    printLine(String(value.length));
    return;
  }
  if (isObject(value)) {
    printLine(String(Object.keys(value).length));
    return;
  }
  printLine("0");
}

function cmdType(args) {
  const file = required(args, 0, "file");
  const jsonPath = required(args, 1, "path");
  printLine(jsonType(getPath(readJsonFile(file), jsonPath, undefined)));
}

function cmdBuild(args) {
  const preset = required(args, 0, "preset");
  let data;

  switch (preset) {
    case "simple-state":
      data = {};
      for (const [key, value] of parsePairs(args.slice(1))) setPath(data, key, parseScalar(value));
      break;
    case "object":
      data = {};
      for (const [key, value] of parsePairs(args.slice(1))) setPath(data, key, parseScalar(value));
      break;
    case "mcp-messages-list":
      data = { action: "mcp.messages.list", params: { room_id: required(args, 1, "room_id"), limit: 1 } };
      process.stdout.write(`${JSON.stringify(data)}\n`);
      return;
    case "matrix-session-create":
      data = { action: "agent.matrix_session.create", params: { device_id: required(args, 1, "device_id") } };
      process.stdout.write(`${JSON.stringify(data)}\n`);
      return;
    case "mcp-json-config": {
      const serverName = required(args, 1, "server_name");
      data = {
        mcpServers: {
          [serverName]: {
            command: required(args, 2, "command"),
            env: {
              DIREXIO_CREDENTIALS_FILE: required(args, 3, "credentials_file"),
              DIREXIO_AGENT_NODE_ID: args[4] || ""
            }
          }
        }
      };
      break;
    }
    case "mcp-openclaw-server-config":
      data = {
        command: required(args, 1, "command"),
        env: {
          DIREXIO_CREDENTIALS_FILE: required(args, 2, "credentials_file"),
          DIREXIO_AGENT_NODE_ID: args[3] || ""
        }
      };
      break;
    case "credentials-profile":
      data = {
        profiles: {
          default: {
            domain: required(args, 1, "domain"),
            password: required(args, 4, "password"),
            access_token: required(args, 5, "access_token"),
            agent_room_id: required(args, 6, "agent_room_id"),
            direxio_domain: required(args, 2, "as_url"),
            direxio_agent_token: required(args, 3, "agent_token"),
            direxio_agent_room_id: required(args, 6, "agent_room_id"),
            direxio_agent_node_id: required(args, 7, "node_id")
          }
        }
      };
      break;
    case "pricing-estimate":
      data = buildPricingEstimate(args.slice(1));
      break;
    case "bootstrap-normalized":
      data = normalizeBootstrap(required(args, 1, "file"), required(args, 2, "domain"));
      break;
    default:
      usage(`unknown build preset: ${preset}`);
  }

  process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
}

function cmdMutate(args) {
  const file = required(args, 0, "file");
  const preset = required(args, 1, "preset");
  const data = existsSync(file) ? readJsonFileOrEmptyObject(file) : {};

  switch (preset) {
    case "set-string": {
      setPath(data, required(args, 2, "path"), required(args, 3, "value"));
      break;
    }
    case "set-json": {
      setPath(data, required(args, 2, "path"), JSON.parse(required(args, 3, "json")));
      break;
    }
    case "state-init": {
      const runId = required(args, 2, "run_id");
      const region = required(args, 3, "region");
      const ts = required(args, 4, "timestamp");
      const phases = args.slice(5);
      const phaseState = {};
      for (const phase of phases) phaseState[phase] = { status: "pending" };
      Object.assign(data, {
        run_id: runId,
        region: region === "" ? null : region,
        domain_mode: null,
        domain: null,
        domain_confirmed_irreversible: false,
        instance_type: null,
        dns_ready: false,
        existing_state_confirmed: false,
        phase: "S0_PREREQ_AWS",
        created_at: ts,
        phases: phaseState,
        resources: {}
      });
      break;
    }
    case "phase-set": {
      const phase = required(args, 2, "phase");
      const status = required(args, 3, "status");
      const ts = required(args, 4, "timestamp");
      const evidence = args[5] || "";
      if (!isObject(data.phases)) data.phases = {};
      if (!isObject(data.phases[phase])) data.phases[phase] = {};
      data.phases[phase].status = status;
      data.phases[phase].ts = ts;
      if (evidence !== "") data.phases[phase].evidence = evidence;
      data.phase = phase;
      break;
    }
    case "ops-refresh-pending": {
      const startPhase = required(args, 2, "start_phase");
      const ts = required(args, 3, "timestamp");
      for (const key of ["password", "access_token", "agent_token", "agent_room_id", "user_confirmations", "runtime_checks"]) {
        delete data[key];
      }
      data.agent_install_status = "refresh_pending";
      data.mcp_install_status = "refresh_pending";
      data.phase = startPhase;
      if (!isObject(data.phases)) data.phases = {};
      if (startPhase === "S4_BOOTSTRAP_STACK") {
        data.phases.S4_BOOTSTRAP_STACK = {
          status: "pending",
          ts,
          evidence: "existing node operation requires fresh health check"
        };
      }
      data.phases.S5_INIT_TOKENS = {
        status: "pending",
        ts,
        evidence: "existing node operation requires fresh bootstrap credentials"
      };
      data.phases.S6_WIRE_LOCAL = {
        status: "pending",
        ts,
        evidence: "existing node operation requires local credentials and MCP refresh"
      };
      data.phases.S7_VERIFY_E2E = {
        status: "pending",
        ts,
        evidence: "existing node operation requires fresh verification"
      };
      break;
    }
    case "delete": {
      deletePath(data, required(args, 2, "path"));
      break;
    }
    case "destroy-evidence": {
      const key = required(args, 2, "key");
      if (!isObject(data.destroy_evidence)) data.destroy_evidence = {};
      data.destroy_evidence[key] = {
        status: required(args, 3, "status"),
        detail: args[4] || "",
        checked_at: required(args, 5, "checked_at")
      };
      break;
    }
    default:
      usage(`unknown mutate preset: ${preset}`);
  }

  atomicWriteJson(file, data);
}

function cmdOperationReport(args) {
  const operation = required(args, 0, "operation");
  const status = required(args, 1, "status");
  const stateFile = required(args, 2, "state");
  const generatedAt = required(args, 3, "generated_at");
  const st = readJsonFile(stateFile);
  process.stdout.write(`${JSON.stringify(buildOperationReport(operation, status, stateFile, generatedAt, st), null, 2)}\n`);
}

function buildOperationReport(operation, status, stateFile, generatedAt, st) {
  const redactedStatus = stringValue(st.password).length > 0 ? "available_in_state_password_field_redacted" : "missing";
  const phaseStatuses = {};
  for (const [key, value] of Object.entries(objectValue(st.phases))) {
    phaseStatuses[key] = stringValue(value?.status || "unknown");
  }
  const userGate = (gate, fallback) => st.user_confirmations?.[gate]?.status || fallback;
  const localRefreshStatus = st.agent_install_status === "refresh_pending" ? "refresh_pending" : "current_or_not_recorded";
  const billable = compact([
    stringValue(st.resources?.instance_id) ? `EC2 ${st.resources.instance_id}` : "",
    stringValue(st.resources?.root_volume_id) ? `EBS root volume ${st.resources.root_volume_id}` : "",
    stringValue(st.resources?.public_ip) ? `public IPv4 ${st.resources.public_ip}` : "",
    stringValue(st.resources?.eip_id) ? `Elastic IP ${st.resources.eip_id}` : "",
    stringValue(st.resources?.route53_zone_id) ? `Route53 hosted zone ${st.resources.route53_zone_id}` : ""
  ]);
  const destroyStatus = (key) => st.destroy_evidence?.[key]?.status || "not_checked";
  const statusNotIn = (value, safe) => !safe.includes(value);
  const destroyBillableResidue = compact([
    stringValue(st.resources?.instance_id) && statusNotIn(destroyStatus("ec2_instance"), ["terminated", "not_found", "skipped"])
      ? `EC2 ${st.resources.instance_id} status=${destroyStatus("ec2_instance")}` : "",
    stringValue(st.resources?.root_volume_id) && statusNotIn(destroyStatus("ebs_root_volume"), ["deleted", "skipped"])
      ? `EBS root volume ${st.resources.root_volume_id} status=${destroyStatus("ebs_root_volume")}` : "",
    stringValue(st.resources?.eip_id) && statusNotIn(destroyStatus("elastic_ip"), ["released", "skipped"])
      ? `Elastic IP ${st.resources.eip_id} status=${destroyStatus("elastic_ip")}` : "",
    stringValue(st.resources?.route53_zone_id) && statusNotIn(destroyStatus("route53_hosted_zone"), ["deleted", "skipped"])
      ? `Route53 hosted zone ${st.resources.route53_zone_id} status=${destroyStatus("route53_hosted_zone")}` : ""
  ]);

  const report = {
    operation_type: operation,
    status,
    generated_at: generatedAt,
    domain: st.domain || "",
    service_id: st.agent_service_id || st.domain || "",
    service_dir: st.agent_service_dir || "",
    state_json: stateFile,
    delivery: {
      app_domain: st.domain || "",
      product_completion_status: status,
      init_code_status: redactedStatus,
      init_code_secret_redacted: true,
      user_path: "enter app_domain and the eight-digit initialization code in the App"
    },
    agent: {
      node_id: st.agent_node_id || "",
      room_id: st.agent_room_id || "",
      runtime: st.agent_runtime || "unknown",
      service_id: st.agent_service_id || st.domain || "",
      credentials_file: st.agent_credentials_file || ""
    },
    gates: {
      automated: phaseStatuses,
      user_confirmation: {
        app_initialization: userGate("app_initialization", "pending_user_confirmation"),
        real_chat: userGate("real_chat", "pending_user_confirmation"),
        agent_mcp_runtime: userGate("agent_mcp_runtime", "pending_runtime_confirmation")
      },
      user_confirmation_details: {
        app_initialization: userGateDetail(st, "app_initialization", "pending_user_confirmation"),
        real_chat: userGateDetail(st, "real_chat", "pending_user_confirmation"),
        agent_mcp_runtime: userGateDetail(st, "agent_mcp_runtime", "pending_runtime_confirmation")
      }
    },
    runtime_checks: {
      summary: st.runtime_checks?.summary || { status: "not_run" },
      connect_daemon: st.runtime_checks?.connect_daemon || { status: "not_run" },
      mcp_doctor: st.runtime_checks?.mcp_doctor || { status: "not_run" },
      mcp_smoke: st.runtime_checks?.mcp_smoke || { status: "not_run" },
      mcp_tools: st.runtime_checks?.mcp_tools || { status: "not_run" }
    },
    credentials: {
      status: localRefreshStatus,
      credentials_file: st.agent_credentials_file || "",
      contains_secrets: true,
      values_redacted: true
    },
    connect: {
      package: st.connect_npm_package || "direxio-connent@latest",
      agent: st.connect_agent || "",
      config: st.connect_config || "",
      install_status: st.agent_install_status || ""
    },
    mcp: {
      status: localRefreshStatus,
      install_status: st.mcp_install_status || "",
      package: st.mcp_npm_package || "direxio-mcp@latest",
      server_name: st.mcp_server_name || "",
      config_dir: st.mcp_config_dir || "",
      codex: st.mcp_codex_config || "",
      openclaw: st.mcp_openclaw_config || "",
      hermes: st.mcp_hermes_config || "",
      doctor: st.mcp_doctor_command || ""
    },
    resources: {
      region: st.region || "",
      domain_mode: st.domain_mode || "",
      instance_type: st.instance_type || "",
      instance_id: st.resources?.instance_id || "",
      root_volume_id: st.resources?.root_volume_id || "",
      public_ip: st.resources?.public_ip || "",
      eip_id: st.resources?.eip_id || "",
      route53_zone_id: st.resources?.route53_zone_id || "",
      route53_zone_name: st.resources?.route53_zone_name || "",
      route53_zone_created_by_deployer: st.resources?.route53_zone_created_by_deployer || "",
      route53_name_servers: st.resources?.route53_name_servers || "",
      route53_existing_a_value: st.resources?.route53_existing_a_value || "",
      route53_pending_a_value: st.resources?.route53_pending_a_value || "",
      route53_overwrite_confirmed: st.resources?.route53_overwrite_confirmed || "",
      sg_id: st.resources?.sg_id || "",
      key_name: st.resources?.key_name || ""
    },
    billing: {
      keeps_billing_until_destroy: operation !== "destroy",
      recorded_billable_resources: billable,
      cost_estimate: typeof st.cost_estimate === "undefined" ? null : st.cost_estimate,
      destroy_cleanup_status: operation !== "destroy"
        ? "not_destroy"
        : destroyBillableResidue.length === 0
          ? "no_recorded_billable_resource_residue"
          : "possible_billable_resource_residue",
      possible_remaining_billable_resources: operation === "destroy" ? destroyBillableResidue : []
    },
    security: {
      secrets_included: false,
      values_redacted: true,
      root_access_key_allowed: true,
      temporary_iam_cleanup_required: true,
      temporary_iam_cleanup_action: "if a temporary DirexioDeployer access key was used, delete or disable it after deployment, or reduce it to a maintenance-only policy"
    }
  };

  if (operation === "destroy") {
    report.destroy = {
      resources_processed_from_state: true,
      user_managed_dns_not_removed: true,
      purchased_domain_not_removed: true,
      local_service_dir: st.agent_service_dir || "",
      evidence: st.destroy_evidence || {}
    };
  }

  return report;
}

function userGateDetail(st, gate, fallback) {
  const gateState = st.user_confirmations?.[gate] || {};
  const originalEvidence = stringValue(gateState.evidence);
  const evidence = redactText(originalEvidence, st);
  const detail = {
    status: gateState.status || fallback,
    ts: gateState.ts || "",
    evidence,
    evidence_redacted: evidence !== originalEvidence
  };
  if (gate === "agent_mcp_runtime") {
    detail.runtime_summary_status = gateState.runtime_summary_status || "";
    detail.runtime_probe_confirmed = gateState.runtime_probe_confirmed || false;
  }
  return detail;
}

function redactText(value, st) {
  let result = stringValue(value);
  for (const secret of [
    st.password,
    st.access_token,
    st.agent_token,
    st.matrix_access_token,
    st.owner_access_token,
    st.aws_secret_access_key,
    st.aws_session_token
  ]) {
    const text = stringValue(secret);
    if (text.length > 0) result = result.split(text).join("<redacted>");
  }
  return result.replace(/[0-9]{8,}/g, "<redacted>");
}

function readJsonFile(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function readJsonFileOrEmptyObject(file) {
  const raw = readFileSync(file, "utf8");
  return raw.trim().length === 0 ? {} : JSON.parse(raw);
}

function readJsonStdin() {
  return JSON.parse(readFileSync(0, "utf8"));
}

function atomicWriteJson(file, data) {
  const tmp = `${file}.tmp.${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, "utf8");
  renameSync(tmp, file);
}

function getPath(data, jsonPath, fallback = "") {
  const result = resolvePath(data, jsonPath);
  return result.exists ? result.value : fallback;
}

function hasPath(data, jsonPath) {
  return resolvePath(data, jsonPath).exists;
}

function setPath(data, jsonPath, value) {
  const segments = parsePath(jsonPath);
  let current = data;
  for (let i = 0; i < segments.length - 1; i += 1) {
    const segment = segments[i];
    if (!isObject(current[segment])) current[segment] = {};
    current = current[segment];
  }
  current[segments[segments.length - 1]] = value;
}

function deletePath(data, jsonPath) {
  const segments = parsePath(jsonPath);
  let current = data;
  for (let i = 0; i < segments.length - 1; i += 1) {
    current = current?.[segments[i]];
    if (!isObject(current)) return;
  }
  delete current[segments[segments.length - 1]];
}

function resolvePath(data, jsonPath) {
  if (jsonPath === "." || jsonPath === "") return { exists: true, value: data };
  let current = data;
  for (const segment of parsePath(jsonPath)) {
    if (!isObject(current) && !Array.isArray(current)) return { exists: false, value: undefined };
    if (!(segment in current)) return { exists: false, value: undefined };
    current = current[segment];
  }
  return { exists: true, value: current };
}

function parsePath(jsonPath) {
  return String(jsonPath)
    .split(".")
    .filter((segment) => segment.length > 0);
}

function parsePairs(args) {
  return args.map((pair) => {
    const index = pair.indexOf("=");
    if (index < 0) usage(`expected key=value, got: ${pair}`);
    return [pair.slice(0, index), pair.slice(index + 1)];
  });
}

function parseScalar(value) {
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null") return null;
  if (/^-?\d+(\.\d+)?$/.test(value)) return Number(value);
  if ((value.startsWith("{") && value.endsWith("}")) || (value.startsWith("[") && value.endsWith("]"))) {
    return JSON.parse(value);
  }
  return value;
}

function buildPricingEstimate(args) {
  const [
    pricingStatus,
    region,
    location,
    instanceType,
    domainMode,
    ec2Source,
    gp3Source,
    ipv4Source,
    warningsJson,
    hours,
    diskGb,
    ec2Hourly,
    ec2Monthly,
    gp3Rate,
    gp3Monthly,
    ipv4Hourly,
    ipv4Monthly,
    route53Monthly
  ] = args;
  const components = {
    ec2_instance: {
      instance_type: required(args, 3, "instance_type"),
      hourly_usd: numberValue(ec2Hourly),
      monthly_usd: numberValue(ec2Monthly),
      source: ec2Source
    },
    ebs_gp3: {
      storage_gb: numberValue(diskGb),
      gb_month_usd: numberValue(gp3Rate),
      monthly_usd: numberValue(gp3Monthly),
      source: gp3Source
    },
    public_ipv4: {
      hourly_usd: numberValue(ipv4Hourly),
      monthly_usd: numberValue(ipv4Monthly),
      billed_even_when_attached: true,
      source: ipv4Source
    },
    route53_hosted_zone: {
      monthly_usd: numberValue(route53Monthly),
      included: domainMode === "route53"
    }
  };
  const total = components.ec2_instance.monthly_usd +
    components.ebs_gp3.monthly_usd +
    components.public_ipv4.monthly_usd +
    components.route53_hosted_zone.monthly_usd;
  return {
    pricing_status: pricingStatus,
    region,
    location,
    hours_per_month: numberValue(hours),
    warnings: unique(JSON.parse(warningsJson || "[]")),
    components,
    notes: [
      "Estimate excludes data transfer, TURN relay traffic, domain registration, taxes, and AWS credit eligibility.",
      "Public IPv4 is billed hourly by AWS even when attached to a running instance.",
      "AWS credits may reduce charges only when the account, plan, region, and service usage are eligible; verify in AWS Billing Console."
    ],
    recommendations: [
      "Set an AWS Budget or billing alert before leaving the node running.",
      "Review AWS Billing Console after deployment and after destroy to confirm actual charges and remaining credits."
    ],
    total_monthly_usd: Math.round(total * 100) / 100
  };
}

function normalizeBootstrap(file, domain) {
  const src = readJsonFile(file);
  const asUrl = `https://${domain}`;
  return {
    ...src,
    domain: src.domain || domain,
    as_url: src.as_url || asUrl,
    p2p_url: src.p2p_url || asUrl,
    user_id: src.user_id || src.owner_user_id || "",
    bot_mxid: src.bot_mxid || src.owner_user_id || src.user_id || `@owner:${domain}`,
    access_token: src.access_token || "",
    agent_token: src.agent_token || "",
    agent_room_id: src.agent_room_id || ""
  };
}

function numberValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function unique(values) {
  return Array.from(new Set(values));
}

function printValue(value) {
  if (value === null || typeof value === "undefined") {
    process.stdout.write("\n");
    return;
  }
  if (typeof value === "object") {
    process.stdout.write(`${JSON.stringify(value)}\n`);
    return;
  }
  process.stdout.write(`${String(value)}\n`);
}

function printLine(value) {
  process.stdout.write(`${value}\n`);
}

function formatEntryValue(value) {
  if (value === null || typeof value === "undefined") return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function jsonType(value) {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  if (typeof value === "undefined") return "missing";
  return typeof value;
}

function required(args, index, name) {
  const value = args[index];
  if (typeof value === "undefined") usage(`missing ${name}`);
  return value;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function usage(message) {
  throw new Error(`${message}\nUsage: scripts/json.mjs <get|stdin-get|assert|stdin-assert|check|entries|stdin-tsv|stdin-join|stdin-route53-a-values|stdin-route53-a-present|stdin-price-usd|length|type|build|mutate|operation-report|valid> ...`);
}

function compact(values) {
  return values.filter((value) => String(value || "").length > 0);
}

function objectValue(value) {
  return isObject(value) ? value : {};
}

function stringValue(value) {
  return typeof value === "undefined" || value === null ? "" : String(value);
}
