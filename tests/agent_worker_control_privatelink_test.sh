#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_HOME="$HOME/.dirextalk" DIREXTALK_WORKDIR="$tmp/state"
mkdir -p "$HOME"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/aws.sh"
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/agent-release.sh"
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/agent-worker-control.sh"

state_init
state_set cloud_provider ec2
state_set region ap-northeast-1
res_set instance_id i-0123456789abcdef0
res_set vpc_id vpc-0123456789abcdef0
res_set sg_id sg-agent
state_set_raw agent_release '{"enabled":true}'
state_set_raw agent_aws_control '{"enabled":true,"managed_preparation_aws":false}'
export AWS_DEFAULT_REGION=ap-northeast-1
export AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID=Z0123456789ABCDEF
calls="$tmp/aws.calls"; : > "$calls"
mutations="$tmp/aws.mutations"; : > "$mutations"
grpc_calls="$tmp/grpc.calls"; : > "$grpc_calls"
principal_added="$tmp/principal-added"
service_configured="$tmp/service-configured"
acceptance_disabled="$tmp/acceptance-disabled"
ingress_added="$tmp/ingress-added"
runtime_reconciled="$tmp/runtime-reconciled"
service_absent="$tmp/service-absent"
listener_absent="$tmp/listener-absent"
target_group_absent="$tmp/target-group-absent"
nlb_absent="$tmp/nlb-absent"
sg_absent="$tmp/sg-absent"
certificate_absent="$tmp/certificate-absent"
acm_record="$tmp/acm-record"
private_dns_record="$tmp/private-dns-record"
: > "$acm_record"
export FAKE_NLB_SCHEME=internal
export FAKE_EXTRA_PRINCIPAL=
export FAKE_PRIVATE_DNS_STATE=pending
export FAKE_ROUTE53_ZONE_NAME=y1.dirextalk.ai.
export FAKE_ROUTE53_PRIVATE_ZONE=false
export FAKE_ACM_RECORD_MODE=exact
export FAKE_PRIVATE_RECORD_MODE=exact
export FAKE_PUBLIC_RECORD_MODE=none
export FAKE_LISTENER_DELETE_NOT_FOUND=
export FAKE_DESTROY_ABSENT=
export FAKE_GRPC_HEALTH=healthy
export FAKE_INSTANCE_STATE=running
export FAKE_INSTANCE_GROUPS=sg-agent
export FAKE_SG_MODE=exact
export FAKE_HEALTH_PROTOCOL=TCP
export FAKE_HEALTH_PORT=9443
export FAKE_TARGET_HEALTH=healthy

fake_route53_records() {
  local -a records=()
  if [ -e "$acm_record" ]; then
    case "$FAKE_ACM_RECORD_MODE" in
      exact) records+=('{"Name":"_acm.worker-control.y1.dirextalk.ai.","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"_value.acm-validations.aws."}]}') ;;
      missing) ;;
      wrong_name) records+=('{"Name":"_other.worker-control.y1.dirextalk.ai.","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"_value.acm-validations.aws."}]}') ;;
      wrong_type) records+=('{"Name":"_acm.worker-control.y1.dirextalk.ai.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"_value.acm-validations.aws.\""}]}') ;;
      wrong_value) records+=('{"Name":"_acm.worker-control.y1.dirextalk.ai.","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"_wrong.acm-validations.aws."}]}') ;;
      extra_value) records+=('{"Name":"_acm.worker-control.y1.dirextalk.ai.","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"_value.acm-validations.aws."},{"Value":"_wrong.acm-validations.aws."}]}') ;;
      *) return 1 ;;
    esac
  fi
  if [ -e "$private_dns_record" ]; then
    case "$FAKE_PRIVATE_RECORD_MODE" in
      exact) records+=('{"Name":"_privatelink.worker-control.y1.dirextalk.ai.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"vpce:worker-control\""}]}') ;;
      missing) ;;
      wrong_name) records+=('{"Name":"_other.worker-control.y1.dirextalk.ai.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"vpce:worker-control\""}]}') ;;
      wrong_type) records+=('{"Name":"_privatelink.worker-control.y1.dirextalk.ai.","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"worker-control.y1.dirextalk.ai."}]}') ;;
      wrong_value) records+=('{"Name":"_privatelink.worker-control.y1.dirextalk.ai.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"vpce:wrong\""}]}') ;;
      extra_value) records+=('{"Name":"_privatelink.worker-control.y1.dirextalk.ai.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"vpce:worker-control\""},{"Value":"\"vpce:wrong\""}]}') ;;
      *) return 1 ;;
    esac
  fi
  case "$FAKE_PUBLIC_RECORD_MODE" in
    none) ;;
    a) records+=('{"Name":"worker-control.y1.dirextalk.ai.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"203.0.113.20"}]}') ;;
    aaaa) records+=('{"Name":"worker-control.y1.dirextalk.ai.","Type":"AAAA","TTL":60,"ResourceRecords":[{"Value":"2001:db8::20"}]}') ;;
    *) return 1 ;;
  esac
  local IFS=,
  printf '[%s]\n' "${records[*]}"
}

