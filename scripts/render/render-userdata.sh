#!/usr/bin/env bash
# render-userdata.sh - render final cloud-init user-data.
#
# Bundle cloud-init deployment files (docker-compose.yml / Caddyfile /
# init-tokens.sh / p2p-http-request.sh) into a tar.gz, inline it as one write_files entry, and unpack
# it to /var/dirextalk-message-server in runcmd. Comment-only lines are stripped at the end to keep
# EC2 cloud-init compact. Replaces __DOMAIN__ /
# __ACME_EMAIL__ / __MESSAGE_SERVER_IMAGE__; the EC2 instance does not need to
# clone repos. An optional Agent bundle is rendered only when all three
# reviewed, non-secret Agent inputs are present.
#
# Usage:
#   render-userdata.sh --domain <domain> --acme <email> --message-server-image <img> > user-data.yaml
#   render-userdata.sh --format shell --domain <domain> --acme <email> --message-server-image <img> > user-data.sh
#   render-userdata.sh --format bundle --bundle-output <archive.tar.gz> ...
#   render-userdata.sh ... --agent-image <tag@digest> --agent-instance-id <uuid> --agent-model-profiles-file <json>
#     [--agent-enable-aws-control true --agent-aws-reaper-image-uri <image@sha256:...>
#      --agent-worker-control-endpoint grpcs://<dns-name>:443
#      --agent-enable-managed-preparation-aws <true|false> --agent-worker-ami-publication-file <json>
#      --agent-worker-ami-publication-sha256 <lowercase-hex>]
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CI="$HERE/cloud-init"
source "$HERE/lib/domain.sh"
source "$HERE/lib/json.sh"
source "$HERE/lib/agent-release.sh"

DOMAIN=""; ACME=""; MESSAGE_SERVER_IMAGE=""; FORMAT="cloud-config"; BUNDLE_OUTPUT=""; DEFER_COMPOSE_START=0
AGENT_IMAGE=""; AGENT_INSTANCE_ID=""; AGENT_MODEL_PROFILES_FILE=""
AGENT_ENABLE_AWS_CONTROL=false; AGENT_AWS_REAPER_IMAGE_URI=""; AGENT_WORKER_CONTROL_ENDPOINT=""
AGENT_ENABLE_MANAGED_PREPARATION_AWS=""; AGENT_WORKER_AMI_PUBLICATION_FILE=""
AGENT_WORKER_AMI_PUBLICATION_SHA256=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT=$2; shift 2;;
    --bundle-output) BUNDLE_OUTPUT=$2; shift 2;;
    --domain) DOMAIN=$2; shift 2;;
    --acme) ACME=$2; shift 2;;
    --message-server-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    --as-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    --agent-image) AGENT_IMAGE=$2; shift 2;;
    --agent-instance-id) AGENT_INSTANCE_ID=$2; shift 2;;
    --agent-model-profiles-file) AGENT_MODEL_PROFILES_FILE=$2; shift 2;;
    --agent-enable-aws-control) AGENT_ENABLE_AWS_CONTROL=$2; shift 2;;
    --agent-aws-reaper-image-uri) AGENT_AWS_REAPER_IMAGE_URI=$2; shift 2;;
    --agent-worker-control-endpoint) AGENT_WORKER_CONTROL_ENDPOINT=$2; shift 2;;
    --agent-enable-managed-preparation-aws) AGENT_ENABLE_MANAGED_PREPARATION_AWS=$2; shift 2;;
    --agent-worker-ami-publication-file) AGENT_WORKER_AMI_PUBLICATION_FILE=$2; shift 2;;
    --agent-worker-ami-publication-sha256) AGENT_WORKER_AMI_PUBLICATION_SHA256=$2; shift 2;;
    --defer-compose-start) DEFER_COMPOSE_START=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$MESSAGE_SERVER_IMAGE" ] || { echo "--message-server-image required" >&2; exit 1; }
[ -n "$DOMAIN" ] || { echo "--domain required; production deployments require a real domain" >&2; exit 1; }
case "$ACME$MESSAGE_SERVER_IMAGE" in
  *$'\n'*|*$'\r'*) echo "--acme and --message-server-image must be single-line values" >&2; exit 1 ;;
esac
DOMAIN=$(domain_normalize "$DOMAIN")
[ "$DOMAIN" != "PLACEHOLDER" ] || { echo "PLACEHOLDER/sslip.io domains are not accepted in the production renderer" >&2; exit 1; }
domain_is_formal_name "$DOMAIN" || { echo "invalid production domain: $DOMAIN" >&2; exit 1; }
case "$FORMAT" in
  cloud-config|shell) [ -z "$BUNDLE_OUTPUT" ] || { echo "--bundle-output requires --format bundle" >&2; exit 1; } ;;
  bundle) [ -n "$BUNDLE_OUTPUT" ] || { echo "--format bundle requires --bundle-output" >&2; exit 1; } ;;
  *) echo "invalid --format: $FORMAT" >&2; exit 1 ;;
