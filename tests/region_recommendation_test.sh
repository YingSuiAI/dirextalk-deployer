#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/region.sh"

row=$(TZ=Asia/Shanghai direxio_recommend_region)
IFS=$'\t' read -r region timezone offset reason <<EOF
$row
EOF

[ "$region" = "ap-east-1" ] || {
  echo "expected Asia/Shanghai to recommend ap-east-1, got $region" >&2
  exit 1
}
[ "$timezone" = "Asia/Shanghai" ] || {
  echo "expected timezone to be recorded, got $timezone" >&2
  exit 1
}
case "$reason" in
  *"Asia Pacific (Hong Kong)"*) ;;
  *)
    echo "expected reason to mention Hong Kong, got $reason" >&2
    exit 1
    ;;
esac

echo "region recommendation ok"
