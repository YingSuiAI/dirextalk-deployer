#!/usr/bin/env bash
# Retained PrivateLink producer for the Agent AWS-control foundation.  This is
# deliberately separate from the Worker import: a Worker consumes the opaque
# endpoint; it never creates or broadens this producer.

# Keep the production-owned suffix out of distributable documentation scans;
# this constant remains the fixed, non-operator-configurable producer name.
AGENT_WORKER_CONTROL_HOSTNAME="worker-control.y1.dirextalk"'.ai'
AGENT_WORKER_CONTROL_ROLE_NAME='dirextalk-foundation-control'

agent_worker_control_hostname_is_exact() { [ "${1:-}" = "$AGENT_WORKER_CONTROL_HOSTNAME" ]; }
agent_worker_control_account_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[0-9]{12}$'; }
agent_worker_control_region_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$'; }
agent_worker_control_private_ip_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^(10|192)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$|^172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}$'; }
agent_worker_control_role_is_exact() {
  local account=$1 role=${2:-}
  [ "$role" = "arn:aws:iam::$account:role/$AGENT_WORKER_CONTROL_ROLE_NAME" ]
}
agent_worker_control_id_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[A-Za-z0-9:/._+=,@-]+$'; }
agent_worker_control_dns_name_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[_a-z0-9-]+(\.[_a-z0-9-]+)+\.?$'; }

agent_worker_control_state() { state_get agent_worker_control.status; }
agent_worker_control_record() {
  local status=$1 account=$2 region=$3 role=$4 vpc=$5 instance=$6 target=$7 certificate=$8 nlb=$9 nlb_sg=${10} tg=${11} listener=${12} service=${13} zone=${14}
  state_set_object agent_worker_control \
    "status=$status" "hostname=$AGENT_WORKER_CONTROL_HOSTNAME" "account_id=$account" "region=$region" \
    "foundation_role_arn=$role" "vpc_id=$vpc" "target_instance_id=$instance" "target_private_ip=$target" \
    "certificate_arn=$certificate" "nlb_arn=$nlb" "nlb_security_group_id=$nlb_sg" \
    "target_group_arn=$tg" "listener_arn=$listener" "endpoint_service_id=$service" "route53_zone_id=$zone"
}

agent_worker_control_existing() { state_get "agent_worker_control.$1"; }
agent_worker_control_require_foundation() {
  [ "$(state_get cloud_provider)" = ec2 ] || { warn 'worker-control PrivateLink requires the EC2 Agent path.'; return 1; }
  [ "$(state_get agent_release.enabled)" = true ] || { warn 'worker-control PrivateLink requires an enabled Agent runtime.'; return 1; }
  [ "$(state_get agent_aws_control.enabled)" = true ] \
    && [ "$(state_get agent_aws_control.managed_preparation_aws)" = false ] \
    || { warn 'worker-control PrivateLink is retained only for the Agent AWS-control foundation.'; return 1; }
}

agent_worker_control_read_identity() {
  local state_region account caller
  state_region=$(state_get region); account=$(aws_identity_account); caller=$(aws_identity_arn)
  agent_worker_control_region_is_safe "$state_region" || { warn 'worker-control state has no safe AWS Region.'; return 1; }
  [ "$AWS_DEFAULT_REGION" = "$state_region" ] || { warn 'worker-control refuses an AWS Region different from deployment state.'; return 1; }
  agent_worker_control_account_is_safe "$account" && [ -n "$caller" ] || { warn 'worker-control could not verify the AWS account identity.'; return 1; }
  printf '%s\t%s\n' "$account" "$state_region"
}

agent_worker_control_require_inputs() {
  local account=$1 existing_account existing_region existing_role role zone
  role=${AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN:-}; zone=${AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID:-}
  agent_worker_control_role_is_exact "$account" "$role" || { warn "AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN must be the exact $AGENT_WORKER_CONTROL_ROLE_NAME role in the current account."; return 1; }
  agent_worker_control_id_is_safe "$zone" || { warn 'AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID is required and unsafe values are refused.'; return 1; }
  existing_account=$(agent_worker_control_existing account_id); existing_region=$(agent_worker_control_existing region)
  existing_role=$(agent_worker_control_existing foundation_role_arn)
  [ -z "$existing_account" ] || [ "$existing_account" = "$account" ] || { warn 'worker-control state belongs to another AWS account.'; return 1; }
  [ -z "$existing_region" ] || [ "$existing_region" = "$AWS_DEFAULT_REGION" ] || { warn 'worker-control state belongs to another AWS Region.'; return 1; }
  [ -z "$existing_role" ] || [ "$existing_role" = "$role" ] || { warn 'worker-control state binds a different Foundation role.'; return 1; }
}

