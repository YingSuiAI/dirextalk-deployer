#!/usr/bin/env bash
# Retained PrivateLink producer for the Agent AWS-control foundation.

AGENT_WORKER_CONTROL_HOSTNAME="worker-control.y1.dirextalk"'.ai'
AGENT_WORKER_CONTROL_ROLE_NAME='dirextalk-foundation-control'
AGENT_WORKER_CONTROL_REGION='ap-northeast-3'
AGENT_WORKER_CONTROL_OWNER_TAG='dirextalk-deployer'

agent_worker_control_hostname_is_exact() { [ "${1:-}" = "$AGENT_WORKER_CONTROL_HOSTNAME" ]; }
agent_worker_control_account_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[0-9]{12}$'; }
agent_worker_control_region_is_safe() { [ "${1:-}" = "$AGENT_WORKER_CONTROL_REGION" ]; }
agent_worker_control_private_ip_is_safe() {
  printf '%s\n' "${1:-}" | grep -Eq '^(10|192)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$|^172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}$'
}
agent_worker_control_role_is_exact() {
  local account=$1 role=${2:-}
  [ "$role" = "arn:aws:iam::$account:role/$AGENT_WORKER_CONTROL_ROLE_NAME" ]
}
agent_worker_control_id_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[A-Za-z0-9:/._+=,@-]+$'; }
agent_worker_control_dns_name_is_safe() { printf '%s\n' "${1:-}" | grep -Eq '^[_a-z0-9-]+(\.[_a-z0-9-]+)+\.?$'; }
agent_worker_control_none() { case "${1:-}" in ''|None|null) return 0 ;; *) return 1 ;; esac; }
agent_worker_control_arn_is_exact() {
  local service=$1 region=$2 account=$3 arn=$4
  case "$arn" in "arn:aws:$service:$region:$account:"*) return 0 ;; *) return 1 ;; esac
}

agent_worker_control_state() { state_get agent_worker_control.status; }
agent_worker_control_existing() { state_get "agent_worker_control.$1"; }
agent_worker_control_record() {
  local status=$1 account=$2 region=$3 role=$4 vpc=$5 instance=$6 target=$7 certificate=$8 nlb=$9
  local nlb_sg=${10} tg=${11} listener=${12} service=${13} zone=${14} subnets=${15:-}
  local acm_name acm_value private_name private_value
  [ -n "$subnets" ] || subnets=$(agent_worker_control_existing subnet_ids)
  acm_name=$(agent_worker_control_existing acm_validation_name)
  acm_value=$(agent_worker_control_existing acm_validation_value)
  private_name=$(agent_worker_control_existing private_dns_validation_name)
  private_value=$(agent_worker_control_existing private_dns_validation_value)
  state_set_object agent_worker_control \
    "status=$status" "hostname=$AGENT_WORKER_CONTROL_HOSTNAME" "account_id=$account" "region=$region" \
    "foundation_role_arn=$role" "vpc_id=$vpc" "target_instance_id=$instance" "target_private_ip=$target" \
    "certificate_arn=$certificate" "nlb_arn=$nlb" "nlb_security_group_id=$nlb_sg" \
    "target_group_arn=$tg" "listener_arn=$listener" "endpoint_service_id=$service" \
    "route53_zone_id=$zone" "subnet_ids=$subnets" \
    "acm_validation_name=$acm_name" "acm_validation_value=$acm_value" \
    "private_dns_validation_name=$private_name" "private_dns_validation_value=$private_value"
}

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
  agent_worker_control_region_is_safe "$state_region" || { warn "worker-control is fixed to $AGENT_WORKER_CONTROL_REGION."; return 1; }
  [ "${AWS_DEFAULT_REGION:-}" = "$state_region" ] || { warn 'worker-control refuses an AWS Region different from deployment state.'; return 1; }
  agent_worker_control_account_is_safe "$account" && [ -n "$caller" ] && [ "$caller" != None ] \
    || { warn 'worker-control could not verify the AWS account identity.'; return 1; }
  printf '%s\t%s\n' "$account" "$state_region"
}

agent_worker_control_require_inputs() {
  local account=$1 role zone existing zone_output zone_name private_zone
  role=${AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN:-}
  zone=${AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID:-}
  agent_worker_control_role_is_exact "$account" "$role" \
    || { warn "AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN must be the exact $AGENT_WORKER_CONTROL_ROLE_NAME role in the current account."; return 1; }
  agent_worker_control_id_is_safe "$zone" || { warn 'AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID is required and unsafe values are refused.'; return 1; }
  zone_output=$(aws route53 get-hosted-zone --id "$zone" --query 'HostedZone.[Name,Config.PrivateZone]' --output text) || return 1
  IFS=$'\t' read -r zone_name private_zone <<EOF
$zone_output
EOF
  zone_name=${zone_name%.}
  case "$AGENT_WORKER_CONTROL_HOSTNAME" in "$zone_name"|*."$zone_name") ;; *) warn 'worker-control Route 53 zone does not own the fixed hostname.'; return 1 ;; esac
  [ "$private_zone" = false ] || [ "$private_zone" = False ] || { warn 'worker-control ACM/PrivateLink ownership records require the public hosted zone.'; return 1; }
  existing=$(agent_worker_control_existing account_id)
  [ -z "$existing" ] || [ "$existing" = "$account" ] || { warn 'worker-control state belongs to another AWS account.'; return 1; }
  existing=$(agent_worker_control_existing region)
  [ -z "$existing" ] || [ "$existing" = "$AWS_DEFAULT_REGION" ] || { warn 'worker-control state belongs to another AWS Region.'; return 1; }
  existing=$(agent_worker_control_existing foundation_role_arn)
  [ -z "$existing" ] || [ "$existing" = "$role" ] || { warn 'worker-control state binds a different Foundation role.'; return 1; }
  existing=$(agent_worker_control_existing route53_zone_id)
  [ -z "$existing" ] || [ "$existing" = "$zone" ] || { warn 'worker-control state binds a different Route 53 zone.'; return 1; }
  existing=$(agent_worker_control_existing hostname)
  [ -z "$existing" ] || agent_worker_control_hostname_is_exact "$existing" || { warn 'worker-control state binds an unexpected hostname.'; return 1; }
}