aws() {
  printf '%s\n' "$*" >> "$calls"
  case "$2" in create-*|modify-*|authorize-*|register-*|delete-*|set-security-groups) printf '%s\n' "$*" >> "$mutations" ;; esac
  case "$1 $2" in
    'sts get-caller-identity')
      case " $* " in *' --query Account '*) printf '123456789012\n' ;; *) printf 'arn:aws:iam::123456789012:role/operator\n' ;; esac ;;
    'ec2 describe-instances')
      case " $* " in
        *'SecurityGroups[].GroupId'*) printf '%s\n' "$FAKE_INSTANCE_GROUPS" ;;
        *) printf '10.0.2.15\tvpc-0123456789abcdef0\tap-northeast-3a\t%s\n' "$FAKE_INSTANCE_STATE" ;;
      esac ;;
    'ec2 describe-vpcs') printf '10.0.0.0/16\n' ;;
    'route53 get-hosted-zone') printf '%s\t%s\n' "$FAKE_ROUTE53_ZONE_NAME" "$FAKE_ROUTE53_PRIVATE_ZONE" ;;
    'route53 change-resource-record-sets')
      batch=
      for arg in "$@"; do
        case "$arg" in file://*) batch=${arg#file://} ;; esac
      done
      [ -n "$batch" ] && [ -f "$batch" ] || return 1
      if grep -Fq '"Type":"CNAME"' "$batch"; then
        if grep -Fq '"Action":"DELETE"' "$batch"; then rm -f "$acm_record"; else : > "$acm_record"; fi
      fi
      if grep -Fq '"Type":"TXT"' "$batch"; then
        if grep -Fq '"Action":"DELETE"' "$batch"; then rm -f "$private_dns_record"; else : > "$private_dns_record"; fi
      fi
      ;;
    'acm request-certificate') printf 'arn:aws:acm:ap-northeast-3:123456789012:certificate/cert-1\n' ;;
    'acm list-tags-for-certificate') printf 'dirextalk-deployer\n' ;;
    'acm describe-certificate')
      if [ -e "$certificate_absent" ]; then printf 'ResourceNotFoundException\n' >&2; return 255; fi
      case " $* " in
        *'Certificate.Status'*) printf 'ISSUED\n' ;;
        *'Certificate.DomainName'*) printf 'worker-control.y1.dirextalk.ai\n' ;;
        *'Certificate.SubjectAlternativeNames'*) printf 'worker-control.y1.dirextalk.ai\n' ;;
        *'ResourceRecord.Name'*) printf '_acm.worker-control.y1.dirextalk.ai.\n' ;;
        *) printf '_value.acm-validations.aws.\n' ;;
      esac ;;
    'ec2 create-security-group') printf 'sg-nlb\n' ;;
    'ec2 authorize-security-group-ingress') : > "$ingress_added" ;;
    'ec2 describe-security-groups')
      if [ -n "$FAKE_DESTROY_ABSENT" ] || [ -e "$sg_absent" ]; then printf 'None\n'
      else
        case " $* " in
          *'IpPermissions'*)
            if [ ! -e "$ingress_added" ]; then printf '[]\n'
            else
              case "$FAKE_SG_MODE" in
                exact) printf '[{"IpProtocol":"tcp","FromPort":9443,"ToPort":9443,"IpRanges":[],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[{"GroupId":"sg-nlb"}]}]\n' ;;
                broad) printf '[{"IpProtocol":"tcp","FromPort":9000,"ToPort":9500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[]},{"IpProtocol":"tcp","FromPort":9443,"ToPort":9443,"IpRanges":[],"Ipv6Ranges":[],"PrefixListIds":[],"UserIdGroupPairs":[{"GroupId":"sg-nlb"}]}]\n' ;;
              esac
            fi ;;
          *'SecurityGroups[0].VpcId'*) printf 'vpc-0123456789abcdef0\n' ;;
          *) printf 'sg-nlb\n' ;;
        esac
      fi ;;
    'ec2 describe-subnets') printf 'ap-northeast-3a\tsubnet-z\nap-northeast-3a\tsubnet-a\nap-northeast-3b\tsubnet-b\n' ;;
    'elbv2 create-load-balancer') printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:loadbalancer/net/worker/abc\n' ;;
    'elbv2 describe-load-balancers')
      if [ -n "$FAKE_DESTROY_ABSENT" ] || [ -e "$nlb_absent" ]; then printf 'None\n'
      else
        case " $* " in
          *'SecurityGroups'*) printf 'sg-nlb\n' ;;
          *'AvailabilityZones'*) printf 'subnet-a\tsubnet-b\n' ;;
          *'LoadBalancerArn'*) printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:loadbalancer/net/worker/abc\n' ;;
          *) printf '%s\tvpc-0123456789abcdef0\tnetwork\n' "$FAKE_NLB_SCHEME" ;;
        esac
      fi ;;
    'elbv2 describe-load-balancer-attributes') printf 'off\n' ;;
    'elbv2 describe-tags') printf 'dirextalk-deployer\n' ;;
    'elbv2 create-target-group') printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:targetgroup/worker/abc\n' ;;
    'elbv2 describe-target-groups') [ -z "$FAKE_DESTROY_ABSENT" ] && [ ! -e "$target_group_absent" ] && printf 'TLS\t9443\tip\tvpc-0123456789abcdef0\t%s\t%s\n' "$FAKE_HEALTH_PROTOCOL" "$FAKE_HEALTH_PORT" || printf 'None\n' ;;
    'elbv2 create-listener') printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:listener/net/worker/abc\n' ;;
    'elbv2 describe-listeners')
      if [ -n "$FAKE_DESTROY_ABSENT" ] || [ -e "$listener_absent" ]; then printf 'None\n'
      else
        case " $* " in
          *'DefaultActions'*) printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:targetgroup/worker/abc\n' ;;
          *'ListenerArn'*) printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:listener/net/worker/abc\n' ;;
          *) printf 'TLS\t443\tHTTP2Only\n' ;;
        esac
      fi ;;
    'elbv2 describe-listener-certificates') printf 'arn:aws:acm:ap-northeast-3:123456789012:certificate/cert-1\n' ;;
    'elbv2 describe-target-health') printf '10.0.2.15\t9443\t%s\n' "$FAKE_TARGET_HEALTH" ;;
    'ec2 create-vpc-endpoint-service-configuration') printf 'vpce-svc-0123456789abcdef0\tcom.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef0\n' ;;
    'ec2 modify-vpc-endpoint-service-permissions') : > "$principal_added" ;;
    'ec2 modify-vpc-endpoint-service-configuration')
      case " $* " in *' --no-acceptance-required '*) : > "$acceptance_disabled" ;; *) : > "$service_configured" ;; esac ;;
    'iam get-role') printf '%s\n' "$AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN" ;;
    'ec2 describe-vpc-endpoint-service-configurations')
      if [ -n "$FAKE_DESTROY_ABSENT" ] || [ -e "$service_absent" ]; then printf 'None\n'
      else
        case " $* " in
          *'PrivateDnsNameConfiguration.State'*) printf '%s\n' "$FAKE_PRIVATE_DNS_STATE" ;;
          *'PrivateDnsNameConfiguration.Name'*) printf '_privatelink.worker-control.y1.dirextalk.ai.\n' ;;
          *'PrivateDnsNameConfiguration.Value'*) printf 'vpce:worker-control\n' ;;
          *'ServiceConfigurations[0].ServiceId'*) printf 'vpce-svc-0123456789abcdef0\n' ;;
          *'NetworkLoadBalancerArns'*) printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:loadbalancer/net/worker/abc\n' ;;
          *)
            acceptance=true
            [ ! -e "$acceptance_disabled" ] || acceptance=false
            private_dns=None
            [ ! -e "$service_configured" ] || private_dns=worker-control.y1.dirextalk.ai
            printf '%s\t%s\tAvailable\tcom.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef0\n' "$private_dns" "$acceptance"
            ;;
        esac
      fi ;;
    'ec2 describe-vpc-endpoint-service-permissions')
      [ ! -e "$principal_added" ] || printf '%s\n' "$AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN"
      [ -z "$FAKE_EXTRA_PRINCIPAL" ] || printf 'arn:aws:iam::123456789012:role/stale\n' ;;
    'ec2 describe-tags') printf 'dirextalk-deployer\n' ;;
    'ec2 describe-vpc-endpoint-connections') [ -z "${FAKE_ACTIVE_WORKER:-}" ] || printf 'vpce-worker-live\n' ;;
    'route53 list-resource-record-sets') fake_route53_records ;;
    'ec2 delete-vpc-endpoint-service-configurations')
      [ -n "${FAKE_HOLD_SERVICE_PRESENT:-}" ] || : > "$service_absent" ;;
    'elbv2 delete-listener')
      if [ -n "$FAKE_LISTENER_DELETE_NOT_FOUND" ]; then
        : > "$listener_absent"
        printf 'ListenerNotFound\n' >&2
        return 255
      fi
      : > "$listener_absent" ;;
    'elbv2 delete-target-group') : > "$target_group_absent" ;;
    'elbv2 delete-load-balancer') : > "$nlb_absent" ;;
    'ec2 delete-security-group') : > "$sg_absent" ;;
    'acm delete-certificate') : > "$certificate_absent" ;;
  esac
}

