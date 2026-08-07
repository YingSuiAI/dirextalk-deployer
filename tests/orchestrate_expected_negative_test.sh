#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run_case() {
  local phase_status_code=$1 expected=$2 out="$tmp/out-$1" marker="$tmp/done-$1"
  if ROOT="$ROOT" CASE_MARKER="$marker" CASE_STATUS="$phase_status_code" \
      DIREXTALK_ORCHESTRATE_LIB_ONLY=1 bash -c '
        set -uo pipefail
        source "$ROOT/scripts/orchestrate.sh"
        precheck_new_deploy_domain_env() { return 0; }
        check_deps() { return 0; }
        guard_existing_state() { return 0; }
        state_ensure() { return 0; }
        ensure_production_domain_selected() { return 0; }
        ensure_region_selected() { return 0; }
        ensure_cost_estimate() { return 0; }
        log() { :; }
        ok() { printf "ok: %s\n" "$*"; }
        warn() { printf "warn: %s\n" "$*"; }
        phase_status() { printf pending; }
        first_unfinished_phase() { [ -f "$CASE_MARKER" ] && printf DONE || printf S0_PREREQ_AWS; }
        print_delivery() { return 0; }
        run_one_phase() {
          if [ "$CASE_STATUS" -eq 0 ]; then : >"$CASE_MARKER"; fi
          return "$CASE_STATUS"
        }
        cmd_run
      ' >"$out" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  [ "$actual" -eq "$expected" ] || { cat "$out" >&2; exit 1; }
}

run_case 0 0
run_case 2 2
run_case 3 3
run_case 17 1
grep -Fq 'waiting for user action' "$tmp/out-2"
grep -Fq 'stopped at an expected protected negative state (rc=3)' "$tmp/out-3"
grep -Fq 'Phase S0_PREREQ_AWS failed (rc=17)' "$tmp/out-17"

echo 'orchestrate result mapping ok'
