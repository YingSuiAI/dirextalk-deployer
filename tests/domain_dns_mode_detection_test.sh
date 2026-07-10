#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "${1:-}" = "run" ]; then
  scenario=${AWS_TEST_SCENARIO:?}
  export HOME="$TEST_TMP/home-$scenario"
  export DIREXTALK_HOME="$HOME/.dirextalk"
  export DIREXTALK_WORKDIR="$TEST_TMP/work-$scenario"
  export DOMAIN="o3.dirextalk.ai"
  export CONFIRM_DOMAIN_BINDING=1
  export DOMAIN_VERIFIED=1
  unset DOMAIN_MODE
  mkdir -p "$HOME" "$DIREXTALK_WORKDIR"

  # shellcheck disable=SC1090
  source "$ROOT/tests/lib/json_test.sh"
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib/state.sh"
  state_init >/dev/null 2>&1
  # shellcheck disable=SC1090
  source "$ROOT/scripts/phases/s2_domain.sh"

  case "$scenario" in
    hosted)
      run_phase >"$TEST_TMP/hosted.out" 2>&1
      json_test_check "$STATE_JSON" "data.domain_mode === 'route53' && data.resources.route53_zone_id === 'ZDIREXTALK' && data.resources.route53_zone_name === 'dirextalk.ai' && data.resources.route53_zone_created_by_deployer === 'false' && data.phases.S2_DOMAIN.status === 'done'"
      ;;
    external)
      run_phase >"$TEST_TMP/external.out" 2>&1
      json_test_check "$STATE_JSON" "data.domain_mode === 'user' && !data.resources?.route53_zone_id && data.phases.S2_DOMAIN.status === 'done'"
      ;;
    denied)
      set +e
      run_phase >"$TEST_TMP/denied.out" 2>&1
      rc=$?
      set -e
      [ "$rc" -eq 1 ] || {
        echo "Route53 permission failure should fail detection with rc=1" >&2
        exit 1
      }
      json_test_check "$STATE_JSON" "!data.domain_mode && data.phases.S2_DOMAIN.status === 'failed'"
      ;;
  esac
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TEST_TMP="$tmp"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$TEST_TMP/aws.calls"
printf ' %q' "$@" >> "$TEST_TMP/aws.calls"
printf '\n' >> "$TEST_TMP/aws.calls"

[ "${1:-} ${2:-}" = "route53 list-hosted-zones" ] || {
  echo "unexpected aws command: $*" >&2
  exit 1
}

case "$AWS_TEST_SCENARIO" in
  hosted)
    printf '{"HostedZones":[{"Id":"/hostedzone/ZPRIVATE","Name":"dirextalk.ai.","Config":{"PrivateZone":true}},{"Id":"/hostedzone/ZPARENT","Name":"ai.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/ZDIREXTALK","Name":"dirextalk.ai.","Config":{"PrivateZone":false}}]}\n'
    ;;
  external)
    printf '{"HostedZones":[]}\n'
    ;;
  denied)
    echo "AccessDenied: route53:ListHostedZones" >&2
    exit 254
    ;;
esac
EOF
chmod 700 "$fakebin/aws"
export PATH="$fakebin:$PATH"

AWS_TEST_SCENARIO=hosted bash "$0" run
grep -q 'existing public Route53 hosted zone dirextalk.ai' "$tmp/hosted.out"
if grep -qi 'manually.*A record\|manual DNS' "$tmp/hosted.out"; then
  echo "Route53-hosted domains must not receive manual DNS guidance" >&2
  cat "$tmp/hosted.out" >&2
  exit 1
fi

AWS_TEST_SCENARIO=external bash "$0" run
grep -q 'not hosted in the current AWS account' "$tmp/external.out"
grep -q 'A record' "$tmp/external.out"

AWS_TEST_SCENARIO=denied bash "$0" run
grep -q 'could not inspect Route53 hosted zones' "$tmp/denied.out"

if grep -q 'route53 create-hosted-zone' "$tmp/aws.calls"; then
  echo "DNS mode detection must never create a Route53 hosted zone" >&2
  cat "$tmp/aws.calls" >&2
  exit 1
fi

echo "domain DNS mode detection ok"
