#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/json.sh"
"$(json_node)" "$ROOT/tests/server_release_resolver_test.mjs"
"$(json_node)" "$ROOT/tests/server_release_fetch_test.mjs"
