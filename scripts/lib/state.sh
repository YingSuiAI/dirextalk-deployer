#!/usr/bin/env bash
# lib/state.sh - state.json helpers for the deployment state machine.
#
# Sourced by orchestrate.sh and phases/*.sh. All state.json reads/writes go
# through this file to keep structure and fields consistent. Requires jq.
#
# state.json path: $P2P_WORKDIR/state.json (default ~/.direxio/deploy/).
#
# PHASES order is the state-machine execution order.

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
P2P_WORKDIR=${P2P_WORKDIR:-${DIREXIO_WORKDIR:-$HOME/.direxio/deploy}}
STATE_JSON="$P2P_WORKDIR/state.json"

# Timestamp helper.
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Shared logging helpers.
log()  { echo -e "\033[36m[p2p]\033[0m $*" >&2; }
ok()   { echo -e "\033[32m[p2p]\033[0m $*" >&2; }
warn() { echo -e "\033[33m[p2p]\033[0m $*" >&2; }
fail() { echo -e "\033[31m[p2p][FATAL]\033[0m $*" >&2; exit 1; }
is_yes() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    y|yes|true|1) return 0 ;;
    *) return 1 ;;
  esac
}

# Initialize state.json for a new deployment.
state_init() {
  mkdir -p "$P2P_WORKDIR"
  local run_id=${RUN_ID:-p2p-$(date -u +%Y%m%d-%H%M%S)}
  local phases_json="{}"
  local p
  for p in "${PHASES[@]}"; do
    phases_json=$(echo "$phases_json" | jq --arg k "$p" '. + {($k): {"status":"pending"}}')
  done
  jq -n \
    --arg run_id "$run_id" \
    --arg region "${AWS_DEFAULT_REGION:-${AWS_REGION:-}}" \
    --argjson phases "$phases_json" \
    --arg ts "$(_now)" \
    '{
       run_id: $run_id,
       region: (if $region == "" then null else $region end),
       domain_mode: null,
       domain: null,
       domain_confirmed_irreversible: false,
       instance_type: null,
       dns_ready: false,
       existing_state_confirmed: false,
       phase: "S0_PREREQ_AWS",
       created_at: $ts,
       phases: $phases,
       resources: {}
     }' > "$STATE_JSON"
  log "Initialized state.json -> $STATE_JSON (run_id=$run_id)"
}

# Ensure state.json exists.
state_ensure() {
  [ -f "$STATE_JSON" ] || state_init
}

# Atomic write using a jq filter.
_state_write() {
  local filter=$1; shift
  local tmp="$STATE_JSON.tmp.$$"
  jq "$@" "$filter" "$STATE_JSON" > "$tmp" && mv "$tmp" "$STATE_JSON"
}

# Top-level field accessors.
state_get()      { jq -r --arg k "$1" '.[$k] // empty' "$STATE_JSON"; }
state_set()      { _state_write '.[$k] = $v' --arg k "$1" --arg v "$2"; }
state_set_raw()  { _state_write ".$1 = $2"; }

# Resource records used by destroy.sh.
res_set() { _state_write '.resources[$k] = $v' --arg k "$1" --arg v "$2"; }
res_get() { jq -r --arg k "$1" '.resources[$k] // empty' "$STATE_JSON"; }

# Phase status helpers.
# phase_status <PHASE>
phase_status() { jq -r --arg p "$1" '.phases[$p].status // "pending"' "$STATE_JSON"; }

# phase_set <PHASE> <status> [evidence]
phase_set() {
  local p=$1 st=$2 ev=${3:-}
  _state_write '
    .phases[$p].status = $st
    | .phases[$p].ts = $ts
    | (if $ev != "" then .phases[$p].evidence = $ev else . end)
    | .phase = $p
  ' --arg p "$p" --arg st "$st" --arg ev "$ev" --arg ts "$(_now)"
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