agent_worker_control_exact_single() {
  local expected=$1 raw=${2:-} values count value
  values=$(printf '%s\n' "$raw" | tr '\t ' '\n\n' | sed '/^$/d' | LC_ALL=C sort -u)
  count=$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] || return 1
  value=$(printf '%s\n' "$values" | sed -n '1p')
  [ "$value" = "$expected" ]
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
  printf '{"Changes":[{"Action":"%s","ResourceRecordSet":{"Name":"%s","Type":"%s","TTL":60,"ResourceRecords":[{"Value":"%s"}]}}]}' \
    "$action" "$name" "$type" "$value" > "$batch"
  batch_native=$(dirextalk_native_tool_path "$batch") || { rm -f "$batch"; return 1; }
  if ! aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "file://$batch_native" >/dev/null; then
    rm -f "$batch"
    return 1
  fi
  rm -f "$batch"
}

agent_worker_control_route53_record_present() {
  local zone=$1 name=$2 type=$3 expected=$4 actual
  actual=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" \
    --query "ResourceRecordSets[?Name=='$name' && Type=='$type'].ResourceRecords[].Value" --output text) || return 2
  actual=${actual#\"}; actual=${actual%\"}
  agent_worker_control_none "$actual" && return 1
  [ "$actual" = "$expected" ] && return 0
  return 3
}

agent_worker_control_route53_ensure() {
  local zone=$1 name=$2 type=$3 value=$4 present
  agent_worker_control_route53_record_present "$zone" "$name" "$type" "$value"; present=$?
  case "$present" in
    0) return 0 ;;
    1) agent_worker_control_route53_change "$zone" UPSERT "$name" "$type" "$value" ;;
    *) warn 'worker-control validation DNS record exists with unexpected values.'; return 1 ;;
  esac
}

agent_worker_control_certificate_readback() {
  local certificate=$1 status domain sans owner
  status=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.Status' --output text) || return 1
  domain=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.DomainName' --output text) || return 1
  sans=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.SubjectAlternativeNames' --output text) || return 1
  owner=$(aws acm list-tags-for-certificate --certificate-arn "$certificate" \
    --query "Tags[?Key=='dirextalk:owner'].Value" --output text) || return 1
  agent_worker_control_hostname_is_exact "$domain" \
    && agent_worker_control_exact_single "$AGENT_WORKER_CONTROL_HOSTNAME" "$sans" \
    && agent_worker_control_exact_single "$AGENT_WORKER_CONTROL_OWNER_TAG" "$owner" || return 1
  case "$status" in ISSUED) return 0 ;; PENDING_VALIDATION) return 2 ;; *) return 1 ;; esac
}

agent_worker_control_certificate() {
  local certificate=$1 zone=$2 status name value discovered
  if [ -z "$certificate" ]; then
    discovered=$(aws acm list-certificates \
      --query "CertificateSummaryList[?DomainName=='$AGENT_WORKER_CONTROL_HOSTNAME'].CertificateArn" --output text) || return 1
    if ! agent_worker_control_none "$discovered"; then
      agent_worker_control_exact_single "$(printf '%s\n' "$discovered" | tr '\t' '\n' | sed -n '1p')" "$discovered" || return 1
      certificate=$(printf '%s\n' "$discovered" | tr '\t' '\n' | sed -n '1p')
    else
      certificate=$(aws acm request-certificate --domain-name "$AGENT_WORKER_CONTROL_HOSTNAME" --validation-method DNS \
        --tags "Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG" --query CertificateArn --output text) || return 1
    fi
    agent_worker_control_id_is_safe "$certificate" || return 1
    state_set agent_worker_control.certificate_arn "$certificate" || return 1
  fi
  agent_worker_control_certificate_readback "$certificate"; status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ] || return 1
  name=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text) || return 1
  value=$(aws acm describe-certificate --certificate-arn "$certificate" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text) || return 1
  agent_worker_control_dns_name_is_safe "$name" && agent_worker_control_dns_name_is_safe "$value" || return 1
  state_set agent_worker_control.acm_validation_name "$name" || return 1
  state_set agent_worker_control.acm_validation_value "$value" || return 1
  if [ "$status" -eq 2 ]; then
    agent_worker_control_route53_ensure "$zone" "$name" CNAME "$value" || return 1
    printf '%s\n' "$certificate"
    return 2
  fi
  printf '%s\n' "$certificate"
}

