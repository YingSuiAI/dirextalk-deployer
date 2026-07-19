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
agent_worker_control_service_name_matches_id() {
  local service=$1 service_name=$2
  printf '%s\n' "$service" | grep -Eq '^vpce-svc-[0-9a-f]{17}$' \
    && [ "$service_name" = "com.amazonaws.vpce.$AGENT_WORKER_CONTROL_REGION.$service" ]
}

agent_worker_control_state() { state_get agent_worker_control.status; }
agent_worker_control_existing() { state_get "agent_worker_control.$1"; }
agent_worker_control_record() {
  local status=$1 account=$2 region=$3 role=$4 vpc=$5 instance=$6 target=$7 certificate=$8 nlb=$9
  local nlb_sg=${10} tg=${11} listener=${12} service=${13} zone=${14} subnets=${15:-}
  local service_name=${16:-} acm_name acm_value private_name private_value
  [ -n "$subnets" ] || subnets=$(agent_worker_control_existing subnet_ids)
  [ -n "$service_name" ] || service_name=$(agent_worker_control_existing endpoint_service_name)
  acm_name=$(agent_worker_control_existing acm_validation_name)
  acm_value=$(agent_worker_control_existing acm_validation_value)
  private_name=$(agent_worker_control_existing private_dns_validation_name)
  private_value=$(agent_worker_control_existing private_dns_validation_value)
  state_set_object agent_worker_control \
    "status=$status" "hostname=$AGENT_WORKER_CONTROL_HOSTNAME" "account_id=$account" "region=$region" \
    "foundation_role_arn=$role" "vpc_id=$vpc" "target_instance_id=$instance" "target_private_ip=$target" \
    "certificate_arn=$certificate" "nlb_arn=$nlb" "nlb_security_group_id=$nlb_sg" \
    "target_group_arn=$tg" "listener_arn=$listener" "endpoint_service_id=$service" "endpoint_service_name=$service_name" \
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
  local account=$1 zone existing
  zone=${AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID:-}
  agent_worker_control_id_is_safe "$zone" || { warn 'AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID is required and unsafe values are refused.'; return 1; }
  agent_worker_control_route53_zone_readback "$zone" \
    || { warn 'worker-control requires the public Route 53 zone that owns the fixed hostname.'; return 1; }
  existing=$(agent_worker_control_existing account_id)
  [ -z "$existing" ] || [ "$existing" = "$account" ] || { warn 'worker-control state belongs to another AWS account.'; return 1; }
  existing=$(agent_worker_control_existing region)
  [ -z "$existing" ] || [ "$existing" = "$AWS_DEFAULT_REGION" ] || { warn 'worker-control state belongs to another AWS Region.'; return 1; }
  existing=$(agent_worker_control_existing route53_zone_id)
  [ -z "$existing" ] || [ "$existing" = "$zone" ] || { warn 'worker-control state binds a different Route 53 zone.'; return 1; }
  existing=$(agent_worker_control_existing hostname)
  [ -z "$existing" ] || agent_worker_control_hostname_is_exact "$existing" || { warn 'worker-control state binds an unexpected hostname.'; return 1; }
}

agent_worker_control_require_authorize_input() {
  local account=$1 role arn
  role=${AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN:-}
  agent_worker_control_role_is_exact "$account" "$role" \
    || { warn "AGENT_WORKER_CONTROL_FOUNDATION_ROLE_ARN must be the exact $AGENT_WORKER_CONTROL_ROLE_NAME role in the current account."; return 1; }
  arn=$(aws iam get-role --role-name "$AGENT_WORKER_CONTROL_ROLE_NAME" --query 'Role.Arn' --output text) || return 1
  [ "$arn" = "$role" ] || { warn 'worker-control could not prove the exact Foundation role exists.'; return 1; }
  printf '%s\n' "$role"
}

agent_worker_control_exact_single() {
  local expected=$1 raw=${2:-} values count value
  values=$(printf '%s\n' "$raw" | tr '\t ' '\n\n' | sed '/^$/d' | LC_ALL=C sort -u)
  count=$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] || return 1
  value=$(printf '%s\n' "$values" | sed -n '1p')
  [ "$value" = "$expected" ]
}

