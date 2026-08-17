#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

message='docker.io/dirextalk/message-server:v1.1.32'
agent='docker.io/dirextalk/agent:v1.0.69'
postgres='docker.io/pgvector/pgvector:pg18@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
caddy='docker.io/library/caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
coturn='docker.io/coturn/coturn:4.6.3-alpine@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
message_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
split_revision=cccccccccccccccccccccccccccccccccccccccc
agent_revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
common=(
  --domain service.example.test
  --acme ops@example.test
  --message-server-image "$message"
  --agent-image "$agent"
  --postgres-image "$postgres"
  --caddy-image "$caddy"
  --coturn-image "$coturn"
  --message-version v1.1.32
  --agent-version v1.0.69
  --message-source-revision "$message_revision"
  --split-source-revision "$split_revision"
  --agent-source-revision "$agent_revision"
  --release-catalog-origin https://imadmin.dirextalk.ai
)

bash "$ROOT/scripts/render/render-userdata.sh" "${common[@]}" >"$tmp/user-data.yaml"
bash "$ROOT/scripts/render/render-userdata.sh" --format shell "${common[@]}" >"$tmp/user-data.sh"

grep -q '^#cloud-config' "$tmp/user-data.yaml"
grep -q '^#!/bin/sh$' "$tmp/user-data.sh"
grep -q "^exec /usr/bin/env bash <<'DIREXTALK_BOOTSTRAP_BASH'$" "$tmp/user-data.sh"
grep -q '^DIREXTALK_BOOTSTRAP_BASH$' "$tmp/user-data.sh"
grep -Fq 'chown 0:0 /var/dirextalk-message-server/.env' "$tmp/user-data.sh"
grep -Fq 'chmod 0600 /var/dirextalk-message-server/.env' "$tmp/user-data.sh"
dash -n "$tmp/user-data.sh"
sed -n "/^exec \/usr\/bin\/env bash <<'DIREXTALK_BOOTSTRAP_BASH'$/,/^DIREXTALK_BOOTSTRAP_BASH$/p" "$tmp/user-data.sh" \
  | sed '1d;$d' | bash -n

for rendered in "$tmp/user-data.yaml" "$tmp/user-data.sh"; do
  grep -Fq "MESSAGE_SERVER_IMAGE=$message" "$rendered"
  grep -Fq "AGENT_IMAGE=$agent" "$rendered"
  grep -Fq "POSTGRES_IMAGE=$postgres" "$rendered"
  grep -Fq "CADDY_IMAGE=$caddy" "$rendered"
  grep -Fq "COTURN_IMAGE=$coturn" "$rendered"
  grep -Fq 'MESSAGE_VERSION=v1.1.32' "$rendered"
  grep -Fq 'AGENT_VERSION=v1.0.69' "$rendered"
  grep -Fq "MESSAGE_SOURCE_REVISION=$message_revision" "$rendered"
  grep -Fq "SPLIT_SOURCE_REVISION=$split_revision" "$rendered"
  grep -Fq "AGENT_SOURCE_REVISION=$agent_revision" "$rendered"
  grep -Fq 'DIREXTALK_RELEASE_CATALOG_ORIGIN=https://imadmin.dirextalk.ai' "$rendered"
  if grep -Eq 'docker-compose\.yml|compose\.local\.yaml|caddy:2|P2P_PORTAL_PASSWORD=' "$rendered"; then
    echo "user-data retained the removed standard/mutable runtime" >&2
    exit 1
  fi
done

awk '/encoding: b64/ { getline; sub(/^    content: /, ""); print; exit }' "$tmp/user-data.yaml" \
  | base64 -d >"$tmp/bundle.tar.gz"
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"
for file in updater/install.sh updater/bootstrap-host.sh updater/set-desired-state.sh \
  updater/release.env updater/config.json updater/dirextalk-updater.service; do
  [ -f "$tmp/bundle/$file" ] || { echo "missing minimal updater bootstrap file: $file" >&2; exit 1; }
done
python3 - "$tmp/bundle/updater/config.json" <<'PY'
import json
import pathlib
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if config.get("watchdog_enabled") is not False:
    raise SystemExit("fresh user-data must install the updater with its resident watchdog disabled")
PY
if find "$tmp/bundle" -maxdepth 1 -type f | grep -q .; then
  echo "user-data bundle must contain only the updater directory" >&2
  exit 1
fi
[ "$(wc -c <"$tmp/user-data.yaml")" -lt 16384 ]

if bash "$ROOT/scripts/render/render-userdata.sh" \
  --domain service.example.test \
  --message-server-image dirextalk/message-server:v1.2.3 \
  --agent-image "$agent" \
  --postgres-image "$postgres" \
  --caddy-image "$caddy" \
  --coturn-image "$coturn" \
  --message-version v1.1.32 \
  --agent-version v1.0.69 \
  --message-source-revision "$message_revision" \
  --split-source-revision "$split_revision" \
  --agent-source-revision "$agent_revision" \
  --release-catalog-origin https://imadmin.dirextalk.ai >/dev/null 2>&1; then
  echo "split renderer accepted a message-server image that differs from its version" >&2
  exit 1
fi

if bash "$ROOT/scripts/render/render-userdata.sh" \
  "${common[@]}" \
  --release-catalog-origin https://example.invalid >/dev/null 2>&1; then
  echo "split renderer accepted an arbitrary release catalog origin" >&2
  exit 1
fi

echo "minimal POSIX split user-data test passed"
