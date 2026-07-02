#!/usr/bin/env bash
# pricing-estimate.sh - estimate monthly AWS costs for a Direxio EC2 node.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/json.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/pricing-estimate.sh --state <state.json> [--write-state]
  scripts/pricing-estimate.sh --region <region> --instance-type <type> --disk-gb <gb> --domain-mode <user|route53>

Queries AWS Price List where possible. Falls back conservatively when pricing is unavailable.
EOF
}

region_location() {
  case "$1" in
    us-east-1) echo "US East (N. Virginia)" ;;
    us-east-2) echo "US East (Ohio)" ;;
    us-west-1) echo "US West (N. California)" ;;
    us-west-2) echo "US West (Oregon)" ;;
    ap-southeast-1) echo "Asia Pacific (Singapore)" ;;
    ap-southeast-2) echo "Asia Pacific (Sydney)" ;;
    ap-northeast-1) echo "Asia Pacific (Tokyo)" ;;
    ap-northeast-2) echo "Asia Pacific (Seoul)" ;;
    ap-east-1) echo "Asia Pacific (Hong Kong)" ;;
    eu-west-1) echo "EU (Ireland)" ;;
    eu-central-1) echo "EU (Frankfurt)" ;;
    *) echo "" ;;
  esac
}

price_from_get_products() {
  local service=$1 location=$2 shift_count=2 json
  shift "$shift_count"
  json=$(aws pricing get-products \
    --region us-east-1 \
    --service-code "$service" \
    --filters "Type=TERM_MATCH,Field=location,Value=$location" "$@" \
    --max-results 1 \
    --output json 2>/dev/null) || return 1
  printf '%s\n' "$json" | json_stdin_price_usd 2>/dev/null
}

numeric_or_empty() {
  case "${1:-}" in
    ''|null|None) return 1 ;;
    *[!0-9.]* ) return 1 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

lookup_ec2_hourly() {
  local location=$1 instance_type=$2 raw
  raw=$(price_from_get_products AmazonEC2 "$location" \
    "Type=TERM_MATCH,Field=instanceType,Value=$instance_type" \
    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
    "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
    "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
  ) || return 1
  numeric_or_empty "$raw"
}

lookup_gp3_gb_month() {
  local location=$1 raw
  raw=$(price_from_get_products AmazonEC2 "$location" \
    "Type=TERM_MATCH,Field=productFamily,Value=Storage" \
    "Type=TERM_MATCH,Field=volumeApiName,Value=gp3" \
  ) || return 1
  numeric_or_empty "$raw"
}

lookup_public_ipv4_hourly() {
  local location=$1 raw
  raw=$(price_from_get_products AmazonVPC "$location" \
    "Type=TERM_MATCH,Field=productFamily,Value=Public IPv4 Address" \
  ) || return 1
  numeric_or_empty "$raw"
}

round2() {
  awk -v n="${1:-0}" 'BEGIN { printf "%.2f", n + 0 }'
}

build_estimate() {
  local region=$1 instance_type=$2 disk_gb=$3 domain_mode=$4
  local hours=730 location ec2_hourly gp3_rate public_ipv4_hourly route53_monthly status warnings_json
  local ec2_source gp3_source ipv4_source
  location=$(region_location "$region")
  status=queried
  warnings_json='[]'

  if [ -z "$location" ]; then
    status=fallback
    warnings_json='["Region is not mapped to an AWS Pricing location; using conservative fallback estimates"]'
  fi

  if [ "$status" = "queried" ] && ec2_hourly=$(lookup_ec2_hourly "$location" "$instance_type"); then
    ec2_source=aws_pricing
  else
    status=fallback
    ec2_hourly=${DIREXIO_FALLBACK_EC2_HOURLY_USD:-0.030}
    ec2_source=fallback
  fi

  if [ "$status" = "queried" ] && gp3_rate=$(lookup_gp3_gb_month "$location"); then
    gp3_source=aws_pricing
  else
    status=fallback
    gp3_rate=${DIREXIO_FALLBACK_GP3_GB_MONTH_USD:-0.10}
    gp3_source=fallback
  fi

  if [ "$status" = "queried" ] && public_ipv4_hourly=$(lookup_public_ipv4_hourly "$location"); then
    ipv4_source=aws_pricing
  else
    [ "$status" = "fallback" ] || status=fallback
    public_ipv4_hourly=${DIREXIO_FALLBACK_PUBLIC_IPV4_HOURLY_USD:-0.005}
    ipv4_source=fallback
  fi

  if [ "$status" = "fallback" ]; then
    case "$warnings_json" in
      *"AWS Pricing API unavailable; using conservative fallback estimates"*) ;;
      "[]") warnings_json='["AWS Pricing API unavailable; using conservative fallback estimates"]' ;;
      *) warnings_json=${warnings_json%]}; warnings_json="$warnings_json,\"AWS Pricing API unavailable; using conservative fallback estimates\"]" ;;
    esac
  fi

  if [ "$domain_mode" = "route53" ]; then
    route53_monthly=${DIREXIO_ROUTE53_HOSTED_ZONE_MONTHLY_USD:-0.50}
  else
    route53_monthly=0
  fi

  json_build pricing-estimate \
    "$status" \
    "$region" \
    "$location" \
    "$instance_type" \
    "$domain_mode" \
    "$ec2_source" \
    "$gp3_source" \
    "$ipv4_source" \
    "$warnings_json" \
    "$hours" \
    "$disk_gb" \
    "$ec2_hourly" \
    "$(round2 "$(awk -v h="$ec2_hourly" -v m="$hours" 'BEGIN { print h*m }')")" \
    "$gp3_rate" \
    "$(round2 "$(awk -v r="$gp3_rate" -v gb="$disk_gb" 'BEGIN { print r*gb }')")" \
    "$public_ipv4_hourly" \
    "$(round2 "$(awk -v h="$public_ipv4_hourly" -v m="$hours" 'BEGIN { print h*m }')")" \
    "$route53_monthly"
}

state=""
write_state=0
region=""
instance_type=""
disk_gb=""
domain_mode=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) state=${2:-}; shift 2 ;;
    --write-state) write_state=1; shift ;;
    --region) region=${2:-}; shift 2 ;;
    --instance-type) instance_type=${2:-}; shift 2 ;;
    --disk-gb) disk_gb=${2:-}; shift 2 ;;
    --domain-mode) domain_mode=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [ -n "$state" ]; then
  [ -f "$state" ] || {
    echo "state.json not found: $state" >&2
    exit 1
  }
  region=${region:-$(json_get "$state" region)}
  instance_type=${instance_type:-$(json_get "$state" instance_type)}
  domain_mode=${domain_mode:-$(json_get "$state" domain_mode user)}
  disk_gb=${disk_gb:-$(json_get "$state" resources.root_volume_gb)}
  disk_gb=${disk_gb:-$(json_get "$state" root_volume_gb 50)}
fi

region=${region:-${AWS_DEFAULT_REGION:-${AWS_REGION:-}}}
instance_type=${instance_type:-t3.small}
disk_gb=${disk_gb:-50}
domain_mode=${domain_mode:-user}

[ -n "$region" ] || {
  echo "region is required for pricing estimate" >&2
  exit 1
}

estimate=$(build_estimate "$region" "$instance_type" "$disk_gb" "$domain_mode")
if [ "$write_state" = "1" ]; then
  [ -n "$state" ] || {
    echo "--write-state requires --state" >&2
    exit 1
  }
  json_mutate "$state" set-json cost_estimate "$estimate"
fi

printf '%s\n' "$estimate"
