#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_WORKDIR="$tmp/work"
export DOMAIN=route53-default.test
export CONFIRM_DOMAIN_BINDING=1
export DOMAIN_VERIFIED=1
unset DOMAIN_MODE

mkdir -p "$HOME" "$DIREXTALK_WORKDIR"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"
state_ensure >/dev/null 2>&1

# shellcheck disable=SC1090
source "$ROOT/scripts/phases/s2_domain.sh"
run_phase >/dev/null

json_test_check "$STATE_JSON" "data.domain === 'route53-default.test' && data.domain_mode === 'route53' && data.domain_confirmed_irreversible === true && data.phases.S2_DOMAIN.status === 'done'"

echo "domain route53 default ok"