agent_worker_control_dns_name_normalize() {
  local value=${1:-}
  agent_worker_control_dns_name_is_safe "$value" || return 1
  printf '%s\n' "${value%.}"
}

agent_worker_control_route53_zone_readback() {
  local zone=$1 output zone_name private_zone normalized_zone
  agent_worker_control_id_is_safe "$zone" || return 1
  output=$(aws route53 get-hosted-zone --id "$zone" --query 'HostedZone.[Name,Config.PrivateZone]' --output text) || return 1
  IFS=$'\t' read -r zone_name private_zone <<EOF
$output
EOF
  normalized_zone=$(agent_worker_control_dns_name_normalize "$zone_name") || return 1
  [ "$private_zone" = false ] || [ "$private_zone" = False ] || return 1
  case "$AGENT_WORKER_CONTROL_HOSTNAME" in "$normalized_zone"|*."$normalized_zone") return 0 ;; *) return 1 ;; esac
}

agent_worker_control_route53_records_json() {
  local zone=$1
  agent_worker_control_id_is_safe "$zone" || return 1
  aws route53 list-resource-record-sets --hosted-zone-id "$zone" \
    --query 'ResourceRecordSets' --output json
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

agent_worker_control_route53_record_readback() {
  local zone=$1 name=$2 type=$3 mode=$4 expected=${5:-} records
  records=$(agent_worker_control_route53_records_json "$zone") || return 2
  printf '%s\n' "$records" | node -e '
    let raw=""; process.stdin.on("data", c => raw += c).on("end", () => {
      let records; try { records=JSON.parse(raw); } catch { process.exit(2); }
      if (!Array.isArray(records)) process.exit(2);
      const [name, type, mode, expected]=process.argv.slice(1);
      const normalizeName=v => typeof v === "string" && /^[A-Za-z0-9_.-]+\.?$/.test(v) ? v.replace(/\.$/, "") : null;
      const sameName=records.filter(r => r && normalizeName(r.Name) === name);
      if (mode === "absent") {
        process.exit(sameName.some(r => r.Type === type) ? 1 : 0);
      }
      if (sameName.length === 0) process.exit(1);
      if (sameName.length !== 1 || sameName[0].Type !== type) process.exit(3);
      const values=sameName[0].ResourceRecords;
      if (!Array.isArray(values) || values.length !== 1 || !values[0] || typeof values[0].Value !== "string") process.exit(3);
      let actual=values[0].Value;
      if (type === "CNAME") actual=normalizeName(actual);
      else if (/^"[A-Za-z0-9_.:-]+"$/.test(actual)) actual=actual.slice(1, -1);
      else if (!/^[A-Za-z0-9_.:-]+$/.test(actual)) process.exit(3);
      process.exit(actual === expected ? 0 : 3);
    });' "$name" "$type" "$mode" "$expected"
}

agent_worker_control_route53_record_present() {
  local zone=$1 name=$2 type=$3 expected=$4 normalized_name normalized_expected
  normalized_name=$(agent_worker_control_dns_name_normalize "$name") || return 3
  case "$type" in
    CNAME) normalized_expected=$(agent_worker_control_dns_name_normalize "$expected") || return 3 ;;
    TXT)
      printf '%s\n' "$expected" | grep -Eq '^[A-Za-z0-9_.:-]+$' || return 3
      normalized_expected=$expected
      ;;
    *) return 3 ;;
  esac
  agent_worker_control_route53_record_readback "$zone" "$normalized_name" "$type" exact "$normalized_expected"
}

agent_worker_control_route53_record_absent() {
  local zone=$1 name=$2 type=$3 normalized_name
  normalized_name=$(agent_worker_control_dns_name_normalize "$name") || return 1
  case "$type" in A|AAAA) ;; *) return 1 ;; esac
  agent_worker_control_route53_record_readback "$zone" "$normalized_name" "$type" absent "" >/dev/null 2>&1
}

