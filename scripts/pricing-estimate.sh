#!/usr/bin/env bash
# pricing-estimate.sh - estimate monthly AWS costs for a Dirextalk node.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/git-bash.sh"
# shellcheck disable=SC1090
source "$HERE/lib/json.sh"

dirextalk_require_git_bash_on_windows || exit 1

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/pricing-estimate.sh --state <state.json> [--write-state]
  scripts/pricing-estimate.sh --region <region> --cloud-provider <lightsail|ec2> [--instance-type <type>] [--disk-gb <gb>] --domain-mode <user|route53>

Queries AWS Price List where possible. Falls back conservatively when pricing is unavailable.
EOF
}

DEFAULT_LIGHTSAIL_MONTHLY_USD=${DEFAULT_LIGHTSAIL_MONTHLY_USD:-12}
DEFAULT_LIGHTSAIL_BUNDLE_ID=${DEFAULT_LIGHTSAIL_BUNDLE_ID:-small_3_1}
DEFAULT_LIGHTSAIL_RAM_GB=${DEFAULT_LIGHTSAIL_RAM_GB:-2}
DEFAULT_LIGHTSAIL_DISK_GB=${DEFAULT_LIGHTSAIL_DISK_GB:-60}
DEFAULT_LIGHTSAIL_TRANSFER_GB=${DEFAULT_LIGHTSAIL_TRANSFER_GB:-3072}
DEFAULT_LIGHTSAIL_CPU_COUNT=${DEFAULT_LIGHTSAIL_CPU_COUNT:-2}

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
    ec2_hourly=${DIREXTALK_FALLBACK_EC2_HOURLY_USD:-0.030}
    ec2_source=fallback
  fi

  if [ "$status" = "queried" ] && gp3_rate=$(lookup_gp3_gb_month "$location"); then
    gp3_source=aws_pricing
  else
    status=fallback
    gp3_rate=${DIREXTALK_FALLBACK_GP3_GB_MONTH_USD:-0.10}
    gp3_source=fallback
  fi

  if [ "$status" = "queried" ] && public_ipv4_hourly=$(lookup_public_ipv4_hourly "$location"); then
    ipv4_source=aws_pricing
  else
    [ "$status" = "fallback" ] || status=fallback
    public_ipv4_hourly=${DIREXTALK_FALLBACK_PUBLIC_IPV4_HOURLY_USD:-0.005}
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
    route53_monthly=${DIREXTALK_ROUTE53_HOSTED_ZONE_MONTHLY_USD:-0.50}
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

build_lightsail_estimate() {
  local region=$1 domain_mode=$2 bundle_id=$3 price=$4 ram=$5 disk=$6 transfer=$7 cpu=$8 route53_monthly total
  if [ "$domain_mode" = "route53" ]; then
    route53_monthly=${DIREXTALK_ROUTE53_HOSTED_ZONE_MONTHLY_USD:-0.50}
  else
    route53_monthly=0
  fi
  total=$(round2 "$(awk -v p="$price" -v r="$route53_monthly" 'BEGIN { print p+r }')")
  json_build object \
    provider=lightsail \
    pricing_status=bundle_price_recorded \
    "region=$region" \
    "domain_mode=$domain_mode" \
    "total_monthly_usd=$total" \
    "components={\"lightsail_bundle\":{\"bundle_id\":\"$bundle_id\",\"monthly_usd\":$price,\"ram_gb\":$ram,\"disk_gb\":$disk,\"transfer_gb\":$transfer,\"cpu_count\":$cpu},\"route53_hosted_zone\":{\"monthly_usd\":$route53_monthly,\"included\":$( [ "$domain_mode" = "route53" ] && printf true || printf false )}}" \
    'notes=["Estimate excludes data transfer beyond the Lightsail bundle, TURN relay traffic, domain registration, taxes, and AWS credit eligibility.","AWS credits may reduce charges only when the account, plan, region, and service usage are eligible; verify in AWS Billing Console."]' \
    'recommendations=["Set an AWS Budget or billing alert before leaving the node running.","Review AWS Billing Console after deployment and after destroy to confirm actual charges."]'
}

lookup_lightsail_bundle() {
  local wanted_id=$1 bundles
  bundles=$(aws lightsail get-bundles --include-inactive --output json 2>/dev/null) || return 1
  printf '%s\n' "$bundles" | "$(json_node)" -e '
let input = "";
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  const wantedId = process.argv[1] || "";
  const wantedRam = Number(process.argv[2] || "2");
  const wantedDisk = Number(process.argv[3] || "60");
  const data = JSON.parse(input || "{}");
  const bundles = Array.isArray(data.bundles) ? data.bundles : [];
  const linux = bundles.filter((bundle) =>
    Array.isArray(bundle.supportedPlatforms) && bundle.supportedPlatforms.includes("LINUX_UNIX")
  );
  const selected = linux.find((bundle) => wantedId && bundle.bundleId === wantedId) ||
    linux.find((bundle) => Number(bundle.ramSizeInGb) === wantedRam && Number(bundle.diskSizeInGb) === wantedDisk) ||
    linux.find((bundle) => Number(bundle.price) === 12) ||
    linux[0];
  if (!selected) process.exit(1);
  const fields = [
    selected.bundleId,
    selected.price,
    selected.ramSizeInGb,
    selected.diskSizeInGb,
    selected.transferPerMonthInGb || 0,
    selected.cpuCount || 0
  ];
  process.stdout.write(`${fields.join("\t")}\n`);
});
' "$wanted_id" "$DEFAULT_LIGHTSAIL_RAM_GB" "$DEFAULT_LIGHTSAIL_DISK_GB"
}

