#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
pin="$ROOT/scripts/updater/release.env"
lib="$ROOT/scripts/lib/updater-release.sh"
[ -f "$pin" ] || { echo "missing pinned updater release metadata" >&2; exit 1; }
[ -f "$lib" ] || { echo "missing pinned updater release helper" >&2; exit 1; }

export UPDATER_PIN_VERSION=attacker UPDATER_PIN_COMMIT=attacker UPDATER_PIN_SHA256=attacker
# shellcheck disable=SC1090
source "$lib"
updater_release_validate_pin

[ "$UPDATER_PIN_VERSION" = v1.0.4 ]
[ "$UPDATER_PIN_COMMIT" = 42f334642aacf5bf9977ece2a961668c373a1c63 ]
[ "$UPDATER_PIN_URL" = https://github.com/YingSuiAI/dirextalk-updater/releases/download/v1.0.4/dirextalk-updater-linux-amd64 ]
[ "$UPDATER_PIN_ASSET" = dirextalk-updater-linux-amd64 ]
[ "$UPDATER_PIN_SHA256" = 3715ad2b4b6fbb8ac15cc941c5a91ebc61b169d1a33ed6829e105288657acec9 ]
[ "$UPDATER_PIN_OS" = linux ]
[ "$UPDATER_PIN_ARCH" = amd64 ]
[ "$UPDATER_PIN_UBUNTU_VERSION" = 24.04 ]
if grep -qi 'latest' "$pin"; then
  echo "pinned updater metadata must never reference latest" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DIREXTALK_WORKDIR="$tmp/work" RUN_ID=updater-pin-test
mkdir -p "$DIREXTALK_WORKDIR"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
updater_release_record_state
[ "$(json_get "$STATE_JSON" updater_release.version)" = v1.0.4 ]
[ "$(json_get "$STATE_JSON" updater_release.commit)" = 42f334642aacf5bf9977ece2a961668c373a1c63 ]
[ "$(json_get "$STATE_JSON" updater_release.sha256)" = 3715ad2b4b6fbb8ac15cc941c5a91ebc61b169d1a33ed6829e105288657acec9 ]

echo "updater release pin ok"