agent_worker_control_dns_ownership_readback() {
  local zone acm_name acm_value private_name private_value
  zone=$(agent_worker_control_existing route53_zone_id)
  acm_name=$(agent_worker_control_existing acm_validation_name)
  acm_value=$(agent_worker_control_existing acm_validation_value)
  private_name=$(agent_worker_control_existing private_dns_validation_name)
  private_value=$(agent_worker_control_existing private_dns_validation_value)
  [ -n "$zone" ] && [ -n "$acm_name" ] && [ -n "$acm_value" ] \
    && [ -n "$private_name" ] && [ -n "$private_value" ] \
    && agent_worker_control_route53_zone_readback "$zone" \
    && agent_worker_control_route53_record_present "$zone" "$acm_name" CNAME "$acm_value" \
    && agent_worker_control_route53_record_present "$zone" "$private_name" TXT "$private_value" \
    && agent_worker_control_route53_record_absent "$zone" "$AGENT_WORKER_CONTROL_HOSTNAME" A \
    && agent_worker_control_route53_record_absent "$zone" "$AGENT_WORKER_CONTROL_HOSTNAME" AAAA
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
  local instance=$1 vpc=$2 expected_ip=$3 region=$4 agent_sg=$5 output ip actual_vpc az instance_state groups
  output=$(aws ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,VpcId,Placement.AvailabilityZone,State.Name]' --output text) || return 1
  IFS=$'\t' read -r ip actual_vpc az instance_state <<EOF
$output
EOF
  groups=$(aws ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text) || return 1
  agent_worker_control_private_ip_is_safe "$ip" && [ "$actual_vpc" = "$vpc" ] && [ "$instance_state" = running ] || return 1
  case "$az" in "$region"[a-z]) ;; *) return 1 ;; esac
  printf '%s\n' "$groups" | tr '\t ' '\n\n' | grep -Fxq "$agent_sg" || return 1
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
  local tg=$1 vpc=$2 output protocol port target_type actual_vpc health_protocol health_port
  output=$(aws elbv2 describe-target-groups --target-group-arns "$tg" \
    --query 'TargetGroups[0].[Protocol,Port,TargetType,VpcId,HealthCheckProtocol,HealthCheckPort]' --output text) || return 1
  IFS=$'\t' read -r protocol port target_type actual_vpc health_protocol health_port <<EOF
$output
EOF
  [ "$protocol" = TLS ] && [ "$port" = 9443 ] && [ "$target_type" = ip ] \
    && [ "$actual_vpc" = "$vpc" ] && [ "$health_protocol" = TCP ] && [ "$health_port" = 9443 ] \
    && agent_worker_control_owned_tag_elbv2 "$tg"
}

agent_worker_control_agent_ingress_state() {
  local agent_sg=$1 nlb_sg=$2 permissions
  permissions=$(aws ec2 describe-security-groups --group-ids "$agent_sg" \
    --query 'SecurityGroups[0].IpPermissions' --output json) || return 1
  printf '%s\n' "$permissions" | node -e '
    let raw=""; process.stdin.on("data", c => raw += c).on("end", () => {
      const expected=process.argv[1]; let rules;
      try { rules=JSON.parse(raw); } catch { process.exit(1); }
      if (!Array.isArray(rules)) process.exit(1);
      const covering=rules.filter(r => r && (r.IpProtocol === "-1" ||
        (r.IpProtocol === "tcp" && Number.isInteger(r.FromPort) && Number.isInteger(r.ToPort) &&
         r.FromPort <= 9443 && r.ToPort >= 9443)));
      if (covering.length === 0) process.exit(2);
      if (covering.length !== 1) process.exit(1);
      const r=covering[0], pairs=Array.isArray(r.UserIdGroupPairs) ? r.UserIdGroupPairs : [];
      const empty=k => !Array.isArray(r[k]) || r[k].length === 0;
      const exact=r.IpProtocol === "tcp" && r.FromPort === 9443 && r.ToPort === 9443 &&
        empty("IpRanges") && empty("Ipv6Ranges") && empty("PrefixListIds") &&
        pairs.length === 1 && pairs[0] && pairs[0].GroupId === expected;
      process.exit(exact ? 0 : 1);
    });' "$nlb_sg"
}