state=""
write_state=0
region=""
cloud_provider=""
instance_type=""
disk_gb=""
domain_mode=""
lightsail_bundle_id=""
lightsail_price=""
lightsail_ram=""
lightsail_disk=""
lightsail_transfer=""
lightsail_cpu=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) state=${2:-}; shift 2 ;;
    --write-state) write_state=1; shift ;;
    --region) region=${2:-}; shift 2 ;;
    --cloud-provider|--provider|--cloud) cloud_provider=${2:-}; shift 2 ;;
    --instance-type) instance_type=${2:-}; shift 2 ;;
    --disk-gb) disk_gb=${2:-}; shift 2 ;;
    --domain-mode) domain_mode=${2:-}; shift 2 ;;
    --lightsail-bundle-id|--bundle-id) lightsail_bundle_id=${2:-}; shift 2 ;;
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
  cloud_provider=${cloud_provider:-$(json_get "$state" cloud_provider)}
  instance_type=${instance_type:-$(json_get "$state" instance_type)}
  domain_mode=${domain_mode:-$(json_get "$state" domain_mode route53)}
  disk_gb=${disk_gb:-$(json_get "$state" resources.root_volume_gb)}
  disk_gb=${disk_gb:-$(json_get "$state" root_volume_gb 50)}
  lightsail_bundle_id=${lightsail_bundle_id:-$(json_get "$state" resources.lightsail_bundle_id)}
  lightsail_price=${lightsail_price:-$(json_get "$state" resources.lightsail_bundle_price_usd)}
  lightsail_ram=${lightsail_ram:-$(json_get "$state" resources.lightsail_bundle_ram_gb)}
  lightsail_disk=${lightsail_disk:-$(json_get "$state" resources.lightsail_bundle_disk_gb)}
  lightsail_transfer=${lightsail_transfer:-$(json_get "$state" resources.lightsail_bundle_transfer_gb)}
  lightsail_cpu=${lightsail_cpu:-$(json_get "$state" resources.lightsail_bundle_cpu_count)}
fi

region=${region:-${AWS_DEFAULT_REGION:-${AWS_REGION:-}}}
cloud_provider=${cloud_provider:-${DIREXTALK_CLOUD_PROVIDER:-${DEPLOY_MODE:-${DIREXTALK_DEPLOY_PROVIDER:-lightsail}}}}
cloud_provider=$(printf '%s' "$cloud_provider" | tr '[:upper:]' '[:lower:]')
instance_type=${instance_type:-t3.small}
disk_gb=${disk_gb:-50}
domain_mode=${domain_mode:-route53}
lightsail_bundle_id=${lightsail_bundle_id:-${DIREXTALK_LIGHTSAIL_BUNDLE_ID:-$DEFAULT_LIGHTSAIL_BUNDLE_ID}}
lightsail_price=${lightsail_price:-$DEFAULT_LIGHTSAIL_MONTHLY_USD}
lightsail_ram=${lightsail_ram:-$DEFAULT_LIGHTSAIL_RAM_GB}
lightsail_disk=${lightsail_disk:-$DEFAULT_LIGHTSAIL_DISK_GB}
lightsail_transfer=${lightsail_transfer:-$DEFAULT_LIGHTSAIL_TRANSFER_GB}
lightsail_cpu=${lightsail_cpu:-$DEFAULT_LIGHTSAIL_CPU_COUNT}

[ -n "$region" ] || {
  echo "region is required for pricing estimate" >&2
  exit 1
}

case "$cloud_provider" in
  lightsail)
    if [ -z "${state:-}" ] || [ -z "${lightsail_price:-}" ] || [ "$lightsail_bundle_id" = "$DEFAULT_LIGHTSAIL_BUNDLE_ID" ]; then
      if bundle_row=$(lookup_lightsail_bundle "${DIREXTALK_LIGHTSAIL_BUNDLE_ID:-}"); then
        IFS=$'\t' read -r lightsail_bundle_id lightsail_price lightsail_ram lightsail_disk lightsail_transfer lightsail_cpu <<EOF
$bundle_row
EOF
      fi
    fi
    estimate=$(build_lightsail_estimate "$region" "$domain_mode" "$lightsail_bundle_id" "$lightsail_price" "$lightsail_ram" "$lightsail_disk" "$lightsail_transfer" "$lightsail_cpu")
    ;;
  ec2)
    estimate=$(build_estimate "$region" "$instance_type" "$disk_gb" "$domain_mode")
    ;;
  *)
    echo "unknown cloud provider: $cloud_provider" >&2
    exit 1
    ;;
esac
if [ "$write_state" = "1" ]; then
  [ -n "$state" ] || {
    echo "--write-state requires --state" >&2
    exit 1
  }
  json_mutate "$state" set-json cost_estimate "$estimate"
fi

printf '%s\n' "$estimate"