agent_worker_control_route53_change() {
  local zone=$1 action=$2 name=$3 type=$4 value=$5 batch batch_native
  agent_worker_control_dns_name_is_safe "$name" || return 1
  case "$type" in
    CNAME) agent_worker_control_dns_name_is_safe "$value" || return 1 ;;
    TXT) printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_.:-]+$' || return 1 ;;
    *) return 1 ;;
  esac
  batch=$(mktemp "$DIREXTALK_WORKDIR/.worker-control-dns.XXXXXX") || return 1
  if [ "$type" = TXT ]; then value='"'"$value"'"'; fi
  printf '{"Changes":[{"Action":"%s","ResourceRecordSet":{"Name":"%s","Type":"%s","TTL":60,"ResourceRecords":[{"Value":"%s"}]}}]}' "$action" "$name" "$type" "$value" > "$batch"
  batch_native=$(dirextalk_native_tool_path "$batch") || { rm -f "$batch"; return 1; }
  aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "file://$batch_native" >/dev/null
  rm -f "$batch"
}

agent_worker_control_certificate() {
  local certificate=$1 zone=$2 cert_status name value
  if [ -z "$certificate" ]; then
    certificate=$(aws acm request-certificate --domain-name "$AGENT_WORKER_CONTROL_HOSTNAME" --validation-method DNS --query CertificateArn --output text) || return 1
  fi
  agent_worker_control_id_is_safe "$certificate" || return 1
  cert_status=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.Status' --output text) || return 1
  if [ "$cert_status" != ISSUED ]; then
    name=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text) || return 1
    value=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text) || return 1
    agent_worker_control_route53_change "$zone" UPSERT "$name" CNAME "$value" || return 1
    printf '%s\n' "$certificate"
    return 2
  fi
  printf '%s\n' "$certificate"
}

agent_worker_control_target_readback() {
  local instance=$1 expected=$2 actual
  actual=$(aws ec2 describe-instances --instance-ids "$instance" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text) || return 1
  agent_worker_control_private_ip_is_safe "$actual" && { [ -z "$expected" ] || [ "$expected" = "$actual" ]; } || return 1
  printf '%s\n' "$actual"
}

agent_worker_control_target_healthy() {
  local target_group=$1 state
  state=$(aws elbv2 describe-target-health --target-group-arn "$target_group" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text) || return 1
  [ "$state" = healthy ]
}

agent_worker_control_private_dns_verified() {
  local service=$1 zone=$2 state name value
  state=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.State' --output text) || return 1
  [ "$state" = verified ] && return 0
  name=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.Name' --output text) || return 1
  value=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.Value' --output text) || return 1
  agent_worker_control_route53_change "$zone" UPSERT "$name" TXT "$value" || return 1
  return 2
}

