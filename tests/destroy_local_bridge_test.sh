#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    case "$*" in
      *"--query Arn"*) printf 'arn:aws:iam::123456789012:user/DirexioDeployer-Test\n' ;;
      *"--query Account"*) printf '123456789012\n' ;;
      *) printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/DirexioDeployer-Test"}\n' ;;
    esac
    ;;
  "ec2 terminate-instances") exit 0 ;;
  "ec2 wait") exit 0 ;;
  "ec2 release-address") exit 0 ;;
  "ec2 delete-security-group") exit 0 ;;
  "ec2 delete-key-pair") exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 700 "$fakebin/aws"

cat > "$fakebin/direxio-connect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'direxio-connect' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "status" ]; then
  [ "${3:-}" = "--service-name" ]
  [ -n "${4:-}" ]
  cat <<STATUS
cc-connect daemon status

  Status:    Running
  Platform:  test
  WorkDir:   ${STATUS_WORK_DIR:-}
STATUS
fi
EOF
chmod 700 "$fakebin/direxio-connect"

write_state() {
  local state=$1 domain=$2 service_dir=$3
  mkdir -p "$(dirname "$state")" "$service_dir/cc-connect"
  : > "$service_dir/cc-connect/config.toml"
  jq -n \
    --arg region "us-east-1" \
    --arg domain "$domain" \
    --arg service_dir "$service_dir" \
    '{
      region: $region,
      domain_mode: "user",
      domain: $domain,
      as_url: ("https://" + $domain),
      agent_service_dir: $service_dir,
      agent_service_id: $domain,
      resources: {
        instance_id: "i-test",
        eip_id: "eipalloc-test",
        sg_id: "sg-test",
        key_name: "direxio-test"
      }
    }' > "$state"
}

run_destroy() {
  local state=$1 calls=$2 status_work_dir=$3
  : > "$calls"
  CALLS="$calls" STATUS_WORK_DIR="$status_work_dir" PATH="$fakebin:$PATH" bash "$ROOT/scripts/destroy.sh" "$state" >/dev/null
}

current_service="$HOME/.direxio/nodes/a5.direxio.ai"
current_state="$current_service/state.json"
current_calls="$tmp/current.calls"
write_state "$current_state" "a5.direxio.ai" "$current_service"
run_destroy "$current_state" "$current_calls" "$current_service/cc-connect"

grep -q '^direxio-connect daemon status --service-name a5.direxio.ai$' "$current_calls" || {
  echo "destroy should query the current named daemon status" >&2
  cat "$current_calls" >&2
  exit 1
}

grep -q '^direxio-connect daemon stop --service-name a5.direxio.ai$' "$current_calls" || {
  echo "destroy should stop the daemon when daemon status WorkDir matches the current service cc-connect dir" >&2
  cat "$current_calls" >&2
  exit 1
}

if [ -d "$current_service" ]; then
  echo "destroy should remove the current service directory after stopping its daemon" >&2
  exit 1
fi

other_service="$HOME/.direxio/nodes/b5.direxio.ai"
other_state="$other_service/state.json"
active_other_service="$HOME/.direxio/nodes/active-other"
other_calls="$tmp/other.calls"
mkdir -p "$active_other_service/cc-connect"
write_state "$other_state" "b5.direxio.ai" "$other_service"
run_destroy "$other_state" "$other_calls" "$active_other_service/cc-connect"

grep -q '^direxio-connect daemon status --service-name b5.direxio.ai$' "$other_calls" || {
  echo "destroy should query the named daemon for the service being destroyed" >&2
  cat "$other_calls" >&2
  exit 1
}

if grep -q '^direxio-connect daemon stop' "$other_calls"; then
  echo "destroy must not stop a daemon whose status WorkDir belongs to a different service" >&2
  cat "$other_calls" >&2
  exit 1
fi

if [ -d "$other_service" ]; then
  echo "destroy should remove the current service directory even when another service daemon is active" >&2
  exit 1
fi

if [ ! -d "$active_other_service" ]; then
  echo "destroy must not remove another service directory" >&2
  exit 1
fi

echo "destroy local bridge ok"
