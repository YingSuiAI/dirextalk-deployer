#!/usr/bin/env bash
# Prove the immutable official HAProxy image and rendered TCP/SNI config.
set -euo pipefail

image=${1:-}
config=${2:-}
die() { printf 'verify worker edge image: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 2 ] || die 'usage: verify-worker-edge-image.sh HAPROXY_IMAGE@sha256:DIGEST CONFIG'
printf '%s\n' "$image" | grep -Eq '^docker\.io/library/haproxy:[^[:space:]@]*alpine@sha256:[0-9a-f]{64}$' \
  || die 'image must be an immutable official HAProxy Alpine digest reference'
[ -f "$config" ] && [ ! -L "$config" ] || die 'rendered HAProxy config must be a regular file'
command -v docker >/dev/null 2>&1 || die 'docker is required'
docker image inspect "$image" >/dev/null 2>&1 || die 'immutable image is not present locally; pull it through the reviewed release path first'

docker run --rm --network none --read-only --cap-drop ALL \
  --entrypoint haproxy "$image" -vv >/dev/null \
  || die 'could not execute HAProxy from the immutable image'
docker run --rm --network none --read-only --cap-drop ALL \
  -v "$config:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  --entrypoint haproxy "$image" -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null \
  || die 'immutable HAProxy image rejected the rendered config'
printf 'worker edge image verified: image=%s\n' "$image"