agent_worker_control_agent_ingress_exact() {
  agent_worker_control_agent_ingress_state "$@"
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

agent_worker_control_principals_none() {
  local service=$1 allowed
  allowed=$(aws ec2 describe-vpc-endpoint-service-permissions --service-id "$service" \
    --query 'AllowedPrincipals[].Principal' --output text) || return 1
  agent_worker_control_none "$allowed"
}

agent_worker_control_service_owned() {
  local service=$1 owner
  owner=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$service" "Name=key,Values=dirextalk:owner" \
    --query 'Tags[].Value' --output text) || return 1
  agent_worker_control_exact_single "$AGENT_WORKER_CONTROL_OWNER_TAG" "$owner"
}

agent_worker_control_service_readback() {
  local service=$1 nlb=$2 service_name=$3 role=${4:-} mode=${5:-partial}
  local output nlb_arns private_dns acceptance service_state actual_service_name
  output=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].[PrivateDnsName,AcceptanceRequired,ServiceState,ServiceName]' --output text) || return 1
  IFS=$'\t' read -r private_dns acceptance service_state actual_service_name <<EOF
$output
EOF
  nlb_arns=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].NetworkLoadBalancerArns' --output text) || return 1
  agent_worker_control_exact_single "$nlb" "$nlb_arns" && agent_worker_control_service_owned "$service" || return 1
  [ "$actual_service_name" = "$service_name" ] \
    && agent_worker_control_endpoint_service_name_is_safe "$actual_service_name" \
    && agent_worker_control_service_name_matches_id "$service" "$actual_service_name" || return 1
  case "$service_state" in Available|Pending) ;; *) return 1 ;; esac
  case "$private_dns" in ''|None|"$AGENT_WORKER_CONTROL_HOSTNAME") ;; *) return 1 ;; esac
  case "$acceptance" in true|false|True|False) ;; *) return 1 ;; esac
  case "$mode" in
    partial)
      if [ "$acceptance" = false ] || [ "$acceptance" = False ]; then
        agent_worker_control_role_is_exact "$(agent_worker_control_existing account_id)" "$role" \
          && agent_worker_control_principals_exact "$service" "$role"
      else
        agent_worker_control_principals_none "$service"
      fi
      ;;
    staged)
      [ "$private_dns" = "$AGENT_WORKER_CONTROL_HOSTNAME" ] \
        && { [ "$acceptance" = true ] || [ "$acceptance" = True ]; } \
        && [ "$service_state" = Available ] \
        && agent_worker_control_principals_none "$service"
      ;;
    authorizing)
      [ "$private_dns" = "$AGENT_WORKER_CONTROL_HOSTNAME" ] \
        && { [ "$acceptance" = true ] || [ "$acceptance" = True ]; } \
        && [ "$service_state" = Available ] \
        && { agent_worker_control_principals_none "$service" \
          || agent_worker_control_principals_exact "$service" "$role"; }
      ;;
    ready)
      [ "$private_dns" = "$AGENT_WORKER_CONTROL_HOSTNAME" ] \
        && { [ "$acceptance" = false ] || [ "$acceptance" = False ]; } \
        && [ "$service_state" = Available ] \
        && agent_worker_control_principals_exact "$service" "$role"
      ;;
    *) return 1 ;;
  esac
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

