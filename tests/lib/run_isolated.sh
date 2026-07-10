#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
isolation_root=$(mktemp -d)
trap 'rm -rf "$isolation_root"' EXIT
export DIREXTALK_TEST_ROOT=$isolation_root

# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"
dirextalk_test_isolate_homes "$isolation_root"

[ "$#" -gt 0 ] || {
  echo "usage: run_isolated.sh <command> [args...]" >&2
  exit 2
}
"$@"