ssh() {
  printf '%s\n' "$*" >> "$grpc_calls"
  printf '%s\n' "$FAKE_GRPC_HEALTH"
}

agent_worker_control_reconcile_runtime() {
  printf '%s\n' "$1" >> "$runtime_reconciled"
}

if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted a Region other than ap-northeast-3' >&2
  exit 1
fi
[ ! -s "$mutations" ]
state_set region ap-northeast-3
export AWS_DEFAULT_REGION=ap-northeast-3
res_set ec2_ssh_known_hosts "$tmp/known-hosts"
res_set key_file "$tmp/key.pem"
res_set public_ip 203.0.113.10
printf '203.0.113.10 ssh-ed25519 test\n' > "$tmp/known-hosts"
printf 'test-key\n' > "$tmp/key.pem"

# Stopped or detached instances fail before the first producer mutation.
FAKE_INSTANCE_STATE=stopped
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted a stopped Agent instance' >&2; exit 1
fi
[ ! -s "$mutations" ]
FAKE_INSTANCE_STATE=running
FAKE_INSTANCE_GROUPS=sg-other
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted an instance without the recorded Agent security group' >&2; exit 1
fi
[ ! -s "$mutations" ]
FAKE_INSTANCE_GROUPS=sg-agent

if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control skipped pending PrivateLink DNS ownership validation' >&2
  exit 1
