#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
caddy_source=$ROOT/scripts/cloud-init/split/Caddyfile
bundle=$ROOT/scripts/cloud-init/split/canonical-bundle.tar.gz
tmp=$(mktemp -d)
container=
cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

site_id=9775c8e4-6016-54e2-9fc3-f907e1271d46
release_id=9e139e84-425a-5c3f-8a2c-45d568ea5f06
public_path="/.sites/$site_id/$release_id/"
public_root=$tmp/static-sites/public
mkdir -p "$public_root/$site_id/$release_id"
printf '%s\n' '<!doctype html><title>Dirextalk edge fixture</title>' \
  >"$public_root/$site_id/$release_id/index.html"

route_line=$(grep -nF 'handle_path /.sites/* {' "$caddy_source" | cut -d: -f1)
fallback_line=$(grep -nF $'\thandle {' "$caddy_source" | tail -n1 | cut -d: -f1)
[ -n "$route_line" ] && [ -n "$fallback_line" ] && [ "$route_line" -lt "$fallback_line" ] || {
  echo 'production Caddy does not reserve /.sites/* before the Message Server fallback' >&2
  exit 1
}
grep -Fq $'\t\troot * /srv/dirextalk-sites' "$caddy_source"
grep -Fq $'\t\tfile_server' "$caddy_source"
grep -Fq "Content-Security-Policy \"sandbox; default-src 'none';" "$caddy_source"

edge_compose=$tmp/edge-compose.yaml
tar -xOzf "$bundle" deploy/split-agent/edge-compose.yaml >"$edge_compose"
grep -Fq 'source: ${DIREXTALK_STATIC_SITES_ROOT:?set the Agent-owned static-site host root}/public' "$edge_compose"
grep -Fq 'target: /srv/dirextalk-sites' "$edge_compose"
grep -A4 -F 'target: /srv/dirextalk-sites' "$edge_compose" | grep -Fq 'read_only: true'

image=${DIREXTALK_TEST_CADDY_IMAGE:-}
if [ -z "$image" ]; then
  echo "static sites edge config ok (set DIREXTALK_TEST_CADDY_IMAGE to run the real Caddy mapping)"
  exit 0
fi
printf '%s\n' "$image" | grep -Eq '@sha256:[0-9a-f]{64}$' || {
  echo 'DIREXTALK_TEST_CADDY_IMAGE must be immutable' >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  echo 'Docker is required for the requested real Caddy mapping test' >&2
  exit 1
}
docker image inspect "$image" >/dev/null 2>&1 || {
  echo 'the requested immutable Caddy image is not available locally' >&2
  exit 1
}

rendered=$tmp/Caddyfile
sed 's#__DIREXTALK_PUBLIC_DOMAIN__#http://:8080#g' "$caddy_source" >"$rendered"
container=dirextalk-static-sites-edge-test-$$
docker run -d --name "$container" --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true --tmpfs /tmp --tmpfs /data --tmpfs /config \
  --expose 8080 -p 127.0.0.1::8080 \
  --mount "type=bind,src=$rendered,dst=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,src=$public_root,dst=/srv/dirextalk-sites,readonly" \
  "$image" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

if [ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]; then
  docker logs "$container" >&2 || true
  echo 'real Caddy mapping container did not remain running' >&2
  exit 1
fi

address=$(docker port "$container" 8080/tcp | head -n1)
base_url=http://$address
body=$tmp/body
headers=$tmp/headers
status=
for _ in $(seq 1 100); do
  status=$(curl --silent --show-error --output "$body" --dump-header "$headers" \
    --write-out '%{http_code}' "$base_url$public_path" || true)
  [ "$status" = 200 ] && break
  sleep 0.1
done
[ "$status" = 200 ] || {
  docker logs "$container" >&2 || true
  echo "published static-site URL returned HTTP ${status:-unavailable}" >&2
  exit 1
}
cmp "$public_root/$site_id/$release_id/index.html" "$body"
grep -Eiq '^Content-Security-Policy: sandbox;.*script-src '\''none'\'';.*connect-src '\''none'\''' "$headers"
grep -Eiq '^Cache-Control: public, max-age=31536000, immutable' "$headers"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/srv/dirextalk-sites"}}{{.RW}}{{end}}{{end}}' "$container")" = false ]

echo "static sites edge mapping ok: $public_path"
