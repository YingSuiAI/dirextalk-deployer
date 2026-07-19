#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_WORKDIR="$tmp/work"
export AWS_DEFAULT_REGION=us-west-2
export DIREXTALK_ORCHESTRATE_LIB_ONLY=1
mkdir -p "$HOME" "$DIREXTALK_WORKDIR"

# shellcheck disable=SC1090
source "$ROOT/scripts/orchestrate.sh"

state_ensure >/dev/null 2>&1
state_set region ""
ensure_region_selected

json_test_check "$STATE_JSON" "data.region === 'us-west-2' && data.region_recommendation.source === 'environment' && data.region_recommendation.timezone === 'unknown' && data.region_recommendation.utc_offset_hours === 'unknown'"

echo "orchestrate region env ok"
