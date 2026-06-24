#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"
unset P2P_WORKDIR

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"

[ "$P2P_WORKDIR" = "$HOME/.direxio/deploy" ]
[ "$STATE_JSON" = "$HOME/.direxio/deploy/state.json" ]

echo "default paths ok"
