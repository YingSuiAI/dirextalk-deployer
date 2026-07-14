#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"

"$(json_node)" tests/connection_stack_v2_contract_test.mjs
"$(json_node)" tests/connection_stack_v2_dynamo_store_test.mjs
"$(json_node)" tests/connection_stack_v2_quote_provider_test.mjs
"$(json_node)" tests/connection_stack_v2_handler_test.mjs
"$(json_node)" tests/connection_stack_v2_template_test.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/command-contract.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/worker-contract.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/dynamo-receipt-store.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/errors.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/quote-contract.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/quote-provider.mjs
"$(json_node)" --check scripts/connection-stack-v2/src/handler.mjs