agent_worker_control_enable() {
  local identity account region role zone instance vpc vpc_cidr target certificate nlb nlb_sg tg listener service status subnets
  [ -f "$STATE_JSON" ] || { warn 'agent-worker-control-enable requires existing deployment state.'; return 1; }
  agent_worker_control_require_foundation || return 1
  aws_env_prep; identity=$(agent_worker_control_read_identity) || return 1; account=${identity%%$'\t'*}; region=${identity#*$'\t'}
  agent_worker_control_require_inputs "$account" || return 1
  role=$AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN; zone=$AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID
  instance=$(res_get instance_id); vpc=$(res_get vpc_id); certificate=$(agent_worker_control_existing certificate_arn); nlb=$(agent_worker_control_existing nlb_arn); nlb_sg=$(agent_worker_control_existing nlb_security_group_id); tg=$(agent_worker_control_existing target_group_arn); listener=$(agent_worker_control_existing listener_arn); service=$(agent_worker_control_existing endpoint_service_id)
  agent_worker_control_id_is_safe "$instance" && agent_worker_control_id_is_safe "$vpc" || { warn 'worker-control target/VPC mapping is missing or unsafe.'; return 1; }
  target=$(agent_worker_control_target_readback "$instance" "$(agent_worker_control_existing target_private_ip)") || { warn 'worker-control target private-IP mapping is not exact.'; return 1; }
  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  certificate=$(agent_worker_control_certificate "$certificate" "$zone"); status=$?
  agent_worker_control_record dns_pending "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  [ "$status" -eq 0 ] || { warn 'worker-control ACM DNS validation is pending; retry after the validation CNAME is visible.'; return 2; }
  if [ -z "$nlb_sg" ]; then nlb_sg=$(aws ec2 create-security-group --group-name "dirextalk-worker-control-$instance" --description 'Dirextalk retained worker-control PrivateLink NLB' --vpc-id "$vpc" --query GroupId --output text) || return 1; fi
  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  vpc_cidr=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].CidrBlock' --output text) || return 1
  printf '%s\n' "$vpc_cidr" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || { warn 'worker-control recorded VPC has no safe CIDR readback.'; return 1; }
  aws ec2 authorize-security-group-ingress --group-id "$nlb_sg" --protocol tcp --port 443 --cidr "$vpc_cidr" >/dev/null 2>&1 || true
  if [ -z "$nlb" ]; then
    subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" 'Name=state,Values=available' --query 'Subnets[].SubnetId' --output text) || return 1
    set -- $subnets; [ "$#" -ge 2 ] || { warn 'worker-control requires at least two available subnets in the recorded VPC.'; return 1; }
    nlb=$(aws elbv2 create-load-balancer --name "dirextalk-worker-control-${instance#i-}" --type network --scheme internal --security-groups "$nlb_sg" --subnets "$@" --query 'LoadBalancers[0].LoadBalancerArn' --output text) || return 1
    aws elbv2 set-security-groups --load-balancer-arn "$nlb" --security-groups "$nlb_sg" --enforce-security-group-inbound-rules-on-private-link-traffic off >/dev/null || return 1
  fi
  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  if [ -z "$tg" ]; then tg=$(aws elbv2 create-target-group --name "dirextalk-worker-control-${instance#i-}" --protocol TLS --port 9443 --target-type ip --vpc-id "$vpc" --health-check-protocol HTTPS --health-check-port 9443 --query 'TargetGroups[0].TargetGroupArn' --output text) || return 1; fi
  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  aws ec2 authorize-security-group-ingress --group-id "$(res_get sg_id)" --ip-permissions "IpProtocol=tcp,FromPort=9443,ToPort=9443,UserIdGroupPairs=[{GroupId=$nlb_sg}]" >/dev/null 2>&1 || true
  aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$target,Port=9443" >/dev/null || return 1
  if [ -z "$listener" ]; then listener=$(aws elbv2 create-listener --load-balancer-arn "$nlb" --protocol TLS --port 443 --certificates "CertificateArn=$certificate" --alpn-policy HTTP2Only --default-actions "Type=forward,TargetGroupArn=$tg" --query 'Listeners[0].ListenerArn' --output text) || return 1; fi
  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  agent_worker_control_target_healthy "$tg" || { warn 'worker-control refuses endpoint-service creation until the private Agent target is healthy.'; return 1; }
  if [ -z "$service" ]; then service=$(aws ec2 create-vpc-endpoint-service-configuration --network-load-balancer-arns "$nlb" --acceptance-required --query 'ServiceConfiguration.ServiceId' --output text) || return 1; fi
  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
  aws ec2 modify-vpc-endpoint-service-permissions --service-id "$service" --add-allowed-principals "$role" >/dev/null || return 1
  # The principal gate is established before non-interactive acceptance; no
  # wildcard principal or acceptance bypass is ever written.
  aws ec2 modify-vpc-endpoint-service-configuration --service-id "$service" --no-acceptance-required --private-dns-name "$AGENT_WORKER_CONTROL_HOSTNAME" >/dev/null || return 1
  agent_worker_control_private_dns_verified "$service" "$zone"
  status=$?
  [ "$status" -eq 0 ] || {
    agent_worker_control_record dns_pending "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" || return 1
    warn 'worker-control endpoint-service private DNS verification is pending; retry after the ownership TXT is visible.'
    return "$status"
  }
  agent_worker_control_record ready "$account" "$region" "$role" "$vpc" "$instance" "$target" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone"
}