else
  pending_status=$?
fi
[ "$pending_status" -eq 2 ]
[ "$(state_get agent_worker_control.status)" = dns_pending ]
export FAKE_PRIVATE_DNS_STATE=verified
agent_worker_control_enable
json_test=$(node -e "const s=require(process.argv[1]); process.exit(s.agent_worker_control.status==='provisioned' && s.agent_worker_control.foundation_role_arn==='' && s.agent_worker_control.endpoint_service_name==='com.amazonaws.vpce.ap-northeast-3.vpce-svc-0123456789abcdef0' && s.agent_aws_control.worker_control_endpoint_service_name===s.agent_worker_control.endpoint_service_name && s.agent_worker_control.target_private_ip==='10.0.2.15' && s.agent_worker_control.subnet_ids==='subnet-a,subnet-b' ? 0 : 1)" "$STATE_JSON")
[ -z "$json_test" ]
grep -Fq 'create-listener' "$calls"
grep -Fq -- '--alpn-policy HTTP2Only' "$calls"
grep -Fq -- '--health-check-protocol TCP --health-check-port 9443' "$calls"
grep -Fq 'set-security-groups' "$calls"
grep -Fq -- '--enforce-security-group-inbound-rules-on-private-link-traffic off' "$calls"
grep -Fq -- '--subnets subnet-a subnet-b' "$calls"
! grep -Fq -- '--subnets subnet-z' "$calls"
[ "$(wc -l < "$grpc_calls")" -eq 1 ]
[ "$(wc -l < "$runtime_reconciled")" -eq 2 ]
grep -Fq 'StrictHostKeyChecking=yes' "$grpc_calls"
! grep -Eiq 'token|service.?key|password|authorization' "$grpc_calls"
! grep -Fq 'modify-vpc-endpoint-service-permissions' "$calls"
! grep -Fq -- '--no-acceptance-required' "$calls"
grep -Fq -- '--acceptance-required --private-dns-name worker-control.y1.dirextalk.ai' "$calls"
if grep -Eq 'route53 change-resource-record-sets.*"Type":"(A|AAAA)"' "$calls"; then
  echo 'worker-control wrote a public record' >&2; exit 1
