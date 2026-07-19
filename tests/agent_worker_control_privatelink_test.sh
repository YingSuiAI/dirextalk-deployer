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
state_set region us-east-1
res_set instance_id i-0123456789abcdef0
res_set vpc_id vpc-0123456789abcdef0
res_set sg_id sg-agent
state_set_raw agent_release '{"enabled":true}'
state_set_raw agent_aws_control '{"enabled":true,"managed_preparation_aws":false}'
export AWS_DEFAULT_REGION=us-east-1
export AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN='arn:aws:iam::123456789012:role/dirextalk-foundation-control'
export AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID=Z0123456789ABCDEF
calls="$tmp/aws.calls"; : > "$calls"

aws() {
  printf '%s\n' "$*" >> "$calls"
  case "$1 $2" in
    'sts get-caller-identity')
      case " $* " in *' --query Account '*) printf '123456789012\n' ;; *) printf 'arn:aws:iam::123456789012:role/operator\n' ;; esac ;;
    'ec2 describe-instances') printf '10.0.2.15\n' ;;
    'ec2 describe-vpcs') printf '10.0.0.0/16\n' ;;
    'acm request-certificate') printf 'arn:aws:acm:us-east-1:123456789012:certificate/cert-1\n' ;;
    'acm describe-certificate')
      case " $* " in *'Certificate.Status'*) printf 'ISSUED\n' ;; *'ResourceRecord.Name'*) printf '_acm.worker-control.y1.dirextalk.ai.\n' ;; *) printf '_value.acm-validations.aws.\n' ;; esac ;;
    'ec2 create-security-group') printf 'sg-nlb\n' ;;
    'ec2 describe-subnets') printf 'subnet-a\tsubnet-b\n' ;;
    'elbv2 create-load-balancer') printf 'arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/worker/abc\n' ;;
    'elbv2 create-target-group') printf 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/worker/abc\n' ;;
    'elbv2 create-listener') printf 'arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/net/worker/abc\n' ;;
    'elbv2 describe-target-health') printf 'healthy\n' ;;
    'ec2 create-vpc-endpoint-service-configuration') printf 'vpce-svc-0123456789abcdef0\n' ;;
    'ec2 describe-vpc-endpoint-service-configurations')
      case " $* " in *'PrivateDnsNameConfiguration.State'*) printf 'verified\n' ;; *'PrivateDnsNameConfiguration.Name'*) printf '_privatelink.worker-control.y1.dirextalk.ai.\n' ;; *) printf 'vpce:worker-control\n' ;; esac ;;
    'ec2 describe-vpc-endpoint-service-permissions') printf '%s\n' "$AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN" ;;
    'ec2 describe-vpc-endpoint-connections') printf '\n' ;;
  esac
}

agent_worker_control_enable
json_test=$(node -e "const s=require(process.argv[1]); process.exit(s.agent_worker_control.status==='ready' && s.agent_worker_control.target_private_ip==='10.0.2.15' ? 0 : 1)" "$STATE_JSON")
[ -z "$json_test" ]
grep -Fq 'create-listener' "$calls"
grep -Fq -- '--alpn-policy HTTP2Only' "$calls"
grep -Fq 'set-security-groups' "$calls"
grep -Fq -- '--enforce-security-group-inbound-rules-on-private-link-traffic off' "$calls"
allow_line=$(grep -n 'modify-vpc-endpoint-service-permissions' "$calls" | head -n1 | cut -d: -f1)
accept_line=$(grep -n -- '--no-acceptance-required' "$calls" | head -n1 | cut -d: -f1)
[ "$allow_line" -lt "$accept_line" ]
if grep -Eq 'route53 change-resource-record-sets.*"Type":"(A|AAAA)"' "$calls"; then
  echo 'worker-control wrote a public record' >&2; exit 1
fi

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

# Parent destroy must retain the producer while a Worker connection exists.
aws() {
  printf '%s\n' "$*" >> "$calls"
  case "$1 $2" in
    'sts get-caller-identity')
      case " $* " in *' --query Account '*) printf '123456789012\n' ;; *) printf 'arn:aws:iam::123456789012:role/operator\n' ;; esac ;;
    'ec2 describe-vpc-endpoint-connections') printf 'vpce-worker-live\n' ;;
  esac
}
if agent_worker_control_destroy >/dev/null 2>&1; then
  echo 'worker-control destroy accepted an active Worker endpoint' >&2; exit 1
fi
if tail -n +$((before + 1)) "$calls" | grep -Eq 'delete-(vpc-endpoint-service|listener|target-group|load-balancer|security-group|certificate)'; then
  echo 'worker-control destroy deleted billed resources while a Worker was active' >&2; exit 1
fi

echo 'worker-control PrivateLink producer boundary ok'
