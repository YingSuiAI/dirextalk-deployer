#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"
NODE_BIN=$(json_node)
JSON="$NODE_BIN scripts/json.mjs"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/input.json" <<'JSON'
{
  "domain": "im.test",
  "resources": {
    "instance_id": "i-123",
    "root_volume_gb": 50
  },
  "messages": [],
  "runtime_checks": {
    "summary": {
      "status": "passed"
    }
  }
}
JSON

[ "$($JSON get "$tmp/input.json" domain)" = "im.test" ]
[ "$($JSON get "$tmp/input.json" resources.instance_id)" = "i-123" ]
[ "$($JSON get "$tmp/input.json" missing.path fallback)" = "fallback" ]
[ "$(cat "$tmp/input.json" | $JSON stdin-get resources.root_volume_gb)" = "50" ]

$JSON assert "$tmp/input.json" path-equals runtime_checks.summary.status passed
$JSON assert "$tmp/input.json" path-missing user_confirmations.app_initialization
$JSON assert "$tmp/input.json" messages-list >/dev/null

$JSON build simple-state domain=im.test phase=S3_PROVISION resources.instance_id=i-abc > "$tmp/state.json"
[ "$($JSON get "$tmp/state.json" domain)" = "im.test" ]
[ "$($JSON get "$tmp/state.json" resources.instance_id)" = "i-abc" ]

$JSON mutate "$tmp/state.json" set-string resources.public_ip 203.0.113.10
[ "$($JSON get "$tmp/state.json" resources.public_ip)" = "203.0.113.10" ]

$JSON mutate "$tmp/state.json" set-json runtime_checks.summary '{"status":"failed","checks":{"mcp":"failed"}}'
[ "$($JSON get "$tmp/state.json" runtime_checks.summary.status)" = "failed" ]

echo "json helper ok"