fi

before=$(wc -l < "$mutations")
agent_worker_control_enable
[ "$(wc -l < "$mutations")" -eq "$before" ]
[ "$(wc -l < "$grpc_calls")" -eq 2 ]
FAKE_GRPC_HEALTH=unhealthy
before=$(wc -l < "$mutations")
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control treated NLB target health as gRPC readiness' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_GRPC_HEALTH=healthy

# AWS rejecting the required TCP health contract and any broad/public rule
# covering 9443 both fail closed without producer mutation.
FAKE_HEALTH_PROTOCOL=TLS
before=$(wc -l < "$mutations")
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted TLS target health checks' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_HEALTH_PROTOCOL=TCP
FAKE_SG_MODE=broad
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted broad/public ingress coexisting with its exact rule' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_SG_MODE=exact

# A persisted target from a different private address is an unsafe recovery,
# so no load balancer mutation may occur on retry.
state_set agent_worker_control.target_private_ip 10.0.9.9
before=$(wc -l < "$calls")
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted a changed target mapping' >&2; exit 1
fi
if tail -n +$((before + 1)) "$calls" | grep -Eq 'create-|register-targets|modify-vpc-endpoint'; then
  echo 'worker-control mutated resources after target readback drift' >&2; exit 1
fi
state_set agent_worker_control.target_private_ip 10.0.2.15

# Every persisted producer identifier is reconciled before retry mutation.
FAKE_NLB_SCHEME=internet-facing
before=$(wc -l < "$mutations")
if agent_worker_control_enable >/dev/null 2>&1; then
  echo 'worker-control accepted NLB scheme drift' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_NLB_SCHEME=internal

# Authorization runs the complete producer readback immediately before every
# mutation, so post-enable infrastructure or Agent drift cannot open access.
export AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN='arn:aws:iam::123456789012:role/dirextalk-foundation-control'
before=$(wc -l < "$mutations")
FAKE_NLB_SCHEME=internet-facing
if agent_worker_control_authorize >/dev/null 2>&1; then
  echo 'worker-control authorized after post-enable NLB drift' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_NLB_SCHEME=internal
FAKE_TARGET_HEALTH=unhealthy
if agent_worker_control_authorize >/dev/null 2>&1; then
  echo 'worker-control authorized after post-enable target drift' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_TARGET_HEALTH=healthy
FAKE_SG_MODE=broad
if agent_worker_control_authorize >/dev/null 2>&1; then
  echo 'worker-control authorized after post-enable Agent ingress drift' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_SG_MODE=exact
FAKE_GRPC_HEALTH=unhealthy
if agent_worker_control_authorize >/dev/null 2>&1; then
  echo 'worker-control authorized after post-enable Agent gRPC drift' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_GRPC_HEALTH=healthy

# Every persisted DNS ownership proof is part of the pre-mutation
# authorization fence. AWS's trailing dots and quoted TXT are accepted, but
# any missing, wrong, conflicting, or public answer fails closed.
assert_dns_authorize_fails_without_mutation() {
  local label=$1 before
  before=$(wc -l < "$mutations")
  if agent_worker_control_authorize >/dev/null 2>&1; then
    echo "worker-control authorized after $label" >&2
    exit 1
  fi
  [ "$(wc -l < "$mutations")" -eq "$before" ]
}

