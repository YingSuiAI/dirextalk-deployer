#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
mkdir -p "$HOME"
unset DIREXTALK_WORKDIR
export DOMAIN="Service.Example.test"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"

[ "$DIREXTALK_WORKDIR" = "$HOME/.dirextalk/nodes/service.example.test" ]
[ "$STATE_JSON" = "$HOME/.dirextalk/nodes/service.example.test/state.json" ]

(
  unset DIREXTALK_WORKDIR
  export DIREXTALK_WORKDIR="$HOME/.dirextalk/custom-workdir"
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib/state.sh"
  [ "$DIREXTALK_WORKDIR" = "$HOME/.dirextalk/custom-workdir" ]
  [ "$STATE_JSON" = "$HOME/.dirextalk/custom-workdir/state.json" ]
)

rm -rf "$HOME/.dirextalk"
(
  unset DOMAIN DIREXTALK_WORKDIR
  HOME="$HOME" bash "$ROOT/scripts/orchestrate.sh" status >/dev/null 2>&1
)
[ ! -e "$HOME/.dirextalk/deploy" ]
[ ! -e "$HOME/.dirextalk/nodes/state.json" ]

mkdir -p "$HOME/.dirextalk/nodes/solo.example.test"
json_build object domain=solo.example.test phase=S3_PROVISION 'resources={"instance_id":"i-solo"}' > "$HOME/.dirextalk/nodes/solo.example.test/state.json"
(
  unset DOMAIN DIREXTALK_WORKDIR
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib/state.sh"
  [ "$DIREXTALK_WORKDIR" = "$HOME/.dirextalk/nodes" ]
  [ "$STATE_JSON" = "$HOME/.dirextalk/nodes/state.json" ]
)

mkdir -p "$HOME/.dirextalk/nodes/second.example.test"
json_build object domain=second.example.test phase=S6_WIRE_LOCAL 'resources={"instance_id":"i-second"}' > "$HOME/.dirextalk/nodes/second.example.test/state.json"
status_output=$(
  unset DOMAIN DIREXTALK_WORKDIR
  HOME="$HOME" bash "$ROOT/scripts/orchestrate.sh" status
)
[[ "$status_output" == *"solo.example.test"* ]]
[[ "$status_output" == *"second.example.test"* ]]
[[ "$status_output" == *"i-solo"* ]]
[[ "$status_output" == *"i-second"* ]]

echo "default paths ok"
