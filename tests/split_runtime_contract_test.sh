#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
: "${DIREXTALK_TEST_ROOT:?run this test through tests/lib/run_isolated.sh}"
source_runtime=$ROOT/scripts/cloud-init/split/runtime
source_tests=$ROOT/tests/split-runtime
fixture=$(mktemp -d "$DIREXTALK_TEST_ROOT/split-runtime.XXXXXX")
cleanup() { rm -rf -- "$fixture"; }
trap cleanup EXIT

cp -a -- "$source_runtime" "$fixture/runtime"
tests=(
  agent-runtime-local.test.sh
  cleanup-local.test.sh
  cleanup-provision-failure.test.sh
  compose-runner-limits.test.sh
  initialize-capability-ca.test.sh
  initialize-message-server.test.sh
  initialize-postgres.test.sh
  manage-runner-apparmor.test.sh
  message-server-entrypoint.test.sh
  message-server-healthcheck.test.sh
  prepare-host-dependencies.test.sh
  prepare-runner-cgroups.test.sh
  refresh-message-mcp-token.test.sh
  update-agent-local.recovery.test.sh
  update-agent-local.test.sh
  update-message-server-local.test.sh
  verify-production-images.test.sh
)

for test in "${tests[@]}"; do
  cp -- "$source_tests/$test" "$fixture/runtime/scripts/$test"
done

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$fixture/runtime/scripts" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)

for test in "${tests[@]}"; do
  bash "$fixture/runtime/scripts/$test"
done

printf 'deployer-owned production split runtime contract verified\n'
