#!/usr/bin/env bash
# Safely identify and adopt the one approved pre-updater message-server layout.
set -euo pipefail

action=${1:-}
source_dir=${2:-}
template_dir=${3:-}
root=${DIREXTALK_LEGACY_ADOPT_ROOT:-}
fixed_version=v0.15.2
fixed_digest=sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c
fixed_image="dirextalk/message-server:$fixed_version@$fixed_digest"

case "$source_dir" in
  /root/dirextalk/dirextalk-message-server) compose_name=docker-compose.p2p.yml ;;
  *) echo "unsupported legacy source layout" >&2; exit 1 ;;
esac
case "$action" in
  probe|commit) ;;
  *) echo "usage: adopt-legacy-host.sh <probe|commit> </approved/source/dir>" >&2; exit 2 ;;
esac

physical_source="$root$source_dir"
compose_file="$physical_source/$compose_name"
[ -d "$template_dir" ] \
  && [ -f "$template_dir/legacy-d1-compose.p2p.yml" ] \
  && [ -f "$template_dir/legacy-adopt-compose.yml" ] || {
  echo "legacy adoption templates are incomplete" >&2
  exit 1
}
[ -d "$physical_source" ] && [ -f "$compose_file" ] && [ -f "$physical_source/.env" ] || {
  echo "legacy Compose layout is incomplete" >&2
  exit 1
}
cmp -s "$compose_file" "$template_dir/legacy-d1-compose.p2p.yml" || {
  echo "legacy Compose layout is not the approved d1 source revision" >&2
  exit 1
}

containers=$(docker ps -aq \
  --filter label=com.docker.compose.project=dirextalk-p2p \
  --filter label=com.docker.compose.service=message-server)
[ "$(printf '%s\n' "$containers" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] || {
  echo "expected exactly one dirextalk-p2p message-server container" >&2
  exit 1
}
container=$(printf '%s\n' "$containers" | sed -n '1p')
[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
  echo "legacy message-server is not running" >&2
  exit 1
}
[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")" = healthy ] || {
  echo "legacy message-server is not Docker-healthy" >&2
  exit 1
}

configured_image=$(docker inspect --format '{{.Config.Image}}' "$container")
case "$configured_image" in
  dirextalk/message-server:latest|dirextalk/message-server:v0.15.2|"$fixed_image") ;;
  *) echo "legacy container uses an unapproved image repository or tag" >&2; exit 1 ;;
esac
image_id=$(docker inspect --format '{{.Image}}' "$container")
docker image inspect --format '{{join .RepoDigests "\n"}}' "$image_id" \
  | grep -F -x -q "dirextalk/message-server@$fixed_digest" || {
    echo "legacy container image digest is not approved" >&2
    exit 1
  }

health_json=$(docker exec "$container" wget -q -O- http://127.0.0.1:8008/_p2p/health)
printf '%s' "$health_json" | python3 -c \
  'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if value == {"status":"ok"} else 1)' || {
  echo "legacy runtime health payload is not the approved minimal response" >&2
  exit 1
}
runtime_version=$(docker exec "$container" /usr/bin/dirextalk-message-server --version 2>&1 | sed -n '1p')
case "$runtime_version" in 0.15.2|v0.15.2) ;; *) echo "legacy runtime binary is not v0.15.2" >&2; exit 1 ;; esac

[ "$(systemctl is-active caddy.service)" = active ] \
  && [ "$(systemctl show -p User --value caddy.service)" = caddy ] \
  && getent group caddy >/dev/null || {
  echo "legacy host Caddy service/user/group contract is not satisfied" >&2
  exit 1
}
caddyfile="$root/etc/caddy/Caddyfile"
[ -x "$root/usr/bin/caddy" ] || [ -x /usr/bin/caddy ] || {
  echo "legacy host Caddy binary is missing" >&2
  exit 1
}
[ -f "$caddyfile" ] || { echo "legacy host Caddyfile is missing" >&2; exit 1; }
[ "$(grep -F -c 'reverse_proxy 127.0.0.1:8008' "$caddyfile")" = 1 ] || {
  echo "legacy host Caddyfile must contain one message-server proxy" >&2
  exit 1
}
if grep -F -q '/_dirextalk/updater/v1/control' "$caddyfile"; then
  echo "legacy host Caddyfile exposes a forbidden updater control route" >&2
  exit 1
