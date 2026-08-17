#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'split host dependencies: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die 'root is required'
command -v apt-get >/dev/null 2>&1 || die 'apt-get is required on the Ubuntu production host'
json_cli=jq
if [ "${DIREXTALK_SPLIT_TEST_MODE:-false}" = true ]; then
  json_cli=${DIREXTALK_SPLIT_JSON_CLI:-jq}
fi

if ! command -v "$json_cli" >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends jq
fi

command -v "$json_cli" >/dev/null 2>&1 || die 'jq installation did not provide an executable'
