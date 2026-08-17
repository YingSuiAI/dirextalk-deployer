#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck disable=SC1091
source "$script_dir/production-ops-common.sh"

if "$script_dir/migrate-message-mcp-token-binding.sh"; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'Message MCP token binding migration reported an expected negative state' ;;
    *) production_die 'Message MCP token binding migration failed' ;;
  esac
fi
production_bind_runtime
production_verify_edge
if "$script_dir/bootstrap-production.sh" --reconcile-edge; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'edge reconcile reported an expected negative state' ;;
    *) production_die 'edge reconcile failed' ;;
  esac
fi
production_bind_runtime
production_verify_edge
if "$script_dir/recover-production.sh"; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'existing runtime recovery reported an expected negative state' ;;
    *) production_die 'existing runtime recovery failed' ;;
  esac
fi
production_bind_runtime
production_verify_edge
portal_parent=$production_base/p2p
portal_bootstrap=$portal_parent/bootstrap.json
[ -d "$portal_parent" ] && [ ! -L "$portal_parent" ] || production_die 'portal bootstrap parent is unavailable'
[ "$(stat -c '%u:%a' "$portal_parent")" = "$(id -u):700" ] || production_die 'portal bootstrap parent owner or mode differs'
production_require_control_file "$portal_bootstrap" 400
portal_parent_identity=$(stat -c '%d:%i:%u' "$portal_parent")
portal_bootstrap_identity=$(stat -c '%d:%i:%u' "$portal_bootstrap")
portal_bootstrap_sha=$(sha256sum "$portal_bootstrap" | awk '{print $1}')
refresh_dir=$(mktemp -d "$portal_parent/.bootstrap-refresh.XXXXXX")
chmod 0700 "$refresh_dir"
[ "$(stat -c '%u:%a' "$refresh_dir")" = "$(id -u):700" ] || production_die 'portal bootstrap refresh directory owner or mode differs'
refresh_bootstrap=$refresh_dir/bootstrap.json
cleanup_refresh() {
  rm -f "$refresh_bootstrap"
  rmdir "$refresh_dir" 2>/dev/null || true
}
trap cleanup_refresh EXIT
if "$production_split/scripts/export-portal-bootstrap.sh" "$production_run" "$refresh_bootstrap" >/dev/null; then
  :
else
  status=$?
  case "$status" in
    3) production_negative 'portal bootstrap refresh reported an expected negative state' ;;
    *) production_die 'portal bootstrap refresh failed' ;;
  esac
fi
[ -f "$refresh_bootstrap" ] && [ ! -L "$refresh_bootstrap" ] || production_die 'refreshed portal bootstrap is not a regular control file'
[ "$(stat -c '%u:%a' "$refresh_bootstrap")" = "$(id -u):400" ] || production_die 'refreshed portal bootstrap owner or mode differs'
refresh_identity=$(stat -c '%d:%i:%u' "$refresh_bootstrap")
if python3 - "$refresh_bootstrap" <<'PY'
import json
import pathlib
import sys

try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
required = ("access_token", "agent_token", "password", "owner_user_id")
if not isinstance(data, dict) or any(not isinstance(data.get(key), str) or not data[key] for key in required):
    raise SystemExit(1)
PY
then
  :
else
  production_die 'refreshed portal bootstrap JSON is incomplete'
fi
refresh_sha=$(sha256sum "$refresh_bootstrap" | awk '{print $1}')

# Rebind the receipt-owned runtime and exact Edge identity after the external
# export, then ensure none of the replacement boundaries changed before the
# atomic same-filesystem commit.
production_bind_runtime
production_verify_edge
[ "$(stat -c '%d:%i:%u' "$portal_parent")" = "$portal_parent_identity" ] || production_die 'portal bootstrap parent identity changed during refresh'
[ "$(stat -c '%u:%a' "$portal_parent")" = "$(id -u):700" ] || production_die 'portal bootstrap parent owner or mode changed during refresh'
[ "$(stat -c '%d:%i:%u' "$portal_bootstrap")" = "$portal_bootstrap_identity" ] || production_die 'canonical portal bootstrap identity changed during refresh'
[ "$(sha256sum "$portal_bootstrap" | awk '{print $1}')" = "$portal_bootstrap_sha" ] || production_die 'canonical portal bootstrap contents changed during refresh'
[ "$(stat -c '%d:%i:%u' "$refresh_bootstrap")" = "$refresh_identity" ] || production_die 'refreshed portal bootstrap identity changed before commit'
[ "$(sha256sum "$refresh_bootstrap" | awk '{print $1}')" = "$refresh_sha" ] || production_die 'refreshed portal bootstrap contents changed before commit'
[ "$(stat -c '%u:%a' "$portal_bootstrap")" = "$(id -u):400" ] || production_die 'canonical portal bootstrap owner or mode changed during refresh'
[ "$(stat -c '%u:%a' "$refresh_bootstrap")" = "$(id -u):400" ] || production_die 'refreshed portal bootstrap owner or mode changed before commit'
mv -f "$refresh_bootstrap" "$portal_bootstrap" || production_die 'portal bootstrap atomic replacement failed'
[ -f "$portal_bootstrap" ] && [ ! -L "$portal_bootstrap" ] || production_die 'canonical portal bootstrap replacement is not a regular control file'
[ "$(stat -c '%d:%i:%u' "$portal_bootstrap")" = "$refresh_identity" ] || production_die 'canonical portal bootstrap replacement identity differs'
[ "$(stat -c '%u:%a' "$portal_bootstrap")" = "$(id -u):400" ] || production_die 'canonical portal bootstrap replacement owner or mode differs'
[ "$(sha256sum "$portal_bootstrap" | awk '{print $1}')" = "$refresh_sha" ] || production_die 'canonical portal bootstrap replacement contents differ'
cleanup_refresh
trap - EXIT
printf 'production split reconcile passed: stack=%s edge=%s\n' "$production_stack" "$production_edge_id"
