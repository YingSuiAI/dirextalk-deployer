#!/usr/bin/env bash
# lib/state.sh - state.json helpers for the deployment state machine.
#
# Sourced by orchestrate.sh and phases/*.sh. All state.json reads/writes go
# through this file to keep structure and fields consistent. Requires Node.js.
#
# state.json path: $DIREXTALK_WORKDIR/state.json.
# By default, DOMAIN=__DOMAIN__ maps to ~/.dirextalk/nodes/<service_id>/state.json.
#
# PHASES order is the state-machine execution order.

STATE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$STATE_LIB_DIR/paths.sh"
# shellcheck disable=SC1090
source "$STATE_LIB_DIR/json.sh"

# Phase list; order matters.
PHASES=(
  S0_PREREQ_AWS
  S1_PREFLIGHT
  S2_DOMAIN
  S3_PROVISION
  S4_BOOTSTRAP_STACK
  S5_INIT_TOKENS
  S6_WIRE_LOCAL
  S7_VERIFY_E2E
)

# Paths.
DIREXTALK_WORKDIR=$(dirextalk_default_workdir)
STATE_JSON="$DIREXTALK_WORKDIR/state.json"

# Timestamp helper.
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Shared logging helpers.
log()  { echo -e "\033[36m[dirextalk]\033[0m $*" >&2; }
ok()   { echo -e "\033[32m[dirextalk]\033[0m $*" >&2; }
warn() { echo -e "\033[33m[dirextalk]\033[0m $*" >&2; }
fail() { echo -e "\033[31m[dirextalk][FATAL]\033[0m $*" >&2; exit 1; }
is_yes() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    y|yes|true|1) return 0 ;;
    *) return 1 ;;
  esac
}

restrict_private_file() {
  local file=$1 uname_s win_file user user_domain
  chmod 600 "$file" 2>/dev/null || true
  uname_s=$(uname -s 2>/dev/null || printf unknown)
  case "$uname_s" in
    MINGW*|MSYS*|CYGWIN*)
      command -v icacls >/dev/null 2>&1 || return 0
      win_file=$file
      if command -v cygpath >/dev/null 2>&1; then
        win_file=$(cygpath -w "$file")
      fi
      user=$(_windows_current_user)
      user_domain=${USERDOMAIN:-}
      MSYS2_ARG_CONV_EXCL='*' icacls "$win_file" /inheritance:r >/dev/null 2>&1 || true
      MSYS2_ARG_CONV_EXCL='*' icacls "$win_file" /remove:g \
        "Users" "Authenticated Users" "Everyone" "CodexSandboxUsers" \
        "${user_domain}\\CodexSandboxUsers" >/dev/null 2>&1 || true
      MSYS2_ARG_CONV_EXCL='*' icacls "$win_file" /grant:r "NT AUTHORITY\\SYSTEM:F" "BUILTIN\\Administrators:F" >/dev/null 2>&1 || true
      [ -n "$user" ] && MSYS2_ARG_CONV_EXCL='*' icacls "$win_file" /grant:r "$user:F" >/dev/null 2>&1 || true
      ;;
  esac
}

_windows_current_user() {
  if [ -n "${USERDOMAIN:-}" ] && [ -n "${USERNAME:-}" ]; then
    printf '%s\\%s\n' "$USERDOMAIN" "$USERNAME"
    return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -NonInteractive -Command '[System.Security.Principal.WindowsIdentity]::GetCurrent().Name' 2>/dev/null \
      | tr -d '\r' | tail -n 1
    return 0
  fi
  if command -v whoami.exe >/dev/null 2>&1; then
    whoami.exe 2>/dev/null | tr -d '\r' | tail -n 1
    return 0
  fi
  return 0
}

# Initialize state.json for a new deployment.
state_init() {
  mkdir -p "$DIREXTALK_WORKDIR"
  local run_id=${RUN_ID:-dirextalk-$(date -u +%Y%m%d-%H%M%S)}
  : > "$STATE_JSON"
  json_mutate "$STATE_JSON" state-init "$run_id" "${AWS_DEFAULT_REGION:-${AWS_REGION:-}}" "$(_now)" "${PHASES[@]}"
  log "Initialized state.json -> $STATE_JSON (run_id=$run_id)"
}

# Ensure state.json exists.
state_ensure() {
  [ -f "$STATE_JSON" ] || state_init
}

# Top-level field accessors.
state_get()      { json_get "$STATE_JSON" "$1"; }
state_set()      { json_mutate "$STATE_JSON" set-string "$1" "$2"; }
state_set_raw()  { json_mutate "$STATE_JSON" set-json "$1" "$2"; }
state_set_object() {
  local path=$1 object_json
  shift
  object_json=$(json_build object "$@")
  json_mutate "$STATE_JSON" set-json "$path" "$object_json"
}

# Resource records used by destroy.sh.
res_set() { json_mutate "$STATE_JSON" set-string "resources.$1" "$2"; }
res_get() { json_get "$STATE_JSON" "resources.$1"; }

# Phase status helpers.
# phase_status <PHASE>
phase_status() { json_get "$STATE_JSON" "phases.$1.status" "pending"; }

# phase_set <PHASE> <status> [evidence]
phase_set() {
  local p=$1 st=$2 ev=${3:-}
  json_mutate "$STATE_JSON" phase-set "$p" "$st" "$(_now)" "$ev"
}

# Find the first phase whose status is not done.
first_unfinished_phase() {
  local p
  for p in "${PHASES[@]}"; do
    [ "$(phase_status "$p")" != "done" ] && { echo "$p"; return 0; }
  done
  echo "DONE"
}

# poll_until <description> <interval-seconds> <max-attempts> <check-command...>
# Return 0 when the check command succeeds. max=0 means poll forever.
poll_until() {
  local desc=$1 interval=$2 maxn=$3; shift 3
  local i=0
  while true; do
    if "$@"; then ok "$desc ✓"; return 0; fi
    i=$((i+1))
    if [ "$maxn" -gt 0 ] && [ "$i" -ge "$maxn" ]; then
      warn "$desc timed out after $i unsuccessful attempts"; return 1
    fi
    log "$desc waiting (attempt $i, retry in ${interval}s)"
    sleep "$interval"
  done
}
