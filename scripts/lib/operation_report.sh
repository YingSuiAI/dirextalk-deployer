#!/usr/bin/env bash
# lib/operation_report.sh - redacted operation reports for deploy/destroy flows.

OPERATION_REPORT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$OPERATION_REPORT_LIB_DIR/paths.sh"
# shellcheck disable=SC1090
source "$OPERATION_REPORT_LIB_DIR/json.sh"

operation_report_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

operation_report_service_id() {
  local state=$1 service_id
  service_id=$(json_get "$state" agent_service_id)
  [ -n "$service_id" ] || service_id=$(json_get "$state" domain)
  printf '%s\n' "${service_id:-unknown-service}"
}

operation_report_default_path() {
  local operation=$1 state=$2 service_id service_dir root
  service_id=$(operation_report_service_id "$state")
  service_dir=$(json_get "$state" agent_service_dir)
  [ -n "$service_dir" ] || service_dir=$(dirname "$state")
  case "$operation" in
    destroy)
      root=$(dirextalk_home)
      printf '%s/reports/%s/operation-report.json\n' "$root" "$service_id"
      ;;
    *)
      printf '%s/operation-report.json\n' "$service_dir"
      ;;
  esac
}

operation_report_json() {
  local operation=$1 status=$2 state=$3 generated_at=$4
  json_cli operation-report "$operation" "$status" "$state" "$generated_at"
}

operation_report_write() {
  local operation=$1 status=$2 state=$3 output=${4:-} generated_at tmp
  [ -f "$state" ] || {
    echo "state.json not found for operation report: $state" >&2
    return 1
  }
  [ -n "$output" ] || output=$(operation_report_default_path "$operation" "$state")
  mkdir -p "$(dirname "$output")"
  generated_at=$(operation_report_now)
  tmp="$output.tmp.$$"
  operation_report_json "$operation" "$status" "$state" "$generated_at" > "$tmp"
  mv "$tmp" "$output"
  printf '%s\n' "$output"
}
