#!/usr/bin/env bash
# render-userdata.sh - render final cloud-init user-data.
#
# Bundle cloud-init deployment files (docker-compose.yml / Caddyfile /
# init-tokens.sh / p2p-http-request.sh) into a tar.gz, inline it as one write_files entry, and unpack
# it to /var/dirextalk-message-server in runcmd. Comment-only lines are stripped at the end to keep
# AWS user-data below the 16384-byte limit. Replaces __DOMAIN__ /
# __ACME_EMAIL__ / __MESSAGE_SERVER_IMAGE__; the EC2 instance does not need to
# clone repos. An optional Agent bundle is rendered only when all three
# reviewed, non-secret Agent inputs are present.
#
# Usage:
#   render-userdata.sh --domain <domain> --acme <email> --message-server-image <img> > user-data.yaml
#   render-userdata.sh --format shell --domain <domain> --acme <email> --message-server-image <img> > user-data.sh
#   render-userdata.sh ... --agent-image <tag@digest> --agent-instance-id <uuid> --agent-model-profiles-file <json>
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CI="$HERE/cloud-init"
source "$HERE/lib/domain.sh"
source "$HERE/lib/agent-release.sh"

DOMAIN=""; ACME=""; MESSAGE_SERVER_IMAGE=""; FORMAT="cloud-config"
AGENT_IMAGE=""; AGENT_INSTANCE_ID=""; AGENT_MODEL_PROFILES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT=$2; shift 2;;
    --domain) DOMAIN=$2; shift 2;;
    --acme) ACME=$2; shift 2;;
    --message-server-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    --as-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    --agent-image) AGENT_IMAGE=$2; shift 2;;
    --agent-instance-id) AGENT_INSTANCE_ID=$2; shift 2;;
    --agent-model-profiles-file) AGENT_MODEL_PROFILES_FILE=$2; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$MESSAGE_SERVER_IMAGE" ] || { echo "--message-server-image required" >&2; exit 1; }
[ -n "$DOMAIN" ] || { echo "--domain required; production deployments require a real domain" >&2; exit 1; }
DOMAIN=$(domain_normalize "$DOMAIN")
[ "$DOMAIN" != "PLACEHOLDER" ] || { echo "PLACEHOLDER/sslip.io domains are not accepted in the production renderer" >&2; exit 1; }
domain_is_formal_name "$DOMAIN" || { echo "invalid production domain: $DOMAIN" >&2; exit 1; }
case "$FORMAT" in
  cloud-config|shell) ;;
  *) echo "invalid --format: $FORMAT" >&2; exit 1 ;;
esac
agent_enabled=0
if [ -n "$AGENT_IMAGE$AGENT_INSTANCE_ID$AGENT_MODEL_PROFILES_FILE" ]; then
  agent_image_is_immutable "$AGENT_IMAGE" || {
    echo "--agent-image must be a prerelease tag plus lowercase sha256 digest" >&2
    exit 1
  }
  agent_instance_id_is_canonical "$AGENT_INSTANCE_ID" || {
    echo "--agent-instance-id must be a canonical non-nil lowercase UUID" >&2
    exit 1
  }
  agent_model_profiles_file_is_safe "$AGENT_MODEL_PROFILES_FILE" || {
    echo "--agent-model-profiles-file must be a readable, non-empty regular file" >&2
    exit 1
  }
  agent_enabled=1
fi
# Single-line base64 compatible with GNU/Linux and macOS/BSD base64.
b64() { base64 | tr -d '\n'; }
sed_replacement_escape() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }
render_optional_agent_sections() {
  local enabled=$1
  awk -v enabled="$enabled" '
    /DIREXTALK_AGENT_OPTIONAL_BEGIN/ { skip = (enabled != 1); next }
    /DIREXTALK_AGENT_OPTIONAL_END/ { skip = 0; next }
    !skip { print }
  ' "$CI/docker-compose.yml"
}

# Build a deterministic tar.gz bundle with fixed permissions and no extra attrs.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
render_optional_agent_sections "$agent_enabled" > "$WORK/docker-compose.yml"
cp "$CI/Caddyfile"          "$WORK/Caddyfile"
tr -d '\r' < "$CI/init-tokens.sh" > "$WORK/init-tokens.sh"
tr -d '\r' < "$CI/p2p-http-request.sh" > "$WORK/p2p-http-request.sh"
if [ "$agent_enabled" = 1 ]; then
  tr -d '\r' < "$CI/agent-db-init.sh" > "$WORK/agent-db-init.sh"
  tr -d '\r' < "$CI/agent-runtime-init.sh" > "$WORK/agent-runtime-init.sh"
  cp "$AGENT_MODEL_PROFILES_FILE" "$WORK/agent-model-profiles.json"