esac
agent_enabled=0
agent_aws_control_enabled=0
agent_aws_publication_enabled=0
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
if [ "$AGENT_ENABLE_AWS_CONTROL" = true ]; then
  [ "$agent_enabled" = 1 ] || { echo "--agent-enable-aws-control true requires Agent inputs" >&2; exit 1; }
  agent_aws_reaper_image_uri_is_safe "$AGENT_AWS_REAPER_IMAGE_URI" || { echo "--agent-aws-reaper-image-uri must be an immutable credential-free image reference with a lowercase sha256 digest" >&2; exit 1; }
  agent_worker_control_endpoint_is_safe "$AGENT_WORKER_CONTROL_ENDPOINT" || { echo "--agent-worker-control-endpoint must be a credential-free grpcs:// DNS endpoint on port 443" >&2; exit 1; }
  agent_managed_preparation_aws_is_safe "$AGENT_ENABLE_MANAGED_PREPARATION_AWS" || { echo "--agent-enable-managed-preparation-aws must be true or false" >&2; exit 1; }
  if [ "$AGENT_ENABLE_MANAGED_PREPARATION_AWS" = true ]; then
    [ -n "$AGENT_WORKER_AMI_PUBLICATION_FILE" ] || { echo "--agent-worker-ami-publication-file is required when managed preparation is enabled" >&2; exit 1; }
    printf '%s\n' "$AGENT_WORKER_AMI_PUBLICATION_SHA256" | grep -Eq '^[0-9a-f]{64}$' || { echo "--agent-worker-ami-publication-sha256 must be the frozen lowercase sha256 digest" >&2; exit 1; }
    agent_aws_publication_enabled=1
  elif [ -n "$AGENT_WORKER_AMI_PUBLICATION_FILE$AGENT_WORKER_AMI_PUBLICATION_SHA256" ]; then
    echo "Worker-AMI publication inputs require --agent-enable-managed-preparation-aws true" >&2
    exit 1
  fi
  agent_aws_control_enabled=1
elif [ "$AGENT_ENABLE_AWS_CONTROL" != false ] || [ -n "$AGENT_AWS_REAPER_IMAGE_URI$AGENT_WORKER_CONTROL_ENDPOINT$AGENT_ENABLE_MANAGED_PREPARATION_AWS$AGENT_WORKER_AMI_PUBLICATION_FILE$AGENT_WORKER_AMI_PUBLICATION_SHA256" ]; then
  echo "Agent AWS control inputs require --agent-enable-aws-control true" >&2
  exit 1
fi
# Single-line base64 compatible with GNU/Linux and macOS/BSD base64.
b64() { base64 | tr -d '\n'; }
sed_replacement_escape() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }
render_optional_agent_sections() {
  local enabled=$1 aws_control_enabled=$2 aws_publication_enabled=$3
  awk -v enabled="$enabled" -v aws_control_enabled="$aws_control_enabled" -v aws_publication_enabled="$aws_publication_enabled" '
    /DIREXTALK_AGENT_OPTIONAL_BEGIN/ { agent_skip = (enabled != 1); next }
    /DIREXTALK_AGENT_OPTIONAL_END/ { agent_skip = 0; next }
    /DIREXTALK_AGENT_AWS_CONTROL_BEGIN/ { aws_skip = (aws_control_enabled != 1); next }
    /DIREXTALK_AGENT_AWS_CONTROL_END/ { aws_skip = 0; next }
    /DIREXTALK_AGENT_AWS_PUBLICATION_BEGIN/ { publication_skip = (aws_publication_enabled != 1); next }
    /DIREXTALK_AGENT_AWS_PUBLICATION_END/ { publication_skip = 0; next }
    !agent_skip && !aws_skip && !publication_skip { print }
  ' "$CI/docker-compose.yml"
}

strip_bundle_comments() {
  # These two files have no block-scalar comments. Strip documentation-only
  # lines from the deployed copy to keep the generated bootstrap compact.
  awk 'NF && $0 !~ /^[[:space:]]*#/ { print }'
}

# Build a deterministic tar.gz bundle with fixed permissions and no extra attrs.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
render_optional_agent_sections "$agent_enabled" "$agent_aws_control_enabled" "$agent_aws_publication_enabled" \
  | sed "s#__AGENT_ENABLE_AWS_CONTROL__#$(sed_replacement_escape "$AGENT_ENABLE_AWS_CONTROL")#g; s#__AGENT_AWS_REAPER_IMAGE_URI__#$(sed_replacement_escape "$AGENT_AWS_REAPER_IMAGE_URI")#g; s#__AGENT_WORKER_CONTROL_ENDPOINT__#$(sed_replacement_escape "$AGENT_WORKER_CONTROL_ENDPOINT")#g; s#__AGENT_ENABLE_MANAGED_PREPARATION_AWS__#$(sed_replacement_escape "$AGENT_ENABLE_MANAGED_PREPARATION_AWS")#g" \
  | strip_bundle_comments > "$WORK/docker-compose.yml"
