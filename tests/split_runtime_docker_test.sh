#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
: "${DIREXTALK_TEST_ROOT:?run this test through tests/lib/run_isolated.sh}"
source_runtime=$ROOT/scripts/cloud-init/split/runtime
source_tests=$ROOT/tests/split-runtime
fixture=$(mktemp -d "$DIREXTALK_TEST_ROOT/split-runtime-docker.XXXXXX")
cleanup() { rm -rf -- "$fixture"; }
trap cleanup EXIT

cp -a -- "$source_runtime" "$fixture/runtime"
for test in postgres-entrypoint.docker.test.sh update-agent-local.docker.test.sh; do
  cp -- "$source_tests/$test" "$fixture/runtime/scripts/$test"
  bash "$fixture/runtime/scripts/$test"
done

printf 'deployer-owned production split Docker runtime verified\n'
