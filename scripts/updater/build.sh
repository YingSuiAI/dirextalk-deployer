#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
output=""
arch=amd64
target_os=linux
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    --os) target_os=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$output" ] || { echo "--output required" >&2; exit 1; }
case "$arch" in amd64|arm64) ;; *) echo "unsupported updater architecture: $arch" >&2; exit 1 ;; esac
case "$target_os" in linux|windows|darwin) ;; *) echo "unsupported updater operating system: $target_os" >&2; exit 1 ;; esac
command -v go >/dev/null 2>&1 || { echo "Go is required to build the updater binary" >&2; exit 1; }
mkdir -p "$(dirname "$output")"
(
  cd "$ROOT/updater"
  CGO_ENABLED=0 GOOS="$target_os" GOARCH="$arch" go build -trimpath -o "$output" ./cmd/dirextalk-updater
)
chmod 0755 "$output"