agent_worker_control_instance_readback() {
  local instance=$1 vpc=$2 expected_ip=$3 region=$4 output ip actual_vpc az
  output=$(aws ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,VpcId,Placement.AvailabilityZone]' --output text) || return 1
  IFS=$'\t' read -r ip actual_vpc az <<EOF
$output
EOF
  agent_worker_control_private_ip_is_safe "$ip" && [ "$actual_vpc" = "$vpc" ] || return 1
  case "$az" in "$region"[a-z]) ;; *) return 1 ;; esac
  [ -z "$expected_ip" ] || [ "$expected_ip" = "$ip" ] || return 1
  printf '%s\n' "$ip"
}

agent_worker_control_select_subnets() {
  local vpc=$1 rows selected count
  rows=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" 'Name=state,Values=available' \
    --query 'Subnets[].[AvailabilityZone,SubnetId]' --output text) || return 1
  selected=$(printf '%s\n' "$rows" | awk -F '\t' '
    NF == 2 && $1 ~ /^[a-z0-9-]+$/ && $2 ~ /^subnet-[A-Za-z0-9-]+$/ { print $1 "\t" $2 }
  ' | LC_ALL=C sort -k1,1 -k2,2 | awk -F '\t' '!seen[$1]++ { print $2 }')
  count=$(printf '%s\n' "$selected" | sed '/^$/d' | wc -l | tr -d '[:space:]')
  [ "$count" -ge 2 ] || return 1
  printf '%s\n' "$selected" | paste -sd, -
}

agent_worker_control_owned_tag_elbv2() {
  local arn=$1 value
  value=$(aws elbv2 describe-tags --resource-arns "$arn" \
    --query "TagDescriptions[0].Tags[?Key=='dirextalk:owner'].Value" --output text) || return 1
  agent_worker_control_exact_single "$AGENT_WORKER_CONTROL_OWNER_TAG" "$value"
}

agent_worker_control_owned_tag_ec2() {
  local id=$1 value
  value=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$id" "Name=key,Values=dirextalk:owner" \
    --query 'Tags[].Value' --output text) || return 1
  agent_worker_control_exact_single "$AGENT_WORKER_CONTROL_OWNER_TAG" "$value"
}

agent_worker_control_nlb_readback() {
  local nlb=$1 vpc=$2 nlb_sg=$3 subnet_csv=$4 output scheme actual_vpc type groups subnets enforcement
  output=$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb" \
    --query 'LoadBalancers[0].[Scheme,VpcId,Type]' --output text) || return 1
  IFS=$'\t' read -r scheme actual_vpc type <<EOF
$output
EOF
  [ "$scheme" = internal ] && [ "$actual_vpc" = "$vpc" ] && [ "$type" = network ] || return 1
  groups=$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb" --query 'LoadBalancers[0].SecurityGroups' --output text) || return 1
  agent_worker_control_exact_single "$nlb_sg" "$groups" || return 1
  subnets=$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb" --query 'LoadBalancers[0].AvailabilityZones[].SubnetId' --output text) || return 1
  [ "$(printf '%s\n' "$subnets" | tr '\t ' '\n\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd, -)" = \
    "$(printf '%s\n' "$subnet_csv" | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)" ] || return 1
  enforcement=$(aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$nlb" \
    --query "Attributes[?Key=='enforce_security_group_inbound_rules_on_private_link_traffic'].Value|[0]" --output text) || return 1
  [ "$enforcement" = off ] && agent_worker_control_owned_tag_elbv2 "$nlb"
}

agent_worker_control_target_group_readback() {
  local tg=$1 vpc=$2 output protocol port target_type actual_vpc health_protocol
  output=$(aws elbv2 describe-target-groups --target-group-arns "$tg" \
    --query 'TargetGroups[0].[Protocol,Port,TargetType,VpcId,HealthCheckProtocol]' --output text) || return 1
  IFS=$'\t' read -r protocol port target_type actual_vpc health_protocol <<EOF
$output
EOF
  [ "$protocol" = TLS ] && [ "$port" = 9443 ] && [ "$target_type" = ip ] \
    && [ "$actual_vpc" = "$vpc" ] && [ "$health_protocol" = TLS ] \
    && agent_worker_control_owned_tag_elbv2 "$tg"
}

agent_worker_control_agent_ingress_exact() {
  local agent_sg=$1 nlb_sg=$2 sources
  sources=$(aws ec2 describe-security-groups --group-ids "$agent_sg" \
    --query 'SecurityGroups[0].IpPermissions[?IpProtocol==`tcp` && FromPort==`9443` && ToPort==`9443`].UserIdGroupPairs[].GroupId' \
    --output text) || return 1
  agent_worker_control_exact_single "$nlb_sg" "$sources"
}

agent_worker_control_agent_ingress_state() {
  local agent_sg=$1 nlb_sg=$2 sources
  sources=$(aws ec2 describe-security-groups --group-ids "$agent_sg" \
    --query 'SecurityGroups[0].IpPermissions[?IpProtocol==`tcp` && FromPort==`9443` && ToPort==`9443`].UserIdGroupPairs[].GroupId' \
    --output text) || return 1
  agent_worker_control_none "$sources" && return 2
  agent_worker_control_exact_single "$nlb_sg" "$sources"
}

agent_worker_control_target_readback() {
  local tg=$1 target=$2 output actual port health lines
  output=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text) || return 1
  agent_worker_control_none "$output" && return 2
  lines=$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d '[:space:]')
  [ "$lines" = 1 ] || return 1
  IFS=$'\t' read -r actual port health <<EOF
$output
EOF
  [ "$actual" = "$target" ] && [ "$port" = 9443 ] || return 1
  [ "$health" = healthy ] || return 3
}

