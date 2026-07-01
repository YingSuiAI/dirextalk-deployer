#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d "$ROOT/.tmp-mcp-tools.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"

windows_path() {
  local path=$1 drive rest
  case "$path" in
    /mnt/[A-Za-z]/*)
      drive=${path#/mnt/}
      drive=${drive%%/*}
      rest=${path#/mnt/$drive/}
      printf '%s:\\%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | sed 's#/#\\#g')"
      ;;
    /[A-Za-z]/*)
      drive=${path#/}
      drive=${drive%%/*}
      rest=${path#/$drive/}
      printf '%s:\\%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | sed 's#/#\\#g')"
      ;;
    *) printf '%s\n' "$path" ;;
  esac
}

cat > "$fakebin/direxio-mcp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "fake direxio-mcp executable should be resolved but not directly executed" >&2
exit 1
EOF
chmod 700 "$fakebin/direxio-mcp"

fake_pkg="$fakebin/node_modules/direxio-mcp"
mkdir -p "$fake_pkg/dist" "$fake_pkg/node_modules/@modelcontextprotocol/sdk/dist/esm/client"
cat > "$fake_pkg/package.json" <<'EOF'
{"name":"direxio-mcp","version":"0.0.0","type":"module"}
EOF
cat > "$fake_pkg/dist/index.js" <<'EOF'
#!/usr/bin/env node
throw new Error("fake MCP server entry should be launched by the SDK transport only");
EOF
cat > "$fake_pkg/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js" <<'EOF'
export class StdioClientTransport {
  constructor(options) {
    this.options = options;
  }
}
EOF
cat > "$fake_pkg/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js" <<'EOF'
export class Client {
  constructor(clientInfo, options) {
    this.clientInfo = clientInfo;
    this.options = options;
  }
  async connect(transport) {
    const serverEntry = String(transport?.options?.args?.[0] || "").replace(/\\/g, "/");
    if (!serverEntry.endsWith("dist/index.js")) {
      throw new Error("SDK transport did not receive direxio-mcp dist/index.js");
    }
    if (transport.options.env.DIREXIO_CREDENTIALS_FILE !== process.env.EXPECTED_CREDENTIALS_FILE) {
      throw new Error("wrong DIREXIO_CREDENTIALS_FILE");
    }
  }
  async listTools() {
    return {
      tools: [
        { name: "search_rooms", description: "Search rooms" },
        { name: "send_message", description: "Send message" },
        { name: "list_messages", description: "List messages" }
      ]
    };
  }
  async close() {}
}
EOF

mcp_command=direxio-mcp
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) use_windows_mcp=1 ;;
  *) use_windows_mcp=0 ;;
esac
if [ "$use_windows_mcp" = "1" ] && command -v cygpath >/dev/null 2>&1; then
  mcp_command=$(cygpath -w "$fakebin/direxio-mcp")
elif { [ "$use_windows_mcp" = "1" ] || ! command -v node >/dev/null 2>&1; } && command -v node.exe >/dev/null 2>&1; then
  mcp_command="$fakebin/direxio-mcp"
fi

service_dir="$HOME/.direxio/nodes/mcp-tools.example.test"
mkdir -p "$service_dir"
credentials="$service_dir/credentials.json"
: > "$credentials"
expected_credentials="$credentials"
if command -v cygpath >/dev/null 2>&1; then
  expected_credentials=$(cygpath -m "$expected_credentials")
fi
state="$service_dir/state.json"
json_build object \
  run_id=mcp-tools-test \
  region=ap-northeast-1 \
  domain_mode=user \
  domain=mcp-tools.example.test \
  agent_service_id=mcp-tools.example.test \
  "agent_service_dir=$service_dir" \
  "agent_credentials_file=$credentials" \
  "mcp_credentials_file=$credentials" \
  "mcp_command=$mcp_command" \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  'resources={}' > "$state"

verify_output=$(DIREXIO_WORKDIR="$service_dir" PATH="$fakebin:$PATH" EXPECTED_CREDENTIALS_FILE="$expected_credentials" bash "$ROOT/scripts/orchestrate.sh" verify mcp_tools)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_tools'

json_test_check "$state" "data.runtime_checks.mcp_tools.status === 'passed' && data.runtime_checks.mcp_tools.tool_count === 3 && data.runtime_checks.mcp_tools.tools.includes('search_rooms') && data.runtime_checks.mcp_tools.tools.includes('send_message') && data.runtime_checks.mcp_tools.tools.includes('list_messages') && !data.user_confirmations?.agent_mcp_runtime"

report_output=$(DIREXIO_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
json_test_check "$report_path" "data.runtime_checks.mcp_tools.status === 'passed' && data.runtime_checks.mcp_tools.tool_count === 3 && data.gates.user_confirmation.agent_mcp_runtime === 'pending_runtime_confirmation'"

echo "mcp tools runtime check ok"
