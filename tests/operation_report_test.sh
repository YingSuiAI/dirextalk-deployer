#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

assert_file_exists() {
  [ -s "$1" ] || {
    echo "expected non-empty file: $1" >&2
    exit 1
  }
}

assert_not_contains_secret() {
  local path=$1
  if grep -E '12345678|87654321|ACCESS_SECRET|AGENT_SECRET|AWS_SECRET' "$path" >/dev/null; then
    echo "operation report leaked a secret: $path" >&2
    cat "$path" >&2
    exit 1
  fi
}

service_dir="$HOME/.direxio/nodes/report.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  '{
    run_id: "report-test",
    region: "ap-northeast-1",
    domain_mode: "route53",
    domain: "report.example.test",
    as_url: "https://report.example.test",
    instance_type: "t3.small",
    password: "12345678",
    access_token: "ACCESS_SECRET",
    agent_token: "AGENT_SECRET",
    agent_room_id: "!room:report.example.test",
    agent_node_id: "node-report",
    agent_service_id: "report.example.test",
    agent_service_dir: $service_dir,
    agent_credentials_file: ($service_dir + "/credentials.json"),
    cc_connect_config: ($service_dir + "/cc-connect/config.toml"),
    cc_connect_agent: "acp",
    cc_connect_npm_package: "direxio-connent@latest",
    mcp_npm_package: "direxio-mcp@latest",
    mcp_server_name: "direxio-report-example-test",
    mcp_config_dir: ($service_dir + "/mcp"),
    mcp_codex_config: ($service_dir + "/mcp/codex.toml"),
    mcp_openclaw_config: ($service_dir + "/mcp/openclaw.md"),
    mcp_hermes_config: ($service_dir + "/mcp/hermes.mcp.json"),
    mcp_doctor_command: "DIREXIO_CREDENTIALS_FILE=<redacted> direxio-mcp doctor --json",
    phase: "S7_VERIFY_E2E",
    phases: {
      S0_PREREQ_AWS: {status: "done"},
      S1_PREFLIGHT: {status: "done"},
      S2_DOMAIN: {status: "done"},
      S3_PROVISION: {status: "done"},
      S4_BOOTSTRAP_STACK: {status: "done"},
      S5_INIT_TOKENS: {status: "done"},
      S6_WIRE_LOCAL: {status: "done"},
      S7_VERIFY_E2E: {status: "done"}
    },
    user_confirmations: {
      app_initialization: {
        status: "confirmed",
        ts: "2026-06-28T01:02:03Z",
        evidence: "user completed app initialization with code 12345678; old screenshot showed code 87654321"
      },
      real_chat: {
        status: "confirmed",
        ts: "2026-06-28T01:03:04Z",
        evidence: "user saw the agent reply; token ACCESS_SECRET stayed local"
      },
      agent_mcp_runtime: {
        status: "confirmed",
        ts: "2026-06-28T01:04:05Z",
        evidence: "runtime channel probe confirmed with agent token AGENT_SECRET",
        runtime_summary_status: "passed",
        runtime_probe_confirmed: true
      }
    },
    resources: {
      instance_id: "i-report",
      root_volume_id: "vol-report-root",
      public_ip: "203.0.113.42",
      eip_id: "eipalloc-report",
      route53_zone_id: "ZREPORT",
      route53_zone_name: "report.example.test",
      route53_zone_created_by_deployer: "true",
      route53_existing_a_value: "198.51.100.20",
      route53_pending_a_value: "203.0.113.42",
      route53_overwrite_confirmed: "true",
      sg_id: "sg-report",
      key_name: "direxio-report"
    }
  }' > "$state"