fi
mkdir -p "$WORK/updater"
for updater_file in install.sh bootstrap-host.sh set-desired-state.sh release.env config.json config.legacy-compose-caddy.json dirextalk-updater.service; do
  tr -d '\r' < "$HERE/updater/$updater_file" > "$WORK/updater/$updater_file"
done
chmod 0644 "$WORK/docker-compose.yml" "$WORK/Caddyfile"
if [ "$agent_enabled" = 1 ]; then
  chmod 0644 "$WORK/agent-model-profiles.json"
  chmod 0755 "$WORK/agent-db-init.sh" "$WORK/agent-runtime-init.sh"
fi
chmod 0644 "$WORK/updater/release.env" "$WORK/updater/config.json" "$WORK/updater/config.legacy-compose-caddy.json" "$WORK/updater/"*.service
chmod 0755 "$WORK/init-tokens.sh" "$WORK/p2p-http-request.sh" "$WORK/updater/install.sh" "$WORK/updater/bootstrap-host.sh" "$WORK/updater/set-desired-state.sh"
find "$WORK" -name '._*' -delete
# -C creates a flat archive. Explicit gzip avoids macOS tar stdout quirks.
# COPYFILE_DISABLE=1 avoids AppleDouble ._* extended-attribute files.
bundle_files=(docker-compose.yml Caddyfile init-tokens.sh p2p-http-request.sh updater)
if [ "$agent_enabled" = 1 ]; then
  bundle_files+=(agent-db-init.sh agent-runtime-init.sh agent-model-profiles.json)
fi
# Use deterministic maximum compression: the Lightsail shell user-data limit is
# 16 KiB, and the optional Agent bundle leaves little headroom with long pinned
# image references.
BUNDLE_B64=$(COPYFILE_DISABLE=1 tar -C "$WORK" -cf - "${bundle_files[@]}" | gzip -9n | b64)

if [ "$FORMAT" = "shell" ]; then
  cat <<EOF
#!/usr/bin/env bash
set -eux

mkdir -p /var/dirextalk-message-server
cd /var/dirextalk-message-server
cat > .env <<'DIREXTALK_ENV'
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME
MESSAGE_SERVER_IMAGE=$MESSAGE_SERVER_IMAGE
AGENT_IMAGE=$AGENT_IMAGE
AGENT_INSTANCE_ID=$AGENT_INSTANCE_ID
DIREXTALK_ENV

base64 --decode > bundle.tar.gz <<'DIREXTALK_BUNDLE'
$BUNDLE_B64
DIREXTALK_BUNDLE

tar -xzf bundle.tar.gz
chmod 0755 init-tokens.sh p2p-http-request.sh updater/install.sh updater/bootstrap-host.sh

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
bash updater/bootstrap-host.sh
EOF
  exit 0
fi

# Generate user-data: append the bundle entry to write_files and unpack first in runcmd.
# Avoid passing multiline strings via awk -v; macOS awk rejects newline in string.
EXTRA_WF=$(mktemp); trap 'rm -rf "$WORK" "$EXTRA_WF"' EXIT
cat > "$EXTRA_WF" <<EOF
  - path: /var/dirextalk-message-server/bundle.tar.gz
    permissions: '0644'
    encoding: b64
    content: $BUNDLE_B64
EOF

# Insert unpack as the first runcmd step before Docker install / compose up.
UNPACK='  - mkdir -p /var/dirextalk-message-server && tar -xzf /var/dirextalk-message-server/bundle.tar.gz -C /var/dirextalk-message-server && chmod 0755 /var/dirextalk-message-server/init-tokens.sh /var/dirextalk-message-server/p2p-http-request.sh /var/dirextalk-message-server/updater/install.sh /var/dirextalk-message-server/updater/bootstrap-host.sh'

strip_userdata_comments() {
  awk '
    NR == 1 && $0 == "#cloud-config" { print; next }
    /^[[:space:]]*#/ { next }
    { print }
  '
}

awk -v wf="$EXTRA_WF" -v unpack="$UNPACK" '
  # Insert bundle entry before runcmd.
  /^runcmd:/ && !wfdone {
    while ((getline line < wf) > 0) print line
    close(wf)
    print
    print unpack
    wfdone=1
    next
  }
  { print }
' "$CI/user-data.yaml" \
| sed "s#__DOMAIN__#$(sed_replacement_escape "$DOMAIN")#g; s#__ACME_EMAIL__#$(sed_replacement_escape "$ACME")#g; s#__MESSAGE_SERVER_IMAGE__#$(sed_replacement_escape "$MESSAGE_SERVER_IMAGE")#g; s#__AGENT_IMAGE__#$(sed_replacement_escape "$AGENT_IMAGE")#g; s#__AGENT_INSTANCE_ID__#$(sed_replacement_escape "$AGENT_INSTANCE_ID")#g" \
| strip_userdata_comments
