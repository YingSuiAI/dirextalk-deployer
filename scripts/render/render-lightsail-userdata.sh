#!/usr/bin/env bash
# render-lightsail-userdata.sh - render shell user-data for Lightsail.
#
# Lightsail runs user-data as a shell script on Ubuntu blueprints, so do not
# send EC2 cloud-config YAML here. The script embeds the same deployment bundle
# as render-userdata.sh and performs the remote bootstrap directly.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CI="$HERE/cloud-init"
source "$HERE/lib/domain.sh"

DOMAIN=""; ACME=""; MESSAGE_SERVER_IMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=$2; shift 2;;
    --acme) ACME=$2; shift 2;;
    --message-server-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    --as-image) MESSAGE_SERVER_IMAGE=$2; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$MESSAGE_SERVER_IMAGE" ] || { echo "--message-server-image required" >&2; exit 1; }
[ -n "$DOMAIN" ] || { echo "--domain required; production deployments require a real domain" >&2; exit 1; }
DOMAIN=$(domain_normalize "$DOMAIN")
[ "$DOMAIN" != "PLACEHOLDER" ] || { echo "PLACEHOLDER/sslip.io domains are not accepted in the production renderer" >&2; exit 1; }
domain_is_formal_name "$DOMAIN" || { echo "invalid production domain: $DOMAIN" >&2; exit 1; }

b64() { base64 | tr -d '\n'; }
sed_replacement_escape() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$CI/docker-compose.yml" "$WORK/docker-compose.yml"
cp "$CI/Caddyfile"          "$WORK/Caddyfile"
tr -d '\r' < "$CI/init-tokens.sh" > "$WORK/init-tokens.sh"
chmod 0644 "$WORK/docker-compose.yml" "$WORK/Caddyfile"
chmod 0755 "$WORK/init-tokens.sh"
find "$WORK" -name '._*' -delete
BUNDLE_B64=$(COPYFILE_DISABLE=1 tar -C "$WORK" -cf - docker-compose.yml Caddyfile init-tokens.sh | gzip -n | b64)

cat <<'EOF' \
| sed "s#__DOMAIN__#$(sed_replacement_escape "$DOMAIN")#g; s#__ACME_EMAIL__#$(sed_replacement_escape "$ACME")#g; s#__MESSAGE_SERVER_IMAGE__#$(sed_replacement_escape "$MESSAGE_SERVER_IMAGE")#g" \
| awk -v bundle="$BUNDLE_B64" '
  $0 == "__DIREXIO_BUNDLE_B64__" { print bundle; next }
  { print }
'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
deploy_dir=/var/direxio-message-server

install -d -m 0700 "$deploy_dir"
install -d -m 0700 "$deploy_dir/p2p"

cat > "$deploy_dir/.env" <<'DIREXIO_ENV'
DOMAIN=__DOMAIN__
ACME_EMAIL=__ACME_EMAIL__
MESSAGE_SERVER_IMAGE=__MESSAGE_SERVER_IMAGE__
DIREXIO_ENV
chmod 0600 "$deploy_dir/.env"

cat > "$deploy_dir/bundle.tar.gz.b64" <<'DIREXIO_BUNDLE'
__DIREXIO_BUNDLE_B64__
DIREXIO_BUNDLE
base64 -d "$deploy_dir/bundle.tar.gz.b64" > "$deploy_dir/bundle.tar.gz"
tar -xzf "$deploy_dir/bundle.tar.gz" -C "$deploy_dir"
chmod 0755 "$deploy_dir/init-tokens.sh"

token=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
public_ip=""
if [ -n "$token" ]; then
  public_ip=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
fi
if [ -z "$public_ip" ]; then
  public_ip=$(curl -fsS https://api.ipify.org 2>/dev/null || curl -fsS https://ifconfig.me 2>/dev/null || true)
fi
if [ -n "$public_ip" ] && ! grep -q '^PUBLIC_IP=' "$deploy_dir/.env"; then
  echo "PUBLIC_IP=$public_ip" >> "$deploy_dir/.env"
fi
grep -q '^TURN_SECRET=' "$deploy_dir/.env" || \
  echo "TURN_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)" >> "$deploy_dir/.env"
grep -q '^P2P_PORTAL_PASSWORD=' "$deploy_dir/.env" || \
  echo "P2P_PORTAL_PASSWORD=$(od -An -N4 -tu4 /dev/urandom | awk '{printf "%08d", $1 % 100000000}')" >> "$deploy_dir/.env"

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

cd "$deploy_dir"
docker compose --env-file .env up -d
DOMAIN=$(grep '^DOMAIN=' .env | cut -d= -f2) bash init-tokens.sh
touch "$deploy_dir/.deploy-done"
EOF
