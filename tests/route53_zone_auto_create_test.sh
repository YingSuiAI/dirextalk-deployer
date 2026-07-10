#!/usr/bin/env bash
set -euo pipefail

# Kept as a compatibility entrypoint for older local test commands. The current
# contract requires a pre-existing public hosted zone and never creates one.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$ROOT/tests/route53_zone_required_test.sh"
