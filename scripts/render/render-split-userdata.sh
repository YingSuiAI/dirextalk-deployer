#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
cloud_split=$root/scripts/cloud-init/split
message_root=${DIREXTALK_MESSAGE_SERVER_ROOT:-$root/../dirextalk-message-server}
split=$message_root/deploy/split-agent
split_scripts=(
  provision-local.sh
  initialize-capability-ca.sh
  initialize-message-server.sh
  materialize-agent-secrets.sh
  message-server-entrypoint.sh
)
domain=''
acme=''
message=''
agent=''
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain=$2; shift 2 ;;
    --acme) acme=$2; shift 2 ;;
    --message-image) message=$2; shift 2 ;;
    --agent-image) agent=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
for value in "$domain" "$message" "$agent"; do [ -n "$value" ] || { echo "domain and both image digests are required" >&2; exit 2; }; done
[ -f "$split/compose.yaml" ] || {
  echo "missing canonical split deployment file: $split/compose.yaml (set DIREXTALK_MESSAGE_SERVER_ROOT)" >&2
  exit 1
}
for script in "${split_scripts[@]}"; do
  [ -f "$split/scripts/$script" ] || {
    echo "missing canonical split deployment script: $split/scripts/$script (set DIREXTALK_MESSAGE_SERVER_ROOT)" >&2
    exit 1
  }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/deploy/split-agent/scripts"
cp "$split/compose.yaml" "$work/deploy/split-agent/compose.yaml"
cp "$cloud_split/edge-compose.yaml" "$work/deploy/split-agent/edge-compose.yaml"
for script in "${split_scripts[@]}"; do
  cp "$split/scripts/$script" "$work/deploy/split-agent/scripts/$script"
done
cp "$cloud_split/bootstrap-split-stack.sh" "$work/bootstrap-split-stack.sh"
chmod 0755 "$work/bootstrap-split-stack.sh" "$work/deploy/split-agent/scripts/"*.sh
bundle=$(tar -C "$work" -cf - . | gzip -n | base64 | tr -d '\n')
cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
install -d -m 0700 /var/dirextalk-message-server
base64 -d >/var/dirextalk-message-server/split-bundle.tar.gz <<'BUNDLE'
$bundle
BUNDLE
tar -xzf /var/dirextalk-message-server/split-bundle.tar.gz -C /var/dirextalk-message-server
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
systemctl enable --now docker
DOMAIN=$domain ACME_EMAIL=$acme MESSAGE_SERVER_IMAGE=$message AGENT_IMAGE=$agent bash /var/dirextalk-message-server/bootstrap-split-stack.sh
EOF