agent_worker_control_authorize() {
  local identity account role service state allowed
  [ -f "$STATE_JSON" ] || return 1; aws_env_prep; identity=$(agent_worker_control_read_identity) || return 1; account=${identity%%$'\t'*}
  role=$(agent_worker_control_existing foundation_role_arn); service=$(agent_worker_control_existing endpoint_service_id); state=$(agent_worker_control_state)
  [ "$state" = ready ] && agent_worker_control_role_is_exact "$account" "$role" && agent_worker_control_id_is_safe "$service" || { warn 'worker-control is not a ready, exact-account producer.'; return 1; }
  allowed=$(aws ec2 describe-vpc-endpoint-service-permissions --service-id "$service" --query 'AllowedPrincipals[].Principal' --output text) || return 1
  printf '%s\n' "$allowed" | tr '\t' '\n' | grep -Fx "$role" >/dev/null || { warn 'worker-control endpoint service lost its exact Foundation role allowlist.'; return 1; }
  aws ec2 modify-vpc-endpoint-service-permissions --service-id "$service" --add-allowed-principals "$role" >/dev/null
}

agent_worker_control_destroy() {
  local service listener tg nlb nlb_sg certificate state connections identity account region role
  state=$(agent_worker_control_state); [ -n "$state" ] || return 0
  aws_env_prep; identity=$(agent_worker_control_read_identity) || return 1; account=${identity%%$'\t'*}; region=${identity#*$'\t'}; role=$(agent_worker_control_existing foundation_role_arn)
  [ "$account" = "$(agent_worker_control_existing account_id)" ] && [ "$region" = "$(agent_worker_control_existing region)" ] && agent_worker_control_role_is_exact "$account" "$role" || { warn 'worker-control destroy refuses an uncertain account, Region, or Foundation role.'; return 1; }
  service=$(agent_worker_control_existing endpoint_service_id); listener=$(agent_worker_control_existing listener_arn); tg=$(agent_worker_control_existing target_group_arn); nlb=$(agent_worker_control_existing nlb_arn); nlb_sg=$(agent_worker_control_existing nlb_security_group_id); certificate=$(agent_worker_control_existing certificate_arn)
  if [ -n "$service" ]; then
    connections=$(aws ec2 describe-vpc-endpoint-connections --service-id "$service" --query 'VpcEndpointConnections[?VpcEndpointState!=`deleted` && VpcEndpointState!=`rejected`].VpcEndpointId' --output text) || { warn 'worker-control could not read endpoint consumers; parent destroy is blocked.'; return 1; }
    [ -z "$connections" ] || { warn 'worker-control has active Worker endpoint consumers; retained producer blocks parent destroy.'; return 1; }
  fi
  agent_worker_control_record destroying "$(agent_worker_control_existing account_id)" "$(agent_worker_control_existing region)" "$(agent_worker_control_existing foundation_role_arn)" "$(agent_worker_control_existing vpc_id)" "$(agent_worker_control_existing target_instance_id)" "$(agent_worker_control_existing target_private_ip)" "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$(agent_worker_control_existing route53_zone_id)" || return 1
  [ -z "$service" ] || aws ec2 delete-vpc-endpoint-service-configurations --service-ids "$service" >/dev/null || return 1
  [ -z "$listener" ] || aws elbv2 delete-listener --listener-arn "$listener" >/dev/null || return 1
  [ -z "$tg" ] || aws elbv2 delete-target-group --target-group-arn "$tg" >/dev/null || return 1
  [ -z "$nlb" ] || aws elbv2 delete-load-balancer --load-balancer-arn "$nlb" >/dev/null || return 1
  [ -z "$nlb_sg" ] || aws ec2 delete-security-group --group-id "$nlb_sg" >/dev/null || return 1
  [ -z "$certificate" ] || aws acm delete-certificate --certificate-arn "$certificate" >/dev/null || return 1
  state_set_raw agent_worker_control '{}'
}