agent_worker_control_listener_readback() {
  local listener=$1 certificate=$2 tg=$3 output protocol port alpn actions certs
  output=$(aws elbv2 describe-listeners --listener-arns "$listener" \
    --query 'Listeners[0].[Protocol,Port,AlpnPolicy[0]]' --output text) || return 1
  IFS=$'\t' read -r protocol port alpn <<EOF
$output
EOF
  [ "$protocol" = TLS ] && [ "$port" = 443 ] && [ "$alpn" = HTTP2Only ] || return 1
  actions=$(aws elbv2 describe-listeners --listener-arns "$listener" \
    --query 'Listeners[0].DefaultActions[].TargetGroupArn' --output text) || return 1
  agent_worker_control_exact_single "$tg" "$actions" || return 1
  certs=$(aws elbv2 describe-listener-certificates --listener-arn "$listener" --query 'Certificates[].CertificateArn' --output text) || return 1
  agent_worker_control_exact_single "$certificate" "$certs" \
    && agent_worker_control_owned_tag_elbv2 "$listener"
}

agent_worker_control_principals_exact() {
  local service=$1 role=$2 allowed
  allowed=$(aws ec2 describe-vpc-endpoint-service-permissions --service-id "$service" \
    --query 'AllowedPrincipals[].Principal' --output text) || return 1
  agent_worker_control_exact_single "$role" "$allowed"
}

agent_worker_control_service_owned() {
  local service=$1 owner
  owner=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$service" "Name=key,Values=dirextalk:owner" \
    --query 'Tags[].Value' --output text) || return 1
  agent_worker_control_exact_single "$AGENT_WORKER_CONTROL_OWNER_TAG" "$owner"
}

agent_worker_control_service_readback() {
  local service=$1 nlb=$2 role=$3 require_ready=${4:-false} output nlb_arns private_dns acceptance service_state
  output=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].[PrivateDnsName,AcceptanceRequired,ServiceState]' --output text) || return 1
  IFS=$'\t' read -r private_dns acceptance service_state <<EOF
$output
EOF
  nlb_arns=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].NetworkLoadBalancerArns' --output text) || return 1
  agent_worker_control_exact_single "$nlb" "$nlb_arns" && agent_worker_control_service_owned "$service" || return 1
  case "$service_state" in Available|Pending) ;; *) return 1 ;; esac
  case "$private_dns" in ''|None|"$AGENT_WORKER_CONTROL_HOSTNAME") ;; *) return 1 ;; esac
  case "$acceptance" in true|false|True|False) ;; *) return 1 ;; esac
  if [ "$acceptance" = false ] || [ "$acceptance" = False ]; then
    agent_worker_control_principals_exact "$service" "$role" || return 1
  fi
  if [ "$require_ready" = true ]; then
    [ "$private_dns" = "$AGENT_WORKER_CONTROL_HOSTNAME" ] \
      && { [ "$acceptance" = false ] || [ "$acceptance" = False ]; } \
      && [ "$service_state" = Available ] \
      && agent_worker_control_principals_exact "$service" "$role"
  fi
}

agent_worker_control_private_dns_verified() {
  local service=$1 zone=$2 state name value
  state=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.State' --output text) || return 1
  [ "$state" = verified ] && return 0
  name=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.Name' --output text) || return 1
  value=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.Value' --output text) || return 1
  agent_worker_control_dns_name_is_safe "$name" && printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_.:-]+$' || return 1
  state_set agent_worker_control.private_dns_validation_name "$name" || return 1
  state_set agent_worker_control.private_dns_validation_value "$value" || return 1
  agent_worker_control_route53_ensure "$zone" "$name" TXT "$value" || return 1
  return 2
}

agent_worker_control_grpc_health() {
  local key_file public_ip known_hosts output remote
  key_file=$(res_get key_file); public_ip=$(res_get public_ip); known_hosts=$(res_get ec2_ssh_known_hosts)
  [ -f "$key_file" ] && [ -s "$known_hosts" ] && printf '%s\n' "$public_ip" | grep -Eq '^[0-9.]+$' \
    || { warn 'worker-control gRPC health requires the recorded key and pinned EC2 host key.'; return 1; }
  remote='cd /var/dirextalk-message-server && container=$(sudo docker compose ps -q agent) && test -n "$container" && sudo docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$container"'
  output=$(ssh -T -i "$key_file" -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=5 ubuntu@"$public_ip" "$remote" 2>/dev/null) || return 1
  [ "$output" = healthy ]
}