strip_bundle_comments < "$CI/Caddyfile" > "$WORK/Caddyfile"
tr -d '\r' < "$CI/init-tokens.sh" > "$WORK/init-tokens.sh"
tr -d '\r' < "$CI/p2p-http-request.sh" > "$WORK/p2p-http-request.sh"
if [ "$agent_enabled" = 1 ]; then
  tr -d '\r' < "$CI/agent-db-init.sh" > "$WORK/agent-db-init.sh"
  tr -d '\r' < "$CI/agent-runtime-init.sh" > "$WORK/agent-runtime-init.sh"
  cp "$AGENT_MODEL_PROFILES_FILE" "$WORK/agent-model-profiles.json"
  if [ "$agent_aws_publication_enabled" = 1 ]; then
    json_worker_ami_publication_snapshot "$AGENT_WORKER_AMI_PUBLICATION_FILE" "$WORK/agent-worker-ami-publication.json" "$AGENT_WORKER_AMI_PUBLICATION_SHA256" >/dev/null || {
      echo "--agent-worker-ami-publication-file must be the exact strict Agent Worker-AMI publication matching the frozen digest" >&2
      exit 1
    }
  fi
fi
mkdir -p "$WORK/updater"
for updater_file in install.sh bootstrap-host.sh set-desired-state.sh release.env config.json config.legacy-compose-caddy.json dirextalk-updater.service; do
  tr -d '\r' < "$HERE/updater/$updater_file" > "$WORK/updater/$updater_file"
done
if [ "$agent_enabled" = 1 ]; then
  tr -d '\r' < "$HERE/updater/reconcile-agent-aws-control.sh" > "$WORK/updater/reconcile-agent-aws-control.sh"
fi
chmod 0644 "$WORK/docker-compose.yml" "$WORK/Caddyfile"
if [ "$agent_enabled" = 1 ]; then
  chmod 0644 "$WORK/agent-model-profiles.json"
  [ "$agent_aws_publication_enabled" = 1 ] && chmod 0644 "$WORK/agent-worker-ami-publication.json"
  chmod 0755 "$WORK/agent-db-init.sh" "$WORK/agent-runtime-init.sh"
fi
chmod 0644 "$WORK/updater/release.env" "$WORK/updater/config.json" "$WORK/updater/config.legacy-compose-caddy.json" "$WORK/updater/"*.service
chmod 0755 "$WORK/init-tokens.sh" "$WORK/p2p-http-request.sh" "$WORK/updater/install.sh" "$WORK/updater/bootstrap-host.sh" "$WORK/updater/set-desired-state.sh"
[ "$agent_enabled" = 1 ] && chmod 0755 "$WORK/updater/reconcile-agent-aws-control.sh"
find "$WORK" -name '._*' -delete
bundle_files=(docker-compose.yml Caddyfile init-tokens.sh p2p-http-request.sh updater)
if [ "$agent_enabled" = 1 ]; then
  bundle_files+=(agent-db-init.sh agent-runtime-init.sh agent-model-profiles.json)
  [ "$agent_aws_publication_enabled" = 1 ] && bundle_files+=(agent-worker-ami-publication.json)
fi
# The shell renderer is a self-contained bootstrap payload. Lightsail streams
# it over SSH; EC2 embeds the same bundle in cloud-init below. The helper emits
# a normalized USTAR+gzip archive (fixed order, ownership, modes, and times).
BUNDLE_ARCHIVE="$WORK/bundle.tar.gz"
[ "$FORMAT" = bundle ] && BUNDLE_ARCHIVE=$BUNDLE_OUTPUT
json_deterministic_bundle "$WORK" "$BUNDLE_ARCHIVE" "${bundle_files[@]}"
[ "$FORMAT" = bundle ] && exit 0
BUNDLE_B64=$(b64 < "$BUNDLE_ARCHIVE")

if [ "$FORMAT" = "shell" ]; then
  bootstrap_prefix=
  [ "$DEFER_COMPOSE_START" = 1 ] && bootstrap_prefix='DIREXTALK_BOOTSTRAP_DEFER_START=1 '
  cat <<EOF
#!/bin/bash
set -eu
mkdir -p /run/lock
exec 8>/run/lock/dirextalk-rendered-bootstrap.lock
flock 8
d=/var/dirextalk-message-server;mkdir -p "\$d";cd "\$d"
if [ ! -f .env ]; then
(umask 077
cat > .env.tmp <<'E'
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME
MESSAGE_SERVER_IMAGE=$MESSAGE_SERVER_IMAGE
AGENT_IMAGE=$AGENT_IMAGE
AGENT_INSTANCE_ID=$AGENT_INSTANCE_ID
E
mv -f .env.tmp .env)
fi
base64 -d>bundle.tar.gz<<B
$BUNDLE_B64
B
tar xzf bundle.tar.gz
type docker>&/dev/null||curl -fsSL https://get.docker.com|sh
systemctl enable --now docker
${bootstrap_prefix}updater/bootstrap-host.sh "\${1:-}"
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
