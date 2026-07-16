#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export MSYS_NO_PATHCONV=1

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
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

service_dir="$HOME/.dirextalk/nodes/report.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
json_build object \
  run_id=report-test \
  region=ap-northeast-1 \
  domain_mode=route53 \
  domain=report.example.test \
  as_url=https://report.example.test \
  instance_type=t3.small \
  password=12345678 \
  access_token=ACCESS_SECRET \
  agent_token=AGENT_SECRET \
  'agent_room_id=!room:report.example.test' \
  agent_node_id=node-report \
  agent_runtime=openclaw \
  agent_service_id=report.example.test \
  "agent_service_dir=$service_dir" \
  "agent_credentials_file=$service_dir/credentials.json" \
  "connect_config=$service_dir/dirextalk-connect/config.toml" \
  connect_agent=acp \
  connect_npm_package=dirextalk-connect@latest \
  'server_release={"source":"default_latest","version":"latest","image":"dirextalk/message-server:latest","digest":"","image_ref":"dirextalk/message-server:latest","manifest_digest":""}' \
  'updater_release={"version":"v1.0.6","commit":"586f5ee82f1697269cfd764545198d88707734b8","sha256":"fc25f8ff811313dfc18c2b4e0f01b46802697385b24395f9c78e634e5ac426e4","asset":"dirextalk-updater-linux-amd64","os":"linux","arch":"amd64","ubuntu_version":"24.04"}' \
  mcp_transport=http \
  mcp_capability=host-managed \
  mcp_install_status=host_probe_passed \
  mcp_host_probe_status=passed \
  mcp_endpoint_url=https://report.example.test/mcp \
  mcp_server_name=dirextalk-report-example-test \
  "mcp_config_dir=$service_dir/mcp" \
  "mcp_openclaw_config=$service_dir/mcp/openclaw.md" \
  mcp_selected_config_type=openclaw \
  "mcp_selected_config=$service_dir/mcp/openclaw.md" \
  "mcp_hermes_config=$service_dir/mcp/hermes.md" \
  'mcp_doctor_command=DOMAIN=report.example.test bash scripts/orchestrate.sh verify mcp_doctor' \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'runtime_checks={"summary":{"status":"passed"},"connect_daemon":{"status":"passed"},"mcp_doctor":{"status":"passed"},"mcp_tools":{"status":"passed"},"mcp_smoke":{"status":"passed"}}' \
  'user_confirmations={"app_initialization":{"status":"confirmed","ts":"2026-06-28T01:02:03Z","evidence":"user completed app initialization with code 12345678; old screenshot showed code 87654321"},"real_chat":{"status":"confirmed","ts":"2026-06-28T01:03:04Z","evidence":"user saw the agent reply; token ACCESS_SECRET stayed local"},"agent_mcp_runtime":{"status":"confirmed","ts":"2026-06-28T01:04:05Z","evidence":"runtime channel probe confirmed with agent token AGENT_SECRET","runtime_summary_status":"passed","runtime_probe_confirmed":true}}' \
  'resources={"instance_id":"i-report","root_volume_id":"vol-report-root","public_ip":"203.0.113.42","eip_id":"eipalloc-report","route53_zone_id":"ZREPORT","route53_zone_name":"report.example.test","route53_zone_created_by_deployer":"true","route53_existing_a_value":"198.51.100.20","route53_pending_a_value":"203.0.113.42","route53_overwrite_confirmed":"true","sg_id":"sg-report","key_name":"dirextalk-report"}' > "$state"

report_output=$(DIREXTALK_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
assert_file_exists "$report_path"
assert_not_contains_secret "$report_path"

json_test_check "$report_path" "data.operation_type === 'new_deploy' && data.status === 'deployment_complete' && data.domain === 'report.example.test' && data.delivery.app_domain === 'report.example.test' && !('service_url' in data.delivery) && data.delivery.init_code_status === 'available_in_state_password_field_redacted' && data.delivery.init_code_secret_redacted === true && data.delivery.product_completion_status === 'deployment_complete' && data.agent.node_id === 'node-report' && data.agent.room_id === '!room:report.example.test' && data.agent.runtime === 'openclaw' && data.release.source === 'default_latest' && data.release.version === 'latest' && data.release.digest === '' && data.release.image_ref === 'dirextalk/message-server:latest' && data.release.manifest_digest === '' && data.updater_release.version === 'v1.0.6' && data.updater_release.commit === '586f5ee82f1697269cfd764545198d88707734b8' && data.updater_release.sha256 === 'fc25f8ff811313dfc18c2b4e0f01b46802697385b24395f9c78e634e5ac426e4' && data.updater_release.os === 'linux' && data.updater_release.arch === 'amd64' && data.updater_release.ubuntu_version === '24.04' && data.gates.automated.S7_VERIFY_E2E === 'done' && data.gates.user_confirmation.app_initialization === 'not_required' && data.gates.user_confirmation.real_chat === 'not_required' && data.gates.user_confirmation.agent_mcp_runtime === 'not_required' && data.gates.user_confirmation_details.agent_mcp_runtime.runtime_summary_status === 'passed' && data.credentials.values_redacted === true && data.security.secrets_included === false && data.mcp.transport === 'http' && data.mcp.capability === 'host-managed' && data.mcp.install_status === 'host_probe_passed' && data.mcp.host_probe_status === 'passed' && data.mcp.selected_config_type === 'openclaw' && data.mcp.selected_config.endsWith('/mcp/openclaw.md') && data.mcp.endpoint_url === 'https://report.example.test/mcp' && data.resources.route53_zone_id === 'ZREPORT' && data.resources.route53_zone_name === 'report.example.test' && data.resources.route53_existing_a_value === '198.51.100.20' && data.resources.route53_pending_a_value === '203.0.113.42' && data.resources.route53_overwrite_confirmed === 'true' && data.resources.root_volume_id === 'vol-report-root' && data.billing.recorded_billable_resources.includes('EC2 i-report') && data.billing.recorded_billable_resources.includes('EBS root volume vol-report-root') && data.billing.recorded_billable_resources.includes('public IPv4 203.0.113.42') && data.billing.recorded_billable_resources.includes('Route53 hosted zone ZREPORT') && data.security.root_access_key_allowed === true && data.security.temporary_iam_cleanup_required === true && data.security.temporary_iam_cleanup_action.includes('delete or disable')"
json_test_check "$report_path" "data.mcp && !('daemon_install_status' in data.mcp) && !('daemon_url' in data.mcp) && !('daemon_status' in data.mcp) && !('daemon_proxy' in data.mcp)"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$AWS_CALLS"
printf ' %q' "$@" >> "$AWS_CALLS"
printf '\n' >> "$AWS_CALLS"
case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    case "$*" in
      *"--query Arn"*) printf 'arn:aws:iam::123456789012:user/DirextalkDeployer-Test\n' ;;
      *"--query Account"*) printf '123456789012\n' ;;
      *) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/DirextalkDeployer-Test"}\n' ;;
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