for FAKE_ACM_RECORD_MODE in missing wrong_name wrong_type wrong_value extra_value; do
  export FAKE_ACM_RECORD_MODE
  assert_dns_authorize_fails_without_mutation "$FAKE_ACM_RECORD_MODE ACM CNAME drift"
done
export FAKE_ACM_RECORD_MODE=exact
for FAKE_PRIVATE_RECORD_MODE in missing wrong_name wrong_type wrong_value extra_value; do
  export FAKE_PRIVATE_RECORD_MODE
  assert_dns_authorize_fails_without_mutation "$FAKE_PRIVATE_RECORD_MODE PrivateLink TXT drift"
done
export FAKE_PRIVATE_RECORD_MODE=exact
export FAKE_ROUTE53_ZONE_NAME=wrong.test.
assert_dns_authorize_fails_without_mutation 'persisted Route 53 zone drift'
export FAKE_ROUTE53_ZONE_NAME=y1.dirextalk.ai.
export FAKE_PUBLIC_RECORD_MODE=a
assert_dns_authorize_fails_without_mutation 'public A publication'
export FAKE_PUBLIC_RECORD_MODE=aaaa
assert_dns_authorize_fails_without_mutation 'public AAAA publication'
export FAKE_PUBLIC_RECORD_MODE=none

# Authorization is the separate exact-role transition and is retry-idempotent.
agent_worker_control_authorize
[ "$(state_get agent_worker_control.status)" = ready ]
grep -Fq 'modify-vpc-endpoint-service-permissions' "$calls"
grep -Fq -- '--no-acceptance-required' "$calls"
state_set agent_worker_control.status provisioned
rm -f "$acceptance_disabled"
permission_mutations=$(grep -c 'modify-vpc-endpoint-service-permissions' "$mutations")
agent_worker_control_authorize
[ "$(state_get agent_worker_control.status)" = ready ]
[ "$(grep -c 'modify-vpc-endpoint-service-permissions' "$mutations")" = "$permission_mutations" ]
before=$(wc -l < "$mutations")
agent_worker_control_authorize
[ "$(wc -l < "$mutations")" -eq "$before" ]

# Authorization remains an exact singleton set; stale/additional principals
# are refused on readback.
FAKE_EXTRA_PRINCIPAL=1
before=$(wc -l < "$mutations")
if agent_worker_control_authorize >/dev/null 2>&1; then
  echo 'worker-control accepted an additional endpoint-service principal' >&2; exit 1
fi
[ "$(wc -l < "$mutations")" -eq "$before" ]
FAKE_EXTRA_PRINCIPAL=

# Parent destroy must retain the producer while a Worker connection exists.
FAKE_EXTRA_PRINCIPAL=
export FAKE_ACTIVE_WORKER=1
if agent_worker_control_destroy >/dev/null 2>&1; then
  echo 'worker-control destroy accepted an active Worker endpoint' >&2; exit 1
fi
if tail -n +$((before + 1)) "$calls" | grep -Eq 'delete-(vpc-endpoint-service|listener|target-group|load-balancer|security-group|certificate)'; then
  echo 'worker-control destroy deleted billed resources while a Worker was active' >&2; exit 1
fi

# A not-found response from a partial prior destroy is success, and state is
# retained until every owned resource and record has an absent readback.
unset FAKE_ACTIVE_WORKER
export FAKE_HOLD_SERVICE_PRESENT=1
if agent_worker_control_destroy >/dev/null 2>&1; then
  echo 'worker-control cleared state before endpoint-service absence readback' >&2; exit 1
fi
[ "$(state_get agent_worker_control.status)" = destroying ]
[ -n "$(state_get agent_worker_control.endpoint_service_id)" ]
unset FAKE_HOLD_SERVICE_PRESENT
FAKE_LISTENER_DELETE_NOT_FOUND=1
if ! agent_worker_control_destroy; then
  echo 'worker-control did not tolerate a prior listener deletion' >&2; exit 1
fi
FAKE_LISTENER_DELETE_NOT_FOUND=
FAKE_DESTROY_ABSENT=1
agent_worker_control_destroy
[ -z "$(state_get agent_worker_control.status)" ]

echo 'worker-control PrivateLink producer boundary ok'
