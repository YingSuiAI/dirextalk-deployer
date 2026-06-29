#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "$ROOT/.tmp-runtime-summary.XXXXXX")
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

cat > "$fakebin/direxio-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "daemon" ]
[ "${2:-}" = "status" ]
[ "${3:-}" = "--service-name" ]
[ "${4:-}" = "runtime-summary.example.test" ]
cat <<STATUS
cc-connect daemon status

  Status:    Running
  Platform:  test
  WorkDir:   ${CONNECT_WORK_DIR:-}
STATUS
EOF
chmod 700 "$fakebin/direxio-connect"

cat > "$fakebin/direxio-mcp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${DIREXIO_CREDENTIALS_FILE:-}" != "${EXPECTED_CREDENTIALS_FILE:-}" ]; then
  echo "wrong DIREXIO_CREDENTIALS_FILE" >&2
  exit 1
fi

if [ "${1:-}" = "doctor" ] && [ "${2:-}" = "--json" ]; then
  printf '{"ok":true,"domain":"runtime-summary.example.test","agent_room_id":"!agent:runtime-summary.example.test","token":"redacted"}\n'
  exit 0
fi

frame() {
  local body=$1
  printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body"
}

frame '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake-direxio-mcp","version":"0.0.0"}}}'
frame '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search_rooms"},{"name":"send_message"},{"name":"list_messages"}]}}'
EOF
chmod 700 "$fakebin/direxio-mcp"

cat > "$tmp/fake-mcp.ps1" <<'EOF'
if ($env:DIREXIO_CREDENTIALS_FILE -ne $env:EXPECTED_CREDENTIALS_FILE) {
  [Console]::Error.WriteLine("wrong DIREXIO_CREDENTIALS_FILE")
  exit 1
}

if (($args.Count -ge 2) -and ($args[0] -eq "doctor") -and ($args[1] -eq "--json")) {
  [Console]::Out.WriteLine('{"ok":true,"domain":"runtime-summary.example.test","agent_room_id":"!agent:runtime-summary.example.test","token":"redacted"}')
  exit 0
}

function Frame($body) {
  [Console]::Out.Write("Content-Length: $($body.Length)`r`n`r`n$body")
}

Frame '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake-direxio-mcp","version":"0.0.0"}}}'
Frame '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search_rooms"},{"name":"send_message"},{"name":"list_messages"}]}}'
EOF

mcp_command=direxio-mcp
if ! command -v node >/dev/null 2>&1 && command -v node.exe >/dev/null 2>&1; then
  fake_mcp_ps1=$(windows_path "$tmp/fake-mcp.ps1")
  mcp_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$fake_mcp_ps1\""
fi

cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body_path=""
write_code=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) body_path=$2; shift 2 ;;
    -w) write_code=1; shift 2 ;;
    *) shift ;;
  esac
done
payload='{"room_id":"!agent:runtime-summary.example.test","messages":[]}'
if [ -n "$body_path" ]; then
  printf '%s\n' "$payload" > "$body_path"
else
  printf '%s\n' "$payload"
fi
[ "$write_code" -eq 1 ] && printf '200'
EOF
chmod 700 "$fakebin/curl"

service_dir="$HOME/.direxio/nodes/runtime-summary.example.test"
mkdir -p "$service_dir/cc-connect"
credentials="$service_dir/credentials.json"
config="$service_dir/cc-connect/config.toml"
: > "$credentials"
: > "$config"
state="$service_dir/state.json"
jq -n \
  --arg service_dir "$service_dir" \
  --arg credentials "$credentials" \
  --arg config "$config" \
  --arg mcp_command "$mcp_command" \
  '{
    run_id: "runtime-summary-test",
    region: "ap-northeast-1",
    domain_mode: "user",
    domain: "runtime-summary.example.test",
    as_url: "https://runtime-summary.example.test",
    agent_service_id: "runtime-summary.example.test",
    agent_service_dir: $service_dir,
    agent_credentials_file: $credentials,
    mcp_credentials_file: $credentials,
    mcp_command: $mcp_command,
    agent_token: "AGENT_TOKEN_RUNTIME",
    agent_room_id: "!agent:runtime-summary.example.test",
    cc_connect_config: $config,
    cc_connect_binary: "direxio-connect",
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

verify_output=$(P2P_WORKDIR="$service_dir" PATH="$fakebin:$PATH" EXPECTED_CREDENTIALS_FILE="$credentials" CONNECT_WORK_DIR="$service_dir/cc-connect" bash "$ROOT/scripts/orchestrate.sh" verify runtime)
printf '%s\n' "$verify_output" | grep -q 'verified runtime checks: passed'

jq -e '
  .runtime_checks.summary.status == "passed"
  and .runtime_checks.summary.failed_count == 0
  and .runtime_checks.summary.checks.connect_daemon == "passed"
  and .runtime_checks.summary.checks.mcp_doctor == "passed"
  and .runtime_checks.summary.checks.mcp_tools == "passed"
  and .runtime_checks.summary.checks.mcp_smoke == "passed"
  and (.user_confirmations.agent_mcp_runtime | not)
' "$state" >/dev/null

report_output=$(P2P_WORKDIR="$service_dir" bash "$ROOT/scripts/orchestrate.sh" report new_deploy)
report_path=$(printf '%s\n' "$report_output" | sed -nE 's/^operation report: //p' | tail -n 1)
jq -e '.runtime_checks.summary.status == "passed"' "$report_path" >/dev/null

set +e
P2P_WORKDIR="$service_dir" PATH="$fakebin:$PATH" EXPECTED_CREDENTIALS_FILE="$credentials" CONNECT_WORK_DIR="$HOME/.direxio/nodes/other.example.test/cc-connect" bash "$ROOT/scripts/orchestrate.sh" verify runtime > "$tmp/runtime-fail.out" 2>&1
fail_rc=$?
set -e
[ "$fail_rc" -ne 0 ] || {
  echo "runtime summary must fail when any runtime check fails" >&2
  exit 1
}
jq -e '
  .runtime_checks.summary.status == "failed"
  and .runtime_checks.summary.failed_count == 1
  and .runtime_checks.summary.checks.connect_daemon == "failed"
  and .runtime_checks.summary.checks.mcp_doctor == "passed"
  and .runtime_checks.summary.checks.mcp_tools == "passed"
  and .runtime_checks.summary.checks.mcp_smoke == "passed"
' "$state" >/dev/null

echo "runtime summary check ok"
