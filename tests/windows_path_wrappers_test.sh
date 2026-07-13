#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_SCRIPT="$ROOT/tests/windows_path_wrappers_test.ps1"
STATUS_TEST_SCRIPT="$ROOT/tests/windows_orchestrate_status_smoke_test.ps1"

to_windows_path() {
  local path=$1 drive rest
  case "$path" in
    /mnt/[A-Za-z]/*)
      drive=${path:5:1}
      rest=${path:6}
      printf '%s:%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | sed 's#/#\\#g')"
      ;;
    /[A-Za-z]/*)
      drive=${path:1:1}
      rest=${path:2}
      printf '%s:%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | sed 's#/#\\#g')"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

if command -v cygpath >/dev/null 2>&1; then
  TEST_SCRIPT=$(cygpath -w "$TEST_SCRIPT")
  STATUS_TEST_SCRIPT=$(cygpath -w "$STATUS_TEST_SCRIPT")
else
  TEST_SCRIPT=$(to_windows_path "$TEST_SCRIPT")
  STATUS_TEST_SCRIPT=$(to_windows_path "$STATUS_TEST_SCRIPT")
fi

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$TEST_SCRIPT"
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$STATUS_TEST_SCRIPT"
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TEST_SCRIPT"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$STATUS_TEST_SCRIPT"
else
  echo "windows path wrapper test skipped; PowerShell not found"
fi