report_output=$(P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
assert_file_exists "$report_path"
assert_not_contains_secret "$report_path"

jq -e '
  .operation_type == "new_deploy"
  and .status == "automated_gates_complete_user_confirmation_pending"
  and .domain == "report.example.test"
  and .delivery.app_domain == "report.example.test"
  and (.delivery | has("service_url") | not)
  and .delivery.init_code_status == "available_in_state_password_field_redacted"
  and .delivery.init_code_secret_redacted == true
  and .delivery.product_completion_status == "automated_gates_complete_user_confirmation_pending"
  and .agent.node_id == "node-report"
  and .agent.room_id == "!room:report.example.test"
  and .agent.runtime == "unknown"
  and .gates.automated.S7_VERIFY_E2E == "done"
  and .gates.user_confirmation.app_initialization == "confirmed"
  and .gates.user_confirmation.real_chat == "confirmed"
  and .gates.user_confirmation.agent_mcp_runtime == "confirmed"
  and .gates.user_confirmation_details.app_initialization.status == "confirmed"
  and .gates.user_confirmation_details.app_initialization.ts == "2026-06-28T01:02:03Z"
  and .gates.user_confirmation_details.app_initialization.evidence == "user completed app initialization with code <redacted>; old screenshot showed code <redacted>"
  and .gates.user_confirmation_details.real_chat.evidence == "user saw the agent reply; token <redacted> stayed local"
  and .gates.user_confirmation_details.agent_mcp_runtime.evidence == "runtime channel probe confirmed with agent token <redacted>"
  and .gates.user_confirmation_details.agent_mcp_runtime.runtime_summary_status == "passed"
  and .gates.user_confirmation_details.agent_mcp_runtime.runtime_probe_confirmed == true
  and .credentials.values_redacted == true
  and .security.secrets_included == false
  and .mcp.package == "direxio-mcp@latest"
  and .resources.route53_zone_id == "ZREPORT"
  and .resources.route53_zone_name == "report.example.test"
  and .resources.route53_existing_a_value == "198.51.100.20"
  and .resources.route53_pending_a_value == "203.0.113.42"
  and .resources.route53_overwrite_confirmed == "true"
  and .resources.root_volume_id == "vol-report-root"
  and (.billing.recorded_billable_resources | index("EC2 i-report") != null)
  and (.billing.recorded_billable_resources | index("EBS root volume vol-report-root") != null)
  and (.billing.recorded_billable_resources | index("public IPv4 203.0.113.42") != null)
  and (.billing.recorded_billable_resources | index("Route53 hosted zone ZREPORT") != null)
  and .security.root_access_key_allowed == true
  and .security.temporary_iam_cleanup_required == true
  and (.security.temporary_iam_cleanup_action | contains("delete or disable"))
' "$report_path" >/dev/null

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    case "$*" in
      *"--query Arn"*) printf 'arn:aws:iam::123456789012:user/DirexioDeployer-Test\n' ;;
      *"--query Account"*) printf '123456789012\n' ;;
      *) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/DirexioDeployer-Test"}\n' ;;
    esac
    ;;
  "ec2 terminate-instances") exit 0 ;;
  "ec2 wait") exit 0 ;;
  "ec2 release-address") exit 0 ;;
  "ec2 delete-security-group") exit 0 ;;
  "ec2 delete-key-pair") exit 0 ;;
  "ec2 describe-instances") printf 'terminated\n' ;;
  "ec2 describe-addresses") exit 255 ;;
  "ec2 describe-volumes") exit 255 ;;
  "ec2 describe-security-groups") exit 255 ;;
  "ec2 describe-key-pairs") exit 255 ;;
  "route53 change-resource-record-sets") printf '{"ChangeInfo":{"Id":"/change/CDELETE","Status":"PENDING"}}\n' ;;
  "route53 wait") exit 0 ;;
  "route53 list-resource-record-sets") printf '{"ResourceRecordSets":[]}\n' ;;
  "route53 delete-hosted-zone") exit 0 ;;
  "route53 get-hosted-zone") exit 255 ;;
  *) exit 0 ;;
esac
EOF
chmod 700 "$fakebin/aws"

cat > "$fakebin/direxio-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "status" ]; then
  cat <<STATUS
cc-connect daemon status

  Status:    Running
  WorkDir:   ${STATUS_WORK_DIR:-}
STATUS
fi
EOF
chmod 700 "$fakebin/direxio-connect"

mkdir -p "$service_dir/cc-connect"
PATH="$fakebin:$PATH" STATUS_WORK_DIR="$service_dir/cc-connect" bash "$ROOT/scripts/destroy.sh" "$state" >/dev/null
destroy_report="$HOME/.direxio/reports/report.example.test/operation-report.json"
assert_file_exists "$destroy_report"
assert_not_contains_secret "$destroy_report"

jq -e '
  .operation_type == "destroy"
  and .status == "destroy_processed"
  and .domain == "report.example.test"
  and .resources.instance_id == "i-report"
  and .resources.root_volume_id == "vol-report-root"
  and .resources.eip_id == "eipalloc-report"
  and .security.secrets_included == false
  and .destroy.user_managed_dns_not_removed == true
  and .destroy.purchased_domain_not_removed == true
  and .destroy.evidence.ec2_instance.status == "terminated"
  and .destroy.evidence.ebs_root_volume.status == "deleted"
  and .destroy.evidence.elastic_ip.status == "released"
  and .destroy.evidence.security_group.status == "deleted"
  and .destroy.evidence.key_pair.status == "deleted"
  and .destroy.evidence.route53_a_record.status == "deleted"
  and .destroy.evidence.route53_hosted_zone.status == "deleted"
  and .billing.destroy_cleanup_status == "no_recorded_billable_resource_residue"
  and (.billing.possible_remaining_billable_resources | length == 0)
' "$destroy_report" >/dev/null

residual_dir="$HOME/.direxio/nodes/residual.example.test"
mkdir -p "$residual_dir"
residual_state="$residual_dir/state.json"
jq -n \
  --arg residual_dir "$residual_dir" \
  '{
    domain: "residual.example.test",
    agent_service_id: "residual.example.test",
    agent_service_dir: $residual_dir,
    resources: {
      instance_id: "i-residual",
      root_volume_id: "vol-residual",
      eip_id: "eipalloc-residual",
      route53_zone_id: "ZRESIDUAL"
    },
    destroy_evidence: {
      ec2_instance: {status: "running"},
      ebs_root_volume: {status: "available"},
      elastic_ip: {status: "still_allocated"},
      route53_hosted_zone: {status: "still_present"}
    }
  }' > "$residual_state"

residual_report_output=$(P2P_WORKDIR="$residual_dir" bash "$ROOT/scripts/orchestrate.sh" report destroy)
residual_report_path=$(printf '%s\n' "$residual_report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
assert_file_exists "$residual_report_path"
jq -e '
  .operation_type == "destroy"
  and .billing.destroy_cleanup_status == "possible_billable_resource_residue"
  and (.billing.possible_remaining_billable_resources | index("EC2 i-residual status=running") != null)
  and (.billing.possible_remaining_billable_resources | index("EBS root volume vol-residual status=available") != null)
  and (.billing.possible_remaining_billable_resources | index("Elastic IP eipalloc-residual status=still_allocated") != null)
  and (.billing.possible_remaining_billable_resources | index("Route53 hosted zone ZRESIDUAL status=still_present") != null)
' "$residual_report_path" >/dev/null

echo "operation report ok"
