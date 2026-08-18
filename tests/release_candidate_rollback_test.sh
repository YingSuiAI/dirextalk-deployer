#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
: "${DIREXTALK_TEST_ROOT:?run this test through tests/lib/run_isolated.sh}"

fixture=$(mktemp -d "$DIREXTALK_TEST_ROOT/release-candidate-rollback.XXXXXX")
cleanup() { rm -rf -- "$fixture"; }
trap cleanup EXIT

cp -a -- "$ROOT/scripts/cloud-init/split/runtime" "$fixture/runtime"
tests=(
  update-agent-local.recovery.test.sh
  update-message-server-local.rollback.test.sh
)
for test in "${tests[@]}"; do
  cp -- "$ROOT/tests/split-runtime/$test" "$fixture/runtime/scripts/$test"
  bash -n "$fixture/runtime/scripts/$test"
done

# These are the two application-specific rollback consumers used by a local
# release candidate. Keep them focused here instead of running the entire split
# runtime matrix: Agent rollback must preserve Message Server identity, while a
# failed Message Server update must restore its exact prior release receipt.
for test in "${tests[@]}"; do
  bash "$fixture/runtime/scripts/$test"
done

printf 'Agent and Message Server release rollback gates passed\n'