agent_worker_control_enable() {
  local identity account region role zone instance vpc target certificate nlb nlb_sg tg listener service status
  local subnet_csv subnet_args target_status ingress_status principals
  [ -f "$STATE_JSON" ] || { warn 'agent-worker-control-enable requires existing deployment state.'; return 1; }
  agent_worker_control_require_foundation || return 1
  aws_env_prep
  identity=$(agent_worker_control_read_identity) || return 1
  account=${identity%%$'\t'*}; region=${identity#*$'\t'}
  agent_worker_control_require_inputs "$account" || return 1
  role=$AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN; zone=$AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID
  instance=$(res_get instance_id); vpc=$(res_get vpc_id)
  agent_worker_control_id_is_safe "$instance" && agent_worker_control_id_is_safe "$vpc" || { warn 'worker-control target/VPC mapping is missing or unsafe.'; return 1; }
  target=$(agent_worker_control_instance_readback "$instance" "$vpc" "$(agent_worker_control_existing target_private_ip)" "$region") \
    || { warn 'worker-control instance private target/VPC/Region mapping is not exact.'; return 1; }
  subnet_csv=$(agent_worker_control_select_subnets "$vpc") || { warn 'worker-control requires deterministic available subnets in at least two distinct AZs.'; return 1; }
  [ -z "$(agent_worker_control_existing subnet_ids)" ] || [ "$(agent_worker_control_existing subnet_ids)" = "$subnet_csv" ] \
    || { warn 'worker-control deterministic subnet selection drifted from recorded state.'; return 1; }

  certificate=$(agent_worker_control_existing certificate_arn)
  nlb=$(agent_worker_control_existing nlb_arn); nlb_sg=$(agent_worker_control_existing nlb_security_group_id)
  tg=$(agent_worker_control_existing target_group_arn); listener=$(agent_worker_control_existing listener_arn)
  service=$(agent_worker_control_existing endpoint_service_id)
  [ -z "$certificate" ] || agent_worker_control_arn_is_exact acm "$region" "$account" "$certificate" || return 1
  [ -z "$nlb" ] || agent_worker_control_arn_is_exact elasticloadbalancing "$region" "$account" "$nlb" || return 1
  [ -z "$tg" ] || agent_worker_control_arn_is_exact elasticloadbalancing "$region" "$account" "$tg" || return 1
  [ -z "$listener" ] || agent_worker_control_arn_is_exact elasticloadbalancing "$region" "$account" "$listener" || return 1

  # Reconcile every persisted identifier before the first mutation.
  if [ -n "$certificate" ]; then
    agent_worker_control_certificate_readback "$certificate"; status=$?
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ] || { warn 'worker-control certificate drifted.'; return 1; }
  fi
  if [ -n "$nlb_sg" ]; then
    [ "$(aws ec2 describe-security-groups --group-ids "$nlb_sg" --query 'SecurityGroups[0].VpcId' --output text)" = "$vpc" ] \
      && agent_worker_control_owned_tag_ec2 "$nlb_sg" \
      || { warn 'worker-control NLB security group drifted.'; return 1; }
    agent_worker_control_agent_ingress_state "$(res_get sg_id)" "$nlb_sg"; ingress_status=$?
    case "$ingress_status" in 0|2) ;; *) warn 'worker-control Agent-host 9443 ingress is not the exact NLB security group.'; return 1 ;; esac
  else
    ingress_status=2
  fi
  [ -z "$nlb" ] || agent_worker_control_nlb_readback "$nlb" "$vpc" "$nlb_sg" "$subnet_csv" \
    || { warn 'worker-control NLB drifted.'; return 1; }
  [ -z "$tg" ] || agent_worker_control_target_group_readback "$tg" "$vpc" \
    || { warn 'worker-control target group drifted.'; return 1; }
  if [ -n "$tg" ]; then
    agent_worker_control_target_readback "$tg" "$target"; target_status=$?
    case "$target_status" in 0|2) ;; *) warn 'worker-control target membership or health drifted.'; return 1 ;; esac
  else
    target_status=2
  fi
  [ -z "$listener" ] || agent_worker_control_listener_readback "$listener" "$certificate" "$tg" \
    || { warn 'worker-control listener drifted.'; return 1; }
  [ -z "$service" ] || agent_worker_control_service_readback "$service" "$nlb" "$role" false \
    || { warn 'worker-control endpoint service drifted.'; return 1; }
  if [ "$(agent_worker_control_state)" = ready ]; then
    [ "$status" -eq 0 ] && [ "$target_status" -eq 0 ] \
      && agent_worker_control_nlb_readback "$nlb" "$vpc" "$nlb_sg" "$subnet_csv" \
      && agent_worker_control_target_group_readback "$tg" "$vpc" \
      && agent_worker_control_agent_ingress_exact "$(res_get sg_id)" "$nlb_sg" \
      && agent_worker_control_listener_readback "$listener" "$certificate" "$tg" \
      && agent_worker_control_service_readback "$service" "$nlb" "$role" true \
      && [ "$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
        --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.State' --output text)" = verified ] \
      && agent_worker_control_grpc_health \
      || { warn 'worker-control ready-state reconciliation failed closed.'; return 1; }
    if [ -z "$(agent_worker_control_existing subnet_ids)" ]; then
      agent_worker_control_record ready "$account" "$region" "$role" "$vpc" "$instance" "$target" \
        "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
    fi
    return 0
  fi

  agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
    "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
  if certificate=$(agent_worker_control_certificate "$certificate" "$zone"); then status=0; else status=$?; fi
  agent_worker_control_arn_is_exact acm "$region" "$account" "$certificate" || return 1
  agent_worker_control_record dns_pending "$account" "$region" "$role" "$vpc" "$instance" "$target" \
    "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
  [ "$status" -eq 0 ] || { warn 'worker-control ACM DNS validation is pending; retry after the validation CNAME is visible.'; return 2; }

  if [ -z "$nlb_sg" ]; then
    nlb_sg=$(aws ec2 create-security-group --group-name "dtx-wc-$instance" \
      --description 'Dirextalk retained worker-control PrivateLink NLB' --vpc-id "$vpc" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG}]" \
      --query GroupId --output text) || return 1
    agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
  fi
  if [ -z "$nlb" ]; then
    subnet_args=$(printf '%s\n' "$subnet_csv" | tr ',' ' ')
    # shellcheck disable=SC2086
    nlb=$(aws elbv2 create-load-balancer --name "dtx-wc-${instance#i-}" --type network --scheme internal \
      --security-groups "$nlb_sg" --subnets $subnet_args \
      --tags "Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text) || return 1
    agent_worker_control_arn_is_exact elasticloadbalancing "$region" "$account" "$nlb" || return 1
    agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
    aws elbv2 set-security-groups --load-balancer-arn "$nlb" --security-groups "$nlb_sg" \
      --enforce-security-group-inbound-rules-on-private-link-traffic off >/dev/null || return 1
  fi
  if [ -z "$tg" ]; then
    tg=$(aws elbv2 create-target-group --name "dtx-wc-${instance#i-}" --protocol TLS --port 9443 \
      --target-type ip --vpc-id "$vpc" --health-check-protocol TLS --health-check-port 9443 \
      --tags "Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG" \
      --query 'TargetGroups[0].TargetGroupArn' --output text) || return 1
    agent_worker_control_arn_is_exact elasticloadbalancing "$region" "$account" "$tg" || return 1
    target_status=2
    agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
  fi
  if [ "$ingress_status" -eq 2 ]; then
    aws ec2 authorize-security-group-ingress --group-id "$(res_get sg_id)" \
      --ip-permissions "IpProtocol=tcp,FromPort=9443,ToPort=9443,UserIdGroupPairs=[{GroupId=$nlb_sg}]" >/dev/null || return 1
  fi
  if [ "$target_status" -eq 2 ]; then
    aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$target,Port=9443" >/dev/null || return 1
  fi
  agent_worker_control_target_readback "$tg" "$target" || { warn 'worker-control NLB target is not healthy.'; return 1; }
  if [ -z "$listener" ]; then
    listener=$(aws elbv2 create-listener --load-balancer-arn "$nlb" --protocol TLS --port 443 \
      --certificates "CertificateArn=$certificate" --alpn-policy HTTP2Only \
      --default-actions "Type=forward,TargetGroupArn=$tg" \
      --tags "Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG" \
      --query 'Listeners[0].ListenerArn' --output text) || return 1
    agent_worker_control_arn_is_exact elasticloadbalancing "$region" "$account" "$listener" || return 1
    agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
  fi
  if [ -z "$service" ]; then
    service=$(aws ec2 create-vpc-endpoint-service-configuration --network-load-balancer-arns "$nlb" \
      --acceptance-required \
      --tag-specifications "ResourceType=vpc-endpoint-service,Tags=[{Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG}]" \
      --query 'ServiceConfiguration.ServiceId' --output text) || return 1
    printf '%s\n' "$service" | grep -Eq '^vpce-svc-[0-9a-f]+$' || return 1
    agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
  fi
  principals=$(aws ec2 describe-vpc-endpoint-service-permissions --service-id "$service" \
    --query 'AllowedPrincipals[].Principal' --output text) || return 1
  if agent_worker_control_none "$principals"; then
    aws ec2 modify-vpc-endpoint-service-permissions --service-id "$service" --add-allowed-principals "$role" >/dev/null || return 1
  elif ! agent_worker_control_exact_single "$role" "$principals"; then
    warn 'worker-control refuses wildcard, additional, or stale endpoint-service principals.'
    return 1
  fi
  agent_worker_control_principals_exact "$service" "$role" || return 1
  aws ec2 modify-vpc-endpoint-service-configuration --service-id "$service" \
    --no-acceptance-required --private-dns-name "$AGENT_WORKER_CONTROL_HOSTNAME" >/dev/null || return 1
  agent_worker_control_private_dns_verified "$service" "$zone"; status=$?
  if [ "$status" -ne 0 ]; then
    agent_worker_control_record dns_pending "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
    [ "$status" -eq 2 ] && warn 'worker-control endpoint-service private DNS verification is pending; retry after the ownership TXT is visible.'
    return "$status"
  fi
  agent_worker_control_service_readback "$service" "$nlb" "$role" true || { warn 'worker-control endpoint-service final readback failed.'; return 1; }
  agent_worker_control_certificate_readback "$certificate" || return 1
  agent_worker_control_nlb_readback "$nlb" "$vpc" "$nlb_sg" "$subnet_csv" || return 1
  agent_worker_control_target_group_readback "$tg" "$vpc" || return 1
  agent_worker_control_agent_ingress_exact "$(res_get sg_id)" "$nlb_sg" || return 1
  agent_worker_control_listener_readback "$listener" "$certificate" "$tg" || return 1
  agent_worker_control_target_readback "$tg" "$target" || return 1
  agent_worker_control_instance_readback "$instance" "$vpc" "$target" "$region" >/dev/null || return 1
  agent_worker_control_grpc_health || { warn 'worker-control authenticated host gRPC health gate failed.'; return 1; }
  agent_worker_control_record ready "$account" "$region" "$role" "$vpc" "$instance" "$target" \
    "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv"
}