agent_worker_control_complete_readback() {
  local account=$1 region=$2 mode=$3 role=${4:-}
  local certificate nlb nlb_sg tg listener service service_name vpc instance target agent_sg subnets dns_state
  [ "$account" = "$(agent_worker_control_existing account_id)" ] \
    && [ "$region" = "$(agent_worker_control_existing region)" ] || return 1
  certificate=$(agent_worker_control_existing certificate_arn)
  nlb=$(agent_worker_control_existing nlb_arn); nlb_sg=$(agent_worker_control_existing nlb_security_group_id)
  tg=$(agent_worker_control_existing target_group_arn); listener=$(agent_worker_control_existing listener_arn)
  service=$(agent_worker_control_existing endpoint_service_id); service_name=$(agent_worker_control_existing endpoint_service_name)
  vpc=$(agent_worker_control_existing vpc_id); instance=$(agent_worker_control_existing target_instance_id)
  target=$(agent_worker_control_existing target_private_ip); subnets=$(agent_worker_control_existing subnet_ids)
  agent_sg=$(res_get sg_id)
  agent_worker_control_endpoint_service_name_is_safe "$service_name" \
    && agent_worker_control_service_name_matches_id "$service" "$service_name" \
    && agent_worker_control_certificate_readback "$certificate" \
    && agent_worker_control_nlb_readback "$nlb" "$vpc" "$nlb_sg" "$subnets" \
    && agent_worker_control_target_group_readback "$tg" "$vpc" \
    && agent_worker_control_listener_readback "$listener" "$certificate" "$tg" \
    && agent_worker_control_target_readback "$tg" "$target" \
    && agent_worker_control_instance_readback "$instance" "$vpc" "$target" "$region" "$agent_sg" >/dev/null \
    && agent_worker_control_agent_ingress_exact "$agent_sg" "$nlb_sg" \
    && agent_worker_control_service_readback "$service" "$nlb" "$service_name" "$role" "$mode" \
    && agent_worker_control_dns_ownership_readback \
    || return 1
  dns_state=$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$service" \
    --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.State' --output text) || return 1
  [ "$dns_state" = verified ] && agent_worker_control_grpc_health
}

agent_worker_control_record_agent_service_name() {
  local service_name=$1
  agent_worker_control_endpoint_service_name_is_safe "$service_name" || return 1
  agent_aws_control_record_enabled \
    "$(state_get agent_aws_control.aws_reaper_image_uri)" \
    "$(state_get agent_aws_control.worker_control_endpoint)" \
    false "" "" "$service_name"
}