cat > "$fakebin/dirextalk-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "status" ]; then
  cat <<STATUS
dirextalk-connect daemon status

  Status:    Running
  WorkDir:   ${STATUS_WORK_DIR:-}
STATUS
fi
EOF
chmod 700 "$fakebin/dirextalk-connect"

mkdir -p "$service_dir/dirextalk-connect"
export AWS_CALLS="$tmp/destroy-aws.calls"
: > "$AWS_CALLS"
PATH="$fakebin:$PATH" STATUS_WORK_DIR="$service_dir/dirextalk-connect" bash "$ROOT/scripts/destroy.sh" "$state" >/dev/null
destroy_report="$HOME/.dirextalk/reports/report.example.test/operation-report.json"
assert_file_exists "$destroy_report"
assert_not_contains_secret "$destroy_report"

json_test_check "$destroy_report" "data.operation_type === 'destroy' && data.status === 'destroy_processed' && data.domain === 'report.example.test' && data.resources.instance_id === 'i-report' && data.resources.root_volume_id === 'vol-report-root' && data.resources.eip_id === 'eipalloc-report' && data.security.secrets_included === false && data.destroy.user_managed_dns_not_removed === true && data.destroy.purchased_domain_not_removed === true && data.destroy.evidence.ec2_instance.status === 'terminated' && data.destroy.evidence.ebs_root_volume.status === 'deleted' && data.destroy.evidence.elastic_ip.status === 'released' && data.destroy.evidence.security_group.status === 'deleted' && data.destroy.evidence.key_pair.status === 'deleted' && data.destroy.evidence.route53_a_record.status === 'deleted' && data.destroy.evidence.route53_hosted_zone.status === 'deleted' && data.billing.destroy_cleanup_status === 'no_recorded_billable_resource_residue' && data.billing.possible_remaining_billable_resources.length === 0"
grep -q '^aws route53 change-resource-record-sets --hosted-zone-id ZREPORT' "$AWS_CALLS"
grep -q '^aws route53 delete-hosted-zone --id ZREPORT$' "$AWS_CALLS"
case "$(uname -s 2>/dev/null || printf unknown)" in
  *MINGW*|*MSYS*|*CYGWIN*)
    grep -Eq -- '--change-batch file://[A-Za-z]:/' "$AWS_CALLS"
    ;;
esac

residual_dir="$HOME/.dirextalk/nodes/residual.example.test"
mkdir -p "$residual_dir"
residual_state="$residual_dir/state.json"
json_build object \
  domain=residual.example.test \
  agent_service_id=residual.example.test \
  "agent_service_dir=$residual_dir" \
  'resources={"instance_id":"i-residual","root_volume_id":"vol-residual","eip_id":"eipalloc-residual","route53_zone_id":"ZRESIDUAL"}' \
  'destroy_evidence={"ec2_instance":{"status":"running"},"ebs_root_volume":{"status":"available"},"elastic_ip":{"status":"still_allocated"},"route53_hosted_zone":{"status":"still_present"}}' > "$residual_state"

residual_report_output=$(DIREXTALK_WORKDIR="$residual_dir" bash "$ROOT/scripts/orchestrate.sh" report destroy)
residual_report_path=$(printf '%s\n' "$residual_report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
assert_file_exists "$residual_report_path"
json_test_check "$residual_report_path" "data.operation_type === 'destroy' && data.billing.destroy_cleanup_status === 'possible_billable_resource_residue' && data.billing.possible_remaining_billable_resources.includes('EC2 i-residual status=running') && data.billing.possible_remaining_billable_resources.includes('EBS root volume vol-residual status=available') && data.billing.possible_remaining_billable_resources.includes('Elastic IP eipalloc-residual status=still_allocated') && data.billing.possible_remaining_billable_resources.includes('Route53 hosted zone ZRESIDUAL status=still_present')"

echo "operation report ok"