agent_worker_control_authorize() {
  local identity account role service nlb
  [ -f "$STATE_JSON" ] || return 1
  aws_env_prep
  identity=$(agent_worker_control_read_identity) || return 1
  account=${identity%%$'\t'*}; role=$(agent_worker_control_existing foundation_role_arn)
  service=$(agent_worker_control_existing endpoint_service_id); nlb=$(agent_worker_control_existing nlb_arn)
  [ "$(agent_worker_control_state)" = ready ] && agent_worker_control_role_is_exact "$account" "$role" \
    && agent_worker_control_id_is_safe "$service" || { warn 'worker-control is not a ready, exact-account producer.'; return 1; }
  agent_worker_control_service_readback "$service" "$nlb" "$role" true \
    && agent_worker_control_principals_exact "$service" "$role" \
    && [ "$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
      --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.State' --output text)" = verified ]
}

agent_worker_control_not_found_error() {
  grep -Eq 'NotFound|not found|does not exist|InvalidVpcEndpointServiceId' "$1"
}

agent_worker_control_delete() {
  local error_file rc=0
  error_file=$(mktemp "$DIREXTALK_WORKDIR/.worker-control-delete.XXXXXX") || return 1
  "$@" >/dev/null 2>"$error_file" || rc=$?
  if [ "$rc" -ne 0 ] && ! agent_worker_control_not_found_error "$error_file"; then
    rm -f "$error_file"
    return "$rc"
  fi
  rm -f "$error_file"
}

agent_worker_control_absent() {
  local kind=$1 id=$2 output rc=0 error_file
  error_file=$(mktemp "$DIREXTALK_WORKDIR/.worker-control-readback.XXXXXX") || return 1
  case "$kind" in
    service) output=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$id" --query 'ServiceConfigurations[0].ServiceId' --output text 2>"$error_file") || rc=$? ;;
    listener) output=$(aws elbv2 describe-listeners --listener-arns "$id" --query 'Listeners[0].ListenerArn' --output text 2>"$error_file") || rc=$? ;;
    target_group) output=$(aws elbv2 describe-target-groups --target-group-arns "$id" --query 'TargetGroups[0].TargetGroupArn' --output text 2>"$error_file") || rc=$? ;;
    nlb) output=$(aws elbv2 describe-load-balancers --load-balancer-arns "$id" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>"$error_file") || rc=$? ;;
    security_group) output=$(aws ec2 describe-security-groups --group-ids "$id" --query 'SecurityGroups[0].GroupId' --output text 2>"$error_file") || rc=$? ;;
    certificate) output=$(aws acm describe-certificate --certificate-arn "$id" --query 'Certificate.CertificateArn' --output text 2>"$error_file") || rc=$? ;;
    *) rm -f "$error_file"; return 1 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    if agent_worker_control_not_found_error "$error_file"; then rm -f "$error_file"; return 0; fi
    rm -f "$error_file"
    return 1
  fi
  rm -f "$error_file"
  agent_worker_control_none "$output"
}

