#!/usr/bin/env bash
# render-userdata.sh - render final cloud-init user-data.
#
# Bundle only the pinned updater bootstrap into user-data. The complete
# canonical split runtime is transferred later over the identity-fixed SSH
# channel because it cannot fit in the AWS user-data limit.
# Comment-only lines are stripped to keep AWS user-data below 16384 bytes.
# Replaces __DOMAIN__ /
# __ACME_EMAIL__ / __MESSAGE_SERVER_IMAGE__; the EC2 instance does not need to
# clone repos.
#
# Usage:
#   render-userdata.sh --domain <domain> --acme <email> --message-server-image <img> > user-data.yaml
#   render-userdata.sh --format shell --domain <domain> --acme <email> --message-server-image <img> > user-data.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CI="$HERE/cloud-init"
source "$HERE/lib/domain.sh"

DOMAIN=""; ACME=""; MESSAGE_SERVER_IMAGE=""; AGENT_IMAGE=""; CADDY_IMAGE=""; COTURN_IMAGE=""
MESSAGE_SOURCE_REVISION=""; SPLIT_SOURCE_REVISION=""; AGENT_SOURCE_REVISION=""; FORMAT="cloud-config"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT=$2; shift 2;;
    --domain) DOMAIN=$2; shift 2;;
    --acme) ACME=$2; shift 2;;
    --message-server-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    --agent-image) AGENT_IMAGE=$2; shift 2;;
    --caddy-image) CADDY_IMAGE=$2; shift 2;;
    --coturn-image) COTURN_IMAGE=$2; shift 2;;
    --message-source-revision) MESSAGE_SOURCE_REVISION=$2; shift 2;;
    --split-source-revision) SPLIT_SOURCE_REVISION=$2; shift 2;;
    --agent-source-revision) AGENT_SOURCE_REVISION=$2; shift 2;;
    --as-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
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
# Single-line base64 compatible with GNU/Linux and macOS/BSD base64.
b64() { base64 | tr -d '\n'; }
sed_replacement_escape() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }
split_env=''
split_cloud_env=''
for value in "$MESSAGE_SERVER_IMAGE" "$AGENT_IMAGE" "$CADDY_IMAGE" "$COTURN_IMAGE"; do
  printf '%s\n' "$value" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$' || {
    echo "split application and Caddy images must be immutable digest references" >&2
    exit 1
  }
done
for value in "$MESSAGE_SOURCE_REVISION" "$SPLIT_SOURCE_REVISION" "$AGENT_SOURCE_REVISION"; do
  printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "split image source revisions must be full lowercase Git commits" >&2
    exit 1
  }
done
split_env=$(printf 'AGENT_IMAGE=%s\nCADDY_IMAGE=%s\nCOTURN_IMAGE=%s\nMESSAGE_SOURCE_REVISION=%s\nSPLIT_SOURCE_REVISION=%s\nAGENT_SOURCE_REVISION=%s\n' \
  "$AGENT_IMAGE" "$CADDY_IMAGE" "$COTURN_IMAGE" "$MESSAGE_SOURCE_REVISION" "$SPLIT_SOURCE_REVISION" "$AGENT_SOURCE_REVISION")
split_cloud_env=$(printf '%s\n' "$split_env" | sed 's/^/      /')

# Build a deterministic tar.gz bundle with fixed permissions and no extra attrs.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/updater"
for updater_file in install.sh bootstrap-host.sh set-desired-state.sh release.env config.json dirextalk-updater.service; do
  tr -d '\r' < "$HERE/updater/$updater_file" > "$WORK/updater/$updater_file"
done
chmod 0644 "$WORK/updater/release.env" "$WORK/updater/config.json" "$WORK/updater/"*.service
chmod 0755 "$WORK/updater/install.sh" "$WORK/updater/bootstrap-host.sh" "$WORK/updater/set-desired-state.sh"
find "$WORK" -name '._*' -delete
# -C creates a flat archive. Explicit gzip avoids macOS tar stdout quirks.
# COPYFILE_DISABLE=1 avoids AppleDouble ._* extended-attribute files.
BUNDLE_B64=$(COPYFILE_DISABLE=1 tar -C "$WORK" -cf - updater | gzip -n | b64)

if [ "$FORMAT" = "shell" ]; then
  cat <<EOF
#!/bin/sh
# Lightsail executes user-data as a /bin/sh fragment and does not honor an
# embedded shebang. Enter Bash explicitly before using pipefail or Bash arrays.
exec /usr/bin/env bash <<'DIREXTALK_BOOTSTRAP_BASH'
#!/usr/bin/env bash
set -eux

mkdir -p /var/dirextalk-message-server
cat > /var/dirextalk-message-server/.env <<'DIREXTALK_ENV'
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME
MESSAGE_SERVER_IMAGE=$MESSAGE_SERVER_IMAGE
$split_env
DIREXTALK_ENV
chown 0:0 /var/dirextalk-message-server/.env
chmod 0600 /var/dirextalk-message-server/.env

base64 --decode > /var/dirextalk-message-server/bundle.tar.gz <<'DIREXTALK_BUNDLE'
$BUNDLE_B64
DIREXTALK_BUNDLE

tar -xzf /var/dirextalk-message-server/bundle.tar.gz -C /var/dirextalk-message-server
chmod 0755 /var/dirextalk-message-server/updater/install.sh /var/dirextalk-message-server/updater/bootstrap-host.sh

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
bash /var/dirextalk-message-server/updater/bootstrap-host.sh
DIREXTALK_BOOTSTRAP_BASH
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
UNPACK='  - mkdir -p /var/dirextalk-message-server && tar -xzf /var/dirextalk-message-server/bundle.tar.gz -C /var/dirextalk-message-server && chmod 0755 /var/dirextalk-message-server/updater/install.sh /var/dirextalk-message-server/updater/bootstrap-host.sh'

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
| sed "s#__DOMAIN__#$(sed_replacement_escape "$DOMAIN")#g; s#__ACME_EMAIL__#$(sed_replacement_escape "$ACME")#g; s#__MESSAGE_SERVER_IMAGE__#$(sed_replacement_escape "$MESSAGE_SERVER_IMAGE")#g" \
| awk -v split_env="$split_cloud_env" '
  /^      MESSAGE_SERVER_IMAGE=/ { print; if (split_env != "") printf "%s\n", split_env; next }
  { print }
' \
| strip_userdata_comments
