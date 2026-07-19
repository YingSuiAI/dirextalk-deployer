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
export AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN='arn:aws:iam::123456789012:role/dirextalk-foundation-control'
export AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID=Z0123456789ABCDEF
calls="$tmp/aws.calls"; : > "$calls"
mutations="$tmp/aws.mutations"; : > "$mutations"
grpc_calls="$tmp/grpc.calls"; : > "$grpc_calls"
principal_added="$tmp/principal-added"
ingress_added="$tmp/ingress-added"
service_absent="$tmp/service-absent"
listener_absent="$tmp/listener-absent"
target_group_absent="$tmp/target-group-absent"
nlb_absent="$tmp/nlb-absent"
sg_absent="$tmp/sg-absent"
certificate_absent="$tmp/certificate-absent"
export FAKE_NLB_SCHEME=internal
export FAKE_EXTRA_PRINCIPAL=
export FAKE_PRIVATE_DNS_STATE=verified
export FAKE_LISTENER_DELETE_NOT_FOUND=
export FAKE_DESTROY_ABSENT=
export FAKE_GRPC_HEALTH=healthy

aws() {
  printf '%s\n' "$*" >> "$calls"
  case "$2" in create-*|modify-*|authorize-*|register-*|delete-*|set-security-groups) printf '%s\n' "$*" >> "$mutations" ;; esac
  case "$1 $2" in
    'sts get-caller-identity')
      case " $* " in *' --query Account '*) printf '123456789012\n' ;; *) printf 'arn:aws:iam::123456789012:role/operator\n' ;; esac ;;
    'ec2 describe-instances')
      case " $* " in
        *'Reservations[0].Instances[0].PrivateIpAddress'*) printf '10.0.2.15\n' ;;
        *) printf '10.0.2.15\tvpc-0123456789abcdef0\tap-northeast-3a\n' ;;
      esac ;;
    'ec2 describe-vpcs') printf '10.0.0.0/16\n' ;;
    'route53 get-hosted-zone') printf 'y1.dirextalk.ai.\tfalse\n' ;;
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
          *'IpPermissions'*) [ ! -e "$ingress_added" ] || printf 'sg-nlb\n' ;;
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
    'elbv2 describe-target-groups') [ -z "$FAKE_DESTROY_ABSENT" ] && [ ! -e "$target_group_absent" ] && printf 'TLS\t9443\tip\tvpc-0123456789abcdef0\tTLS\n' || printf 'None\n' ;;
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
    'elbv2 describe-target-health') printf '10.0.2.15\t9443\thealthy\n' ;;
    'ec2 create-vpc-endpoint-service-configuration') printf 'vpce-svc-0123456789abcdef0\n' ;;
    'ec2 modify-vpc-endpoint-service-permissions') : > "$principal_added" ;;
    'ec2 describe-vpc-endpoint-service-configurations')
      if [ -n "$FAKE_DESTROY_ABSENT" ] || [ -e "$service_absent" ]; then printf 'None\n'
      else
        case " $* " in
          *'PrivateDnsNameConfiguration.State'*) printf '%s\n' "$FAKE_PRIVATE_DNS_STATE" ;;
          *'PrivateDnsNameConfiguration.Name'*) printf '_privatelink.worker-control.y1.dirextalk.ai.\n' ;;
          *'PrivateDnsNameConfiguration.Value'*) printf 'vpce:worker-control\n' ;;
          *'ServiceConfigurations[0].ServiceId'*) printf 'vpce-svc-0123456789abcdef0\n' ;;
          *'NetworkLoadBalancerArns'*) printf 'arn:aws:elasticloadbalancing:ap-northeast-3:123456789012:loadbalancer/net/worker/abc\n' ;;
          *) printf 'worker-control.y1.dirextalk.ai\tfalse\tAvailable\n' ;;
        esac
      fi ;;
    'ec2 describe-vpc-endpoint-service-permissions')
      [ ! -e "$principal_added" ] || printf '%s\n' "$AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN"
      [ -z "$FAKE_EXTRA_PRINCIPAL" ] || printf 'arn:aws:iam::123456789012:role/stale\n' ;;
    'ec2 describe-tags') printf 'dirextalk-deployer\n' ;;
    'ec2 describe-vpc-endpoint-connections') [ -z "${FAKE_ACTIVE_WORKER:-}" ] || printf 'vpce-worker-live\n' ;;
    'route53 list-resource-record-sets') printf 'None\n' ;;
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

agent_worker_control_enable
json_test=$(node -e "const s=require(process.argv[1]); process.exit(s.agent_worker_control.status==='ready' && s.agent_worker_control.target_private_ip==='10.0.2.15' && s.agent_worker_control.subnet_ids==='subnet-a,subnet-b' ? 0 : 1)" "$STATE_JSON")
[ -z "$json_test" ]
grep -Fq 'create-listener' "$calls"
grep -Fq -- '--alpn-policy HTTP2Only' "$calls"
grep -Fq -- '--health-check-protocol TLS' "$calls"
! grep -Fq -- '--health-check-protocol HTTPS' "$calls"
grep -Fq 'set-security-groups' "$calls"
grep -Fq -- '--enforce-security-group-inbound-rules-on-private-link-traffic off' "$calls"
grep -Fq -- '--subnets subnet-a subnet-b' "$calls"
! grep -Fq -- '--subnets subnet-z' "$calls"
[ "$(wc -l < "$grpc_calls")" -eq 1 ]
grep -Fq 'StrictHostKeyChecking=yes' "$grpc_calls"
! grep -Eiq 'token|service.?key|password|authorization' "$grpc_calls"
allow_line=$(grep -n 'modify-vpc-endpoint-service-permissions' "$calls" | head -n1 | cut -d: -f1)
accept_line=$(grep -n -- '--no-acceptance-required' "$calls" | head -n1 | cut -d: -f1)
[ "$allow_line" -lt "$accept_line" ]
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

# Authorization remains an exact singleton set; stale/additional principals
# cannot be hidden by re-adding the expected role.
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