agent_worker_control_destroy_checkpoint() {
  agent_worker_control_record destroying \
    "$(agent_worker_control_existing account_id)" "$(agent_worker_control_existing region)" \
    "$(agent_worker_control_existing foundation_role_arn)" "$(agent_worker_control_existing vpc_id)" \
    "$(agent_worker_control_existing target_instance_id)" "$(agent_worker_control_existing target_private_ip)" \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" \
    "$(agent_worker_control_existing route53_zone_id)" "$(agent_worker_control_existing subnet_ids)"
}

agent_worker_control_destroy() {
  local state identity account region role service listener tg nlb nlb_sg certificate connections agent_sg
  local zone acm_name acm_value private_name private_value present
  state=$(agent_worker_control_state); [ -n "$state" ] || return 0
  aws_env_prep
  identity=$(agent_worker_control_read_identity) || return 1
  account=${identity%%$'\t'*}; region=${identity#*$'\t'}; role=$(agent_worker_control_existing foundation_role_arn)
  [ "$account" = "$(agent_worker_control_existing account_id)" ] \
    && [ "$region" = "$(agent_worker_control_existing region)" ] \
    && agent_worker_control_role_is_exact "$account" "$role" \
    || { warn 'worker-control destroy refuses an uncertain account, Region, or Foundation role.'; return 1; }
  service=$(agent_worker_control_existing endpoint_service_id); listener=$(agent_worker_control_existing listener_arn)
  tg=$(agent_worker_control_existing target_group_arn); nlb=$(agent_worker_control_existing nlb_arn)
  nlb_sg=$(agent_worker_control_existing nlb_security_group_id); certificate=$(agent_worker_control_existing certificate_arn)
  zone=$(agent_worker_control_existing route53_zone_id); acm_name=$(agent_worker_control_existing acm_validation_name)
  acm_value=$(agent_worker_control_existing acm_validation_value)
  private_name=$(agent_worker_control_existing private_dns_validation_name)
  private_value=$(agent_worker_control_existing private_dns_validation_value)
  agent_sg=$(res_get sg_id)
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$service" ] && ! agent_worker_control_absent service "$service"; then
    agent_worker_control_service_owned "$service" || { warn 'worker-control endpoint-service ownership is uncertain.'; return 1; }
    connections=$(aws ec2 describe-vpc-endpoint-connections --service-id "$service" \
      --query 'VpcEndpointConnections[?VpcEndpointState!=`deleted` && VpcEndpointState!=`rejected`].VpcEndpointId' --output text) \
      || { warn 'worker-control could not read endpoint consumers; parent destroy is blocked.'; return 1; }
    agent_worker_control_none "$connections" || { warn 'worker-control has active Worker endpoint consumers; retained producer blocks parent destroy.'; return 1; }
    agent_worker_control_delete aws ec2 delete-vpc-endpoint-service-configurations --service-ids "$service" || return 1
    agent_worker_control_absent service "$service" || { warn 'worker-control endpoint service still exists.'; return 1; }
  fi
  service=
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$listener" ] && ! agent_worker_control_absent listener "$listener"; then
    agent_worker_control_owned_tag_elbv2 "$listener" || { warn 'worker-control listener ownership is uncertain.'; return 1; }
    agent_worker_control_delete aws elbv2 delete-listener --listener-arn "$listener" || return 1
    agent_worker_control_absent listener "$listener" || { warn 'worker-control listener still exists.'; return 1; }
  fi
  listener=
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$tg" ] && ! agent_worker_control_absent target_group "$tg"; then
    agent_worker_control_owned_tag_elbv2 "$tg" || { warn 'worker-control target-group ownership is uncertain.'; return 1; }
    agent_worker_control_delete aws elbv2 delete-target-group --target-group-arn "$tg" || return 1
    agent_worker_control_absent target_group "$tg" || { warn 'worker-control target group still exists.'; return 1; }
  fi
  tg=
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$nlb" ] && ! agent_worker_control_absent nlb "$nlb"; then
    agent_worker_control_owned_tag_elbv2 "$nlb" || { warn 'worker-control NLB ownership is uncertain.'; return 1; }
    agent_worker_control_delete aws elbv2 delete-load-balancer --load-balancer-arn "$nlb" || return 1
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$nlb" >/dev/null 2>&1 || true
    agent_worker_control_absent nlb "$nlb" || { warn 'worker-control NLB still exists.'; return 1; }
  fi
  nlb=
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$nlb_sg" ]; then
    [ -z "$agent_sg" ] || aws ec2 revoke-security-group-ingress --group-id "$agent_sg" \
      --ip-permissions "IpProtocol=tcp,FromPort=9443,ToPort=9443,UserIdGroupPairs=[{GroupId=$nlb_sg}]" >/dev/null 2>&1 || true
    if ! agent_worker_control_absent security_group "$nlb_sg"; then
      agent_worker_control_owned_tag_ec2 "$nlb_sg" || { warn 'worker-control NLB security-group ownership is uncertain.'; return 1; }
      agent_worker_control_delete aws ec2 delete-security-group --group-id "$nlb_sg" || return 1
      agent_worker_control_absent security_group "$nlb_sg" || { warn 'worker-control NLB security group still exists.'; return 1; }
    fi
  fi
  nlb_sg=
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$certificate" ] && ! agent_worker_control_absent certificate "$certificate"; then
    [ "$(aws acm list-tags-for-certificate --certificate-arn "$certificate" \
      --query "Tags[?Key=='dirextalk:owner'].Value" --output text)" = "$AGENT_WORKER_CONTROL_OWNER_TAG" ] \
      || { warn 'worker-control certificate ownership is uncertain.'; return 1; }
    agent_worker_control_delete aws acm delete-certificate --certificate-arn "$certificate" || return 1
    agent_worker_control_absent certificate "$certificate" || { warn 'worker-control certificate still exists.'; return 1; }
  fi
  certificate=
  agent_worker_control_destroy_checkpoint "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" || return 1

  if [ -n "$private_name$private_value" ]; then
    agent_worker_control_route53_record_present "$zone" "$private_name" TXT "$private_value"; present=$?
    case "$present" in
      0) agent_worker_control_route53_change "$zone" DELETE "$private_name" TXT "$private_value" || return 1 ;;
      1) ;;
      *) return 1 ;;
    esac
    agent_worker_control_route53_record_present "$zone" "$private_name" TXT "$private_value"; present=$?
    [ "$present" -eq 1 ] || return 1
  fi
  if [ -n "$acm_name$acm_value" ]; then
    agent_worker_control_route53_record_present "$zone" "$acm_name" CNAME "$acm_value"; present=$?
    case "$present" in
      0) agent_worker_control_route53_change "$zone" DELETE "$acm_name" CNAME "$acm_value" || return 1 ;;
      1) ;;
      *) return 1 ;;
    esac
    agent_worker_control_route53_record_present "$zone" "$acm_name" CNAME "$acm_value"; present=$?
    [ "$present" -eq 1 ] || return 1
  fi
  state_set_raw agent_worker_control '{}'
}
