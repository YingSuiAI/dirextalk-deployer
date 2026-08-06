#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck disable=SC1091
source "$script_dir/production-ops-common.sh"

production_bind_runtime
production_verify_edge
production_require_control_file "$production_base/image-attestation" 400
# Revalidate the strongest recorded edge identity immediately before mutation.
production_verify_edge
docker container rm -f "$production_edge_id" >/dev/null
"$production_split/scripts/cleanup-local.sh" --purge "$production_run"

audit_root=$production_base/reset-audit
install -d -o "$(id -u)" -g "$(id -g)" -m 0700 "$audit_root"
audit_dir=$audit_root/$(date -u +%Y%m%dT%H%M%SZ)-$production_stack
[ ! -e "$audit_dir" ] || production_die 'reset audit target already exists'
mv "$production_run" "$audit_dir"
mv "$production_base/image-attestation" "$audit_dir/image-attestation.previous"
rm -f "$production_base/p2p/bootstrap.json" "$production_base/.split-deploy-done" \
  "$production_base/.deploy-done" "$production_base/edge-bootstrap-receipt" \
  "$production_base/runner-preparation.env"
"$production_base/production-ops/bootstrap-production.sh"
printf 'production split reset passed: previous_control_files=%s\n' "$audit_dir"
