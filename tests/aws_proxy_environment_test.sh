#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

export AWS_DEFAULT_REGION=ap-northeast-2
export HTTP_PROXY=http://127.0.0.1:7897
export HTTPS_PROXY=http://127.0.0.1:7897
export http_proxy=http://127.0.0.1:7897
export https_proxy=http://127.0.0.1:7897
export NO_PROXY=localhost,127.0.0.1,::1
export no_proxy=localhost,127.0.0.1,::1

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/aws.sh"
aws_env_prep

[ "$HTTP_PROXY" = "http://127.0.0.1:7897" ]
[ "$HTTPS_PROXY" = "http://127.0.0.1:7897" ]
[ "$http_proxy" = "http://127.0.0.1:7897" ]
[ "$https_proxy" = "http://127.0.0.1:7897" ]
[ "$NO_PROXY" = "localhost,127.0.0.1,::1" ]
[ "$no_proxy" = "localhost,127.0.0.1,::1" ]

echo "aws proxy environment ok"