fi
jobs_routes=$(grep -F -c 'handle /_dirextalk/updater/v1/jobs/* {' "$caddyfile" || true)
[ "$jobs_routes" -le 1 ] || { echo "legacy host Caddyfile has duplicate updater jobs routes" >&2; exit 1; }
if [ "$jobs_routes" -eq 1 ]; then
  [ "$(grep -F -c 'reverse_proxy unix//run/dirextalk-updater/http.sock' "$caddyfile")" = 1 ] || {
    echo "legacy host Caddyfile has an invalid updater jobs upstream" >&2
    exit 1
  }
fi
caddy_backup="$caddyfile.dirextalk-legacy-adopt.bak"
dropin_dir="$root/etc/systemd/system/dirextalk-updater.service.d"
dropin="$dropin_dir/legacy-systemd-caddy.conf"
if [ "$jobs_routes" -eq 0 ] && [ -e "$caddy_backup" ]; then
  echo "legacy Caddy backup exists without the adopted jobs route" >&2
  exit 1
fi
if [ "$jobs_routes" -eq 1 ] && [ ! -f "$caddy_backup" ]; then
  echo "adopted Caddy route is missing its single rollback backup" >&2
  exit 1
fi
if [ -f "$dropin" ] && ! grep -F -q 'chgrp caddy /run/dirextalk-updater/http.sock' "$dropin"; then
  echo "existing updater systemd drop-in is not the approved host-Caddy contract" >&2
  exit 1
fi

if [ "$action" = probe ]; then
  printf 'legacy_adoptable\t%s\t%s\t%s\t%s\tsystemd_caddy\n' \
    "$fixed_version" "$fixed_image" "$source_dir" "$compose_name"
  exit 0
fi

if [ "$(id -u)" -ne 0 ] && ! {
  [ -n "$root" ] && [ "${DIREXTALK_LEGACY_ADOPT_ALLOW_NON_ROOT_TEST:-0}" = 1 ]
}; then
  echo "legacy host adoption requires root" >&2
  exit 1
fi

target="$root/var/dirextalk-message-server"
target_created=0
if [ ! -d "$target" ]; then
  install -d -m 0700 "$root/var"
  stage=$(mktemp -d "$root/var/.dirextalk-message-server.adopt.XXXXXX")
  cleanup_stage() { rm -rf "$stage"; }
  trap cleanup_stage EXIT
  install -m 0600 "$physical_source/.env" "$stage/.env.source"
  awk '$0 !~ /^MESSAGE_SERVER_IMAGE=/' "$stage/.env.source" > "$stage/.env"
  printf 'MESSAGE_SERVER_IMAGE=%s\n' "$fixed_image" >> "$stage/.env"
  chmod 0600 "$stage/.env"
  rm -f "$stage/.env.source"
  install -m 0600 "$template_dir/legacy-adopt-compose.yml" "$stage/docker-compose.yml"
  install -d -m 0700 "$stage/p2p"
  docker cp "$container:/var/dirextalk-message-server/p2p/." "$stage/p2p"
  [ -s "$stage/p2p/bootstrap.json" ] || {
    echo "legacy p2p state could not be copied from the running container" >&2
    exit 1
  }
  find "$stage/p2p" -type d -exec chmod 0700 {} +
  find "$stage/p2p" -type f -exec chmod 0600 {} +
  MESSAGE_SERVER_IMAGE="$fixed_image" docker compose \
    --project-name dirextalk-p2p --env-file "$stage/.env" \
    --file "$stage/docker-compose.yml" config >/dev/null
  mv "$stage" "$target"
  target_created=1
  trap - EXIT
else
  cmp -s "$target/docker-compose.yml" "$template_dir/legacy-adopt-compose.yml" \
    && [ "$(grep -F -c "MESSAGE_SERVER_IMAGE=$fixed_image" "$target/.env" 2>/dev/null || true)" = 1 ] \
    && [ -s "$target/p2p/bootstrap.json" ] || {
    echo "existing updater layout does not match the completed legacy adoption" >&2
    exit 1
  }
fi

