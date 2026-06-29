#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
if [ "${DIREXIO_CREDENTIALS_FILE:-}" != "${EXPECTED_CREDENTIALS_FILE:-}" ]; then
  echo "wrong DIREXIO_CREDENTIALS_FILE" >&2
  exit 1
fi

frame() {
  local body=$1
  printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body"
}

frame '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake-direxio-mcp","version":"0.0.0"}}}'
frame '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search_rooms","description":"Search rooms"},{"name":"send_message","description":"Send message"},{"name":"list_messages","description":"List messages"}]}}'
EOF
chmod 700 "$fakebin/direxio-mcp"

cat > "$tmp/fake-mcp.ps1" <<'EOF'
if ($env:DIREXIO_CREDENTIALS_FILE -ne $env:EXPECTED_CREDENTIALS_FILE) {
  [Console]::Error.WriteLine("wrong DIREXIO_CREDENTIALS_FILE")
  exit 1
}

function Frame($body) {
  [Console]::Out.Write("Content-Length: $($body.Length)`r`n`r`n$body")
}

Frame '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake-direxio-mcp","version":"0.0.0"}}}'
Frame '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search_rooms","description":"Search rooms"},{"name":"send_message","description":"Send message"},{"name":"list_messages","description":"List messages"}]}}'
EOF

mcp_command=direxio-mcp
if ! command -v node >/dev/null 2>&1 && command -v node.exe >/dev/null 2>&1; then
  fake_mcp_ps1=$(windows_path "$tmp/fake-mcp.ps1")
  mcp_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$fake_mcp_ps1\""
fi

service_dir="$HOME/.direxio/nodes/mcp-tools.example.test"
mkdir -p "$service_dir"
credentials="$service_dir/credentials.json"
: > "$credentials"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  --arg credentials "$credentials" \
  --arg mcp_command "$mcp_command" \
  '{
    run_id: "mcp-tools-test",
    region: "ap-northeast-1",
    domain_mode: "user",
    domain: "mcp-tools.example.test",
    agent_service_id: "mcp-tools.example.test",
    agent_service_dir: $service_dir,
    agent_credentials_file: $credentials,
    mcp_credentials_file: $credentials,
    mcp_command: $mcp_command,
    phase: "S7_VERIFY_E2E",
    phases: {
      S0_PREREQ_AWS: {status: "done"},
      S1_PREFLIGHT: {status: "done"},
      S2_DOMAIN: {status: "done"},
      S3_PROVISION: {status: "done"},
      S4_BOOTSTRAP_STACK: {status: "done"},
      S5_INIT_TOKENS: {status: "done"},
      S6_WIRE_LOCAL: {status: "done"},
      S7_VERIFY_E2E: {status: "done"}
    },
    resources: {}
  }' > "$state"

verify_output=$(P2P_WORKDIR="$service_dir" PATH="$fakebin:$PATH" EXPECTED_CREDENTIALS_FILE="$credentials" bash "$ROOT/scripts/orchestrate.sh" verify mcp_tools)
printf '%s\n' "$verify_output" | grep -q 'verified runtime check: mcp_tools'

jq -e '
  .runtime_checks.mcp_tools.status == "passed"
  and .runtime_checks.mcp_tools.tool_count == 3
  and (.runtime_checks.mcp_tools.tools | index("search_rooms") != null)
  and (.runtime_checks.mcp_tools.tools | index("send_message") != null)
  and (.runtime_checks.mcp_tools.tools | index("list_messages") != null)
  and (.user_confirmations.agent_mcp_runtime | not)
' "$state" >/dev/null

report_output=$(P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
jq -e '
  .runtime_checks.mcp_tools.status == "passed"
  and .runtime_checks.mcp_tools.tool_count == 3
  and .gates.user_confirmation.agent_mcp_runtime == "pending_runtime_confirmation"
' "$report_path" >/dev/null

echo "mcp tools runtime check ok"
