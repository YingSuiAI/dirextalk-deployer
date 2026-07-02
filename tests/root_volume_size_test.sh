#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXIO_WORKDIR="$tmp/work"
mkdir -p "$HOME" "$DIREXIO_WORKDIR"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1

# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

_root_block_device_mappings > "$tmp/root-volume.json"

json_test_check "$tmp/root-volume.json" "Array.isArray(data) && data[0].DeviceName === '/dev/sda1' && data[0].Ebs.VolumeSize === 50 && data[0].Ebs.VolumeType === 'gp3' && data[0].Ebs.DeleteOnTermination === true"
grep -q -- '--block-device-mappings "$(_root_block_device_mappings)"' "$ROOT/scripts/phases/s3_provision.sh"

echo "root volume size ok"
