#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# The npm entrypoint must provide the isolation root before any test can resolve
# a user or runtime home.
# shellcheck disable=SC1091
source "$ROOT/tests/lib/isolated_home.sh"
: "${DIREXTALK_TEST_ROOT:?run this suite through tests/lib/run_isolated.sh}"
dirextalk_test_assert_isolated_homes "$DIREXTALK_TEST_ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/json.sh"

[ "$#" -gt 0 ] || {
  echo "the test runner did not select any tests" >&2
  exit 2
}

# The Node runner owns the test plan and passes only the affected, quick, stage,
# or explicit full list. Keep this shell as one sequential Git Bash controller.
for test_spec in "$@"; do
  test_file=${test_spec%%::*}
  variant=
  [ "$test_file" = "$test_spec" ] || variant=${test_spec#*::}
  case "$test_file:$variant" in
    tests/*_test.sh:|tests/*_test.mjs:|tests/s6_run_phase_failure_test.sh:extended) ;;
    *) echo "invalid selected test: $test_spec" >&2; exit 2 ;;
  esac
  [ -f "$test_file" ] || { echo "selected test does not exist: $test_file" >&2; exit 2; }

  test_started=$SECONDS
  case "$test_file:$variant" in
    *.mjs:) "$(json_node)" "$test_file" ;;
    *:extended) bash "$test_file" --extended ;;
    *) bash "$test_file" ;;
  esac
  if [ "${DIREXTALK_TEST_TIMINGS:-0}" = 1 ]; then
    printf 'DIREXTALK_TEST_TIMING\t%s\t%ss\n' "$test_file" "$((SECONDS - test_started))"
  fi
done