agent_worker_control_render_foundation_bundle() {
  local output=$1 service_name=${2:-} scripts_dir
  local -a args
  scripts_dir=${DIREXTALK_INSTALL_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  args=(
    --format bundle
    --bundle-output "$output"
    --domain "$(state_get domain)"
    --acme "${ACME_EMAIL:-}"
    --message-server-image "$(state_get server_release.image_ref)"
    --agent-image "$(state_get agent_release.image_ref)"
    --agent-instance-id "$(state_get agent_release.instance_id)"
    --agent-model-profiles-file "$AGENT_MODEL_PROFILES_FILE"
    --agent-enable-aws-control true
    --agent-aws-reaper-image-uri "$(state_get agent_aws_control.aws_reaper_image_uri)"
    --agent-worker-control-endpoint "$(state_get agent_aws_control.worker_control_endpoint)"
    --agent-enable-managed-preparation-aws false
  )
  [ -z "$service_name" ] || args+=(--agent-worker-control-endpoint-service-name "$service_name")
  bash "$scripts_dir/render/render-userdata.sh" "${args[@]}"
}

agent_worker_control_reconcile_runtime() {
  local service_name=$1 render_dir foundation_bundle producer_bundle foundation_compose producer_compose
  local foundation_sha producer_sha message_image agent_image agent_instance_id profiles_sha reaper endpoint
  local key_file public_ip known_hosts remote output scripts_dir
  agent_release_require_render_inputs || return 1
  scripts_dir=${DIREXTALK_INSTALL_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  render_dir=$(mktemp -d "$DIREXTALK_WORKDIR/.worker-control-runtime.XXXXXX") || return 1
  foundation_bundle="$render_dir/foundation.tar.gz"; producer_bundle="$render_dir/producer.tar.gz"
  foundation_compose="$render_dir/foundation-compose.yml"; producer_compose="$render_dir/producer-compose.yml"
  if ! agent_worker_control_render_foundation_bundle "$foundation_bundle" "" \
      || ! agent_worker_control_render_foundation_bundle "$producer_bundle" "$service_name" \
      || ! tar -xOzf "$foundation_bundle" docker-compose.yml > "$foundation_compose" \
      || ! tar -xOzf "$producer_bundle" docker-compose.yml > "$producer_compose"; then
    rm -rf "$render_dir"
    return 1
  fi
  foundation_sha=$(sha256sum "$foundation_compose" | awk '{print $1}')
  producer_sha=$(sha256sum "$producer_compose" | awk '{print $1}')
  [ "$foundation_sha" != "$producer_sha" ] || { rm -rf "$render_dir"; return 1; }
  message_image=$(state_get server_release.image_ref); agent_image=$(state_get agent_release.image_ref)
  agent_instance_id=$(state_get agent_release.instance_id); profiles_sha=$(state_get agent_release.model_profiles_sha256)
  reaper=$(state_get agent_aws_control.aws_reaper_image_uri); endpoint=$(state_get agent_aws_control.worker_control_endpoint)
  key_file=$(res_get key_file); public_ip=$(res_get public_ip); known_hosts=$(res_get ec2_ssh_known_hosts)
  [ -f "$key_file" ] && [ -s "$known_hosts" ] && printf '%s\n' "$public_ip" | grep -Eq '^[0-9.]+$' \
    || { rm -rf "$render_dir"; return 1; }
  remote="stage=\$(mktemp -d /tmp/dirextalk-worker-control.XXXXXX) && trap 'rm -rf \"\$stage\"' EXIT && tar -xzf - -C \"\$stage\" && sudo -n -- /bin/bash \"\$stage/updater/reconcile-agent-worker-control.sh\" \"\$stage\" /var/dirextalk-message-server '$foundation_sha' '$producer_sha' '$message_image' '$agent_image' '$agent_instance_id' '$profiles_sha' '$reaper' '$endpoint' '$service_name'"
  output=$(ssh -T -i "$key_file" -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 ubuntu@"$public_ip" "$remote" \
    < "$producer_bundle" 2>/dev/null) || { rm -rf "$render_dir"; return 1; }
  rm -rf "$render_dir"
  [ "$(printf '%s\n' "$output" | tail -n 1 | cut -f1-2)" = "$(printf 'applied\t%s' "$producer_sha")" ]
}

agent_worker_control_enable() {
  local identity account region role zone instance vpc agent_sg target certificate nlb nlb_sg tg listener service service_name status
  local subnet_csv subnet_args target_status ingress_status principals service_output
  [ -f "$STATE_JSON" ] || { warn 'agent-worker-control-enable requires existing deployment state.'; return 1; }
  agent_worker_control_require_foundation || return 1
  aws_env_prep
  identity=$(agent_worker_control_read_identity) || return 1
  account=${identity%%$'\t'*}; region=${identity#*$'\t'}
  agent_worker_control_require_inputs "$account" || return 1
  role=$(agent_worker_control_existing foundation_role_arn); zone=$AGENT_WORKER_CONTROL_ROUTE53_ZONE_ID
  instance=$(res_get instance_id); vpc=$(res_get vpc_id); agent_sg=$(res_get sg_id)
  agent_worker_control_id_is_safe "$instance" && agent_worker_control_id_is_safe "$vpc" \
    && agent_worker_control_id_is_safe "$agent_sg" || { warn 'worker-control target/VPC/security-group mapping is missing or unsafe.'; return 1; }
  target=$(agent_worker_control_instance_readback "$instance" "$vpc" "$(agent_worker_control_existing target_private_ip)" "$region" "$agent_sg") \
    || { warn 'worker-control instance must be running with the exact private target/VPC/AZ/Region and recorded Agent security group.'; return 1; }
  subnet_csv=$(agent_worker_control_select_subnets "$vpc") || { warn 'worker-control requires deterministic available subnets in at least two distinct AZs.'; return 1; }
  [ -z "$(agent_worker_control_existing subnet_ids)" ] || [ "$(agent_worker_control_existing subnet_ids)" = "$subnet_csv" ] \
    || { warn 'worker-control deterministic subnet selection drifted from recorded state.'; return 1; }

  certificate=$(agent_worker_control_existing certificate_arn)
  nlb=$(agent_worker_control_existing nlb_arn); nlb_sg=$(agent_worker_control_existing nlb_security_group_id)
  tg=$(agent_worker_control_existing target_group_arn); listener=$(agent_worker_control_existing listener_arn)
  service=$(agent_worker_control_existing endpoint_service_id); service_name=$(agent_worker_control_existing endpoint_service_name)
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
    case "$target_status" in 0|2|3) ;; *) warn 'worker-control target membership drifted.'; return 1 ;; esac
  else
    target_status=2
  fi
  [ -z "$listener" ] || agent_worker_control_listener_readback "$listener" "$certificate" "$tg" \
    || { warn 'worker-control listener drifted.'; return 1; }
  [ -z "$service" ] || agent_worker_control_service_readback "$service" "$nlb" "$service_name" "$role" partial \
    || { warn 'worker-control endpoint service drifted.'; return 1; }
  if [ "$(agent_worker_control_state)" = ready ]; then
    [ "$status" -eq 0 ] && [ "$target_status" -eq 0 ] \
      && agent_worker_control_complete_readback "$account" "$region" ready "$role" \
      || { warn 'worker-control ready-state reconciliation failed closed.'; return 1; }
    if [ -z "$(agent_worker_control_existing subnet_ids)" ]; then
      agent_worker_control_record ready "$account" "$region" "$role" "$vpc" "$instance" "$target" \
        "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
    fi
    return 0
  fi
  if [ "$(agent_worker_control_state)" = provisioned ]; then
    agent_worker_control_reconcile_runtime "$service_name" \
      && agent_worker_control_complete_readback "$account" "$region" staged "" \
      || { warn 'worker-control staged-state reconciliation failed closed.'; return 1; }
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
      --target-type ip --vpc-id "$vpc" --health-check-protocol TCP --health-check-port 9443 \
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
    service_output=$(aws ec2 create-vpc-endpoint-service-configuration --network-load-balancer-arns "$nlb" \
      --acceptance-required \
      --tag-specifications "ResourceType=vpc-endpoint-service,Tags=[{Key=dirextalk:owner,Value=$AGENT_WORKER_CONTROL_OWNER_TAG}]" \
      --query 'ServiceConfiguration.[ServiceId,ServiceName]' --output text) || return 1
    IFS=$'\t' read -r service service_name <<EOF
$service_output
EOF
    agent_worker_control_endpoint_service_name_is_safe "$service_name" \
      && agent_worker_control_service_name_matches_id "$service" "$service_name" || return 1
    agent_worker_control_record provisioning "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" "$service_name" || return 1
  fi
  principals=$(aws ec2 describe-vpc-endpoint-service-permissions --service-id "$service" \
    --query 'AllowedPrincipals[].Principal' --output text) || return 1
  agent_worker_control_none "$principals" || { warn 'worker-control enable requires an empty endpoint-service principal set.'; return 1; }
  aws ec2 modify-vpc-endpoint-service-configuration --service-id "$service" \
    --acceptance-required --private-dns-name "$AGENT_WORKER_CONTROL_HOSTNAME" >/dev/null || return 1
  agent_worker_control_record_agent_service_name "$service_name" || return 1
  agent_worker_control_reconcile_runtime "$service_name" \
    || { warn 'worker-control could not safely reconcile the endpoint service name into the Agent runtime.'; return 1; }
  agent_worker_control_private_dns_verified "$service" "$zone"; status=$?
  if [ "$status" -ne 0 ]; then
    agent_worker_control_record dns_pending "$account" "$region" "$role" "$vpc" "$instance" "$target" \
      "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" || return 1
    [ "$status" -eq 2 ] && warn 'worker-control endpoint-service private DNS verification is pending; retry after the ownership TXT is visible.'
    return "$status"
  fi
  agent_worker_control_complete_readback "$account" "$region" staged "" \
    || { warn 'worker-control complete staged producer readback failed.'; return 1; }
  agent_worker_control_record provisioned "$account" "$region" "" "$vpc" "$instance" "$target" \
    "$certificate" "$nlb" "$nlb_sg" "$tg" "$listener" "$service" "$zone" "$subnet_csv" "$service_name"
}

agent_worker_control_authorize() {
  local identity account region role service service_name nlb status principals instance vpc target
  [ -f "$STATE_JSON" ] || return 1
  aws_env_prep
  identity=$(agent_worker_control_read_identity) || return 1
  account=${identity%%$'\t'*}; region=${identity#*$'\t'}
  role=$(agent_worker_control_require_authorize_input "$account") || return 1
  service=$(agent_worker_control_existing endpoint_service_id); service_name=$(agent_worker_control_existing endpoint_service_name)
  nlb=$(agent_worker_control_existing nlb_arn); status=$(agent_worker_control_state)
  instance=$(agent_worker_control_existing target_instance_id); vpc=$(agent_worker_control_existing vpc_id)
  target=$(agent_worker_control_existing target_private_ip)
  case "$status" in provisioned|ready) ;; *) warn 'worker-control is not a staged producer.'; return 1 ;; esac
  agent_worker_control_id_is_safe "$service" && agent_worker_control_endpoint_service_name_is_safe "$service_name" || return 1
  if [ "$status" = ready ]; then
    [ "$(agent_worker_control_existing foundation_role_arn)" = "$role" ] \
      && agent_worker_control_complete_readback "$account" "$region" ready "$role"
    return $?
  fi
  if agent_worker_control_complete_readback "$account" "$region" ready "$role"; then
    agent_worker_control_record ready "$account" "$region" "$role" \
      "$vpc" "$instance" "$target" "$(agent_worker_control_existing certificate_arn)" \
      "$nlb" "$(agent_worker_control_existing nlb_security_group_id)" "$(agent_worker_control_existing target_group_arn)" \
      "$(agent_worker_control_existing listener_arn)" "$service" "$(agent_worker_control_existing route53_zone_id)" \
      "$(agent_worker_control_existing subnet_ids)" "$service_name"
    return $?
  fi
  agent_worker_control_complete_readback "$account" "$region" authorizing "$role" \
    || { warn 'worker-control authorization pre-mutation producer readback failed closed.'; return 1; }
  principals=$(aws ec2 describe-vpc-endpoint-service-permissions --service-id "$service" \
    --query 'AllowedPrincipals[].Principal' --output text) || return 1
  if agent_worker_control_none "$principals"; then
    aws ec2 modify-vpc-endpoint-service-permissions --service-id "$service" --add-allowed-principals "$role" >/dev/null || return 1
  elif ! agent_worker_control_exact_single "$role" "$principals"; then
    warn 'worker-control refuses wildcard, additional, or stale endpoint-service principals.'
    return 1
  fi
  agent_worker_control_principals_exact "$service" "$role" || return 1
  agent_worker_control_complete_readback "$account" "$region" authorizing "$role" \
    || { warn 'worker-control producer drifted before acceptance mutation.'; return 1; }
  aws ec2 modify-vpc-endpoint-service-configuration --service-id "$service" \
    --no-acceptance-required --private-dns-name "$AGENT_WORKER_CONTROL_HOSTNAME" >/dev/null || return 1
  agent_worker_control_complete_readback "$account" "$region" ready "$role" \
    || { warn 'worker-control authorization final producer readback failed closed.'; return 1; }
  agent_worker_control_record ready "$account" "$region" "$role" \
    "$(agent_worker_control_existing vpc_id)" "$(agent_worker_control_existing target_instance_id)" \
    "$(agent_worker_control_existing target_private_ip)" "$(agent_worker_control_existing certificate_arn)" \
    "$nlb" "$(agent_worker_control_existing nlb_security_group_id)" "$(agent_worker_control_existing target_group_arn)" \
    "$(agent_worker_control_existing listener_arn)" "$service" "$(agent_worker_control_existing route53_zone_id)" \
    "$(agent_worker_control_existing subnet_ids)" "$service_name"
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
    && { [ -z "$role" ] || agent_worker_control_role_is_exact "$account" "$role"; } \
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
