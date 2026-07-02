#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

if [ "${AWS_PRICING_FAIL:-0}" = "1" ]; then
  exit 255
fi

case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    if [ "${AWS_STS_OK:-0}" = "1" ]; then
      printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/DirexioDeployer","UserId":"AIDAEXAMPLE"}\n'
      exit 0
    fi
    exit 255
    ;;
esac

service=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  if [ "$arg" = "--service-code" ]; then
    j=$((i+1))
    service="${!j}"
  fi
done

case "$service" in
  AmazonEC2)
    if printf '%s\n' "$*" | grep -q 'instanceType'; then
      rate="0.025"
    else
      rate="0.096"
    fi
    ;;
  AmazonVPC)
    rate="0.005"
    ;;
  *)
    rate="0.50"
    ;;
esac

product=$(printf '{"terms":{"OnDemand":{"term":{"priceDimensions":{"dim":{"pricePerUnit":{"USD":"%s"}}}}}}}' "$rate")
escaped_product=$(printf '%s' "$product" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"PriceList":["%s"]}\n' "$escaped_product"
EOF
chmod 700 "$fakebin/aws"

assert_file_exists() {
  [ -s "$1" ] || {
    echo "expected non-empty file: $1" >&2
    exit 1
  }
}

CALLS="$tmp/aws.calls"
export CALLS
export PATH="$fakebin:$PATH"

service_dir="$HOME/.direxio/nodes/pricing.example.test"
mkdir -p "$service_dir"
state="$service_dir/state.json"
json_build object \
  domain=pricing.example.test \
  region=ap-northeast-1 \
  domain_mode=route53 \
  instance_type=t3.small \
  'resources={"root_volume_gb":"50"}' \
  'phases={"S7_VERIFY_E2E":{"status":"done"}}' > "$state"

estimate=$(bash "$ROOT/scripts/pricing-estimate.sh" --state "$state" --write-state)
printf '%s\n' "$estimate" > "$tmp/estimate.json"

json_test_check "$tmp/estimate.json" "data.pricing_status === 'queried' && data.region === 'ap-northeast-1' && data.location === 'Asia Pacific (Tokyo)' && data.hours_per_month === 730 && data.components.ec2_instance.hourly_usd === 0.025 && data.components.ec2_instance.monthly_usd === 18.25 && data.components.ebs_gp3.storage_gb === 50 && data.components.public_ipv4.hourly_usd === 0.005 && data.components.public_ipv4.monthly_usd === 3.65 && data.components.route53_hosted_zone.monthly_usd === 0.5 && data.components.public_ipv4.billed_even_when_attached === true && data.recommendations.includes('Set an AWS Budget or billing alert before leaving the node running.') && data.notes.includes('AWS credits may reduce charges only when the account, plan, region, and service usage are eligible; verify in AWS Billing Console.') && data.total_monthly_usd > 27 && data.total_monthly_usd < 28"

json_test_check "$state" "data.cost_estimate.pricing_status === 'queried' && data.cost_estimate.components.public_ipv4.billed_even_when_attached === true"

auto_workdir="$HOME/.direxio/nodes/auto-pricing.example.test"
set +e
AWS_DEFAULT_REGION=ap-northeast-1 \
DOMAIN=auto-pricing.example.test \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
DIREXIO_WORKDIR="$auto_workdir" \
bash "$ROOT/scripts/orchestrate.sh" > "$tmp/orchestrate.out" 2> "$tmp/orchestrate.err"
auto_rc=$?
set -e
[ "$auto_rc" -ne 0 ] || {
  echo "expected orchestrate test run to stop before real provisioning" >&2
  exit 1
}
json_test_check "$auto_workdir/state.json" "data.cost_estimate.pricing_status === 'queried' && data.cost_estimate.region === 'ap-northeast-1'"

report_output=$(DIREXIO_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
assert_file_exists "$report_path"
json_test_check "$report_path" "data.billing.cost_estimate.pricing_status === 'queried' && data.billing.cost_estimate.components.public_ipv4.billed_even_when_attached === true"

fallback=$(AWS_PRICING_FAIL=1 bash "$ROOT/scripts/pricing-estimate.sh" --region ap-southeast-1 --instance-type t3.small --disk-gb 8 --domain-mode user)
printf '%s\n' "$fallback" > "$tmp/fallback.json"
json_test_check "$tmp/fallback.json" "data.pricing_status === 'fallback' && data.region === 'ap-southeast-1' && data.warnings.includes('AWS Pricing API unavailable; using conservative fallback estimates') && data.components.public_ipv4.billed_even_when_attached === true && data.components.route53_hosted_zone.monthly_usd === 0"

echo "pricing estimate ok"