caddy_tmp=$(mktemp "$root/etc/caddy/.Caddyfile.adopt.XXXXXX")
caddy_changed=0
dropin_created=0
cleanup_commit() { rm -f "$caddy_tmp"; }
trap cleanup_commit EXIT

if ! grep -F -q 'handle /_dirextalk/updater/v1/jobs/* {' "$caddyfile"; then
  install -m 0644 "$caddyfile" "$caddy_backup"
  if ! python3 - "$caddyfile" "$caddy_tmp" <<'PY'
import pathlib, sys
source, destination = map(pathlib.Path, sys.argv[1:])
lines = source.read_text(encoding="utf-8").splitlines(keepends=True)
proxy = [i for i, line in enumerate(lines) if line.strip() == "reverse_proxy 127.0.0.1:8008"]
if len(proxy) != 1:
    raise SystemExit("expected one legacy message proxy")
index = proxy[0]
start = next((i for i in range(index, -1, -1) if lines[i] and not lines[i][0].isspace() and lines[i].rstrip().endswith("{")), None)
end = next((i for i in range(index + 1, len(lines)) if lines[i].strip() == "}" and lines[i].startswith("}")), None)
if start is None or end is None:
    raise SystemExit("could not isolate legacy Caddy site block")
catch_all = next((i for i in range(start + 1, end) if lines[i].strip() == "handle {"), None)
if catch_all is None:
    raise SystemExit("legacy Caddy site has no catch-all handle")
route = [
    "\thandle /_dirextalk/updater/v1/jobs/* {\n",
    "\t\treverse_proxy unix//run/dirextalk-updater/http.sock\n",
    "\t}\n",
    "\n",
]
destination.write_text("".join(lines[:catch_all] + route + lines[catch_all:]), encoding="utf-8")
PY
  then
    rm -f "$caddy_backup"
    [ "$target_created" -eq 0 ] || rm -rf "$target"
    echo "legacy Caddy site could not be patched safely" >&2
    exit 1
  fi
  chmod 0644 "$caddy_tmp"
  mv "$caddy_tmp" "$caddyfile"
  caddy_changed=1
fi

install -d -m 0755 "$dropin_dir"
if [ ! -f "$dropin" ]; then
  cat > "$dropin" <<'EOF'
[Service]
ExecStartPost=/usr/bin/timeout 10 /bin/sh -c 'until [ -S /run/dirextalk-updater/http.sock ]; do sleep 0.1; done; /usr/bin/chgrp caddy /run/dirextalk-updater/http.sock; /usr/bin/chmod 0660 /run/dirextalk-updater/http.sock'
EOF
  chmod 0644 "$dropin"
  dropin_created=1
fi

restore_caddy_transaction() {
  if [ "$caddy_changed" -eq 1 ]; then
    restore_tmp=$(mktemp "$root/etc/caddy/.Caddyfile.restore.XXXXXX")
    install -m 0644 "$caddy_backup" "$restore_tmp"
    mv "$restore_tmp" "$caddyfile"
    rm -f "$caddy_backup"
  fi
  [ "$dropin_created" -eq 0 ] || rm -f "$dropin"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reload caddy.service >/dev/null 2>&1 || true
  [ "$target_created" -eq 0 ] || rm -rf "$target"
}

if ! systemctl daemon-reload; then
  restore_caddy_transaction
  echo "adopted updater systemd configuration did not reload; original restored" >&2
  exit 1
fi
caddy_binary=/usr/bin/caddy
[ -x "$root/usr/bin/caddy" ] && caddy_binary="$root/usr/bin/caddy"
if ! "$caddy_binary" validate --config "$caddyfile" >/dev/null 2>&1; then
  restore_caddy_transaction
  echo "adopted Caddy configuration did not validate; original restored" >&2
  exit 1
fi
if ! systemctl reload caddy.service; then
  restore_caddy_transaction
  echo "adopted Caddy configuration did not reload; original restored" >&2
  exit 1
fi

printf '%s\t%s\t%s\n' "$fixed_version" "$fixed_image" systemd_caddy > "$target/.legacy-adopted"
chmod 0600 "$target/.legacy-adopted"
trap - EXIT
printf 'legacy_adopted\t%s\t%s\t%s\n' "$fixed_version" "$fixed_image" systemd_caddy
