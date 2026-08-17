#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck disable=SC1091
source "$script_dir/production-ops-common.sh"

if production_migrate_message_mcp_token_binding; then
  printf 'production Message MCP token binding is canonical\n'
else
  status=$?
  case "$status" in
    3) exit 3 ;;
    *) exit 1 ;;
  esac
fi
