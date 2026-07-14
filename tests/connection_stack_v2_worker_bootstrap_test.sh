#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/json.sh"

# This is the Worker-bootstrap lane. It deliberately exercises only the
# Connection Stack contract and Lambda/EC2 seams; it never invokes deploy.sh,
# resume/destroy lifecycle scripts, AWS, or local credentials.
"$(json_node)" tests/connection_stack_v2_contract_test.mjs
"$(json_node)" tests/connection_stack_v2_dynamo_store_test.mjs
"$(json_node)" tests/connection_stack_v2_dynamo_deployment_store_test.mjs
"$(json_node)" tests/connection_stack_v2_deployment_provisioner_test.mjs
"$(json_node)" tests/connection_stack_v2_deployment_observer_test.mjs
"$(json_node)" tests/connection_stack_v2_handler_test.mjs
"$(json_node)" tests/connection_stack_v2_template_test.mjs
"$(json_node)" tests/connection_stack_v2_worker_session_contract_test.mjs
"$(json_node)" tests/connection_stack_v2_worker_session_service_test.mjs
"$(json_node)" tests/connection_stack_v2_worker_identity_verifier_test.mjs
"$(json_node)" tests/connection_stack_v2_dynamo_worker_session_store_test.mjs
"$(json_node)" tests/connection_stack_v2_worker_bootstrap_user_data_test.mjs
"$(json_node)" tests/connection_stack_v2_worker_task_contract_test.mjs
"$(json_node)" tests/connection_stack_v2_worker_task_service_test.mjs
"$(json_node)" tests/connection_stack_v2_dynamo_worker_task_store_test.mjs

for source in \
  scripts/connection-stack-v2/src/dynamo-receipt-store.mjs \
  scripts/connection-stack-v2/src/dynamo-deployment-store.mjs \
  scripts/connection-stack-v2/src/dynamo-worker-session-store.mjs \
  scripts/connection-stack-v2/src/dynamo-worker-task-store.mjs \
  scripts/connection-stack-v2/src/deployment-provisioner.mjs \
  scripts/connection-stack-v2/src/deployment-observer.mjs \
  scripts/connection-stack-v2/src/handler.mjs \
  scripts/connection-stack-v2/src/worker-bootstrap-user-data.mjs \
  scripts/connection-stack-v2/src/worker-identity-verifier.mjs \
  scripts/connection-stack-v2/src/worker-session-contract.mjs \
  scripts/connection-stack-v2/src/worker-session-service.mjs \
  scripts/connection-stack-v2/src/worker-task-contract.mjs \
  scripts/connection-stack-v2/src/worker-task-service.mjs; do
  "$(json_node)" --check "$source"
done
