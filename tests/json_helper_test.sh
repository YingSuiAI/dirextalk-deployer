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

mkdir -p "$tmp/bin"
cat > "$tmp/bin/node-no-secret-argv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${NODE_ARGV_LOG:?}"
exec "$NODE_BIN" "\$@"
EOF
chmod 700 "$tmp/bin/node-no-secret-argv"
NODE_ARGV_LOG="$tmp/node-argv.log" NODE="$tmp/bin/node-no-secret-argv" json_build object agent_token=SECRET_ARGV_SENTINEL > "$tmp/argv-safe.json"
if grep -q 'SECRET_ARGV_SENTINEL' "$tmp/node-argv.log"; then
  echo "JSON secret values must be delivered over stdin, not Node argv" >&2
  exit 1
fi
json_check "$tmp/argv-safe.json" "data.agent_token === 'SECRET_ARGV_SENTINEL'"

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

if $JSON build mcp-messages-list '!room:im.test' > "$tmp/legacy-mcp-action.json" 2>/dev/null; then
  echo "retired mcp-messages-list body action must not be generated" >&2
  exit 1
fi
if $JSON build mcp-http-json-config server https://service.example.test/mcp token > "$tmp/legacy-mcp-config.json" 2>/dev/null; then
  echo "retired token-bearing standalone MCP config action must not be generated" >&2
  exit 1
fi

echo "json helper ok"
