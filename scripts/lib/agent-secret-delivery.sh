#!/usr/bin/env bash
# Private one-time model-secret delivery for the optional Agent runtime.
#
# The source is an operator-owned local file. Its bytes are streamed only over
# a pinned SSH connection into the Agent's private named volume; neither the
# source path nor the secret value enters user-data, state, argv, or logs.

AGENT_MOUNTED_SECRET_MAX_BYTES=16384
AGENT_MOUNTED_SECRET_FILE_RESOLVED=${AGENT_MOUNTED_SECRET_FILE_RESOLVED:-}

_agent_mounted_secret_warn() {
  if declare -F warn >/dev/null 2>&1; then
    warn "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}

agent_mounted_secret_name_is_safe() {
  printf '%s\n' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
}

_agent_mounted_secret_canonical_file() {
  local raw=${1:-} source_dir source_file
  [ -n "$raw" ] || return 1
  source_file=$(dirextalk_execution_path "$raw") || return 1
  [ -L "$source_file" ] && return 1
  [ -f "$source_file" ] && [ -r "$source_file" ] || return 1
  source_dir=$(cd -P -- "$(dirname -- "$source_file")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$source_dir" "$(basename -- "$source_file")"
}

_agent_mounted_secret_file_is_safe() {
  local source=${1:-} bytes hex
  [ -f "$source" ] && [ ! -L "$source" ] && [ -r "$source" ] || return 1
  bytes=$(wc -c < "$source" | tr -d '[:space:]') || return 1
  [ "${bytes:-0}" -gt 0 ] && [ "$bytes" -le "$AGENT_MOUNTED_SECRET_MAX_BYTES" ] || return 1
  hex=$(LC_ALL=C od -An -v -tx1 "$source" | tr -d '[:space:]') || return 1
  case "$hex" in *00*) return 1 ;; esac
  LC_ALL=C awk '
    NR > 1 || $0 == "" || $0 ~ /[[:space:]]/ { invalid = 1 }
    END { exit (NR == 1 && !invalid ? 0 : 1) }
  ' "$source"
}

_agent_mounted_secret_is_managed_local_path() {
  local source=$1 root canonical_root
  for root in "${S3_PHASE_DIR:-}" "${DIREXTALK_WORKDIR:-}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    canonical_root=$(cd -P -- "$root" 2>/dev/null && pwd -P) || continue
    case "$source" in
      "$canonical_root"|"$canonical_root"/*) return 0 ;;
    esac
  done
  return 1
}

_agent_mounted_secret_catalog_references_name() {
  local catalog=$1 name=$2 native_catalog
  native_catalog=$(dirextalk_native_tool_path "$catalog") || return 1
  "$(json_node)" -e '
const fs = require("fs");
const [catalog, name] = process.argv.slice(1);
const parsed = JSON.parse(fs.readFileSync(catalog, "utf8"));
const profiles = Array.isArray(parsed.profiles) ? parsed.profiles : [];
process.exit(profiles.some((profile) => profile && profile.secret_ref === `mounted:${name}`) ? 0 : 1);
' "$native_catalog" "$name" >/dev/null 2>&1
}

agent_mounted_secret_delivery_inputs_validate() {
  local source name enabled catalog
  AGENT_MOUNTED_SECRET_FILE_RESOLVED=
  source=${AGENT_MOUNTED_SECRET_FILE:-}
  name=${AGENT_MOUNTED_SECRET_NAME:-}
  if [ -z "$source$name" ]; then
    return 0
  fi
  if [ -z "$source" ] || [ -z "$name" ]; then
    _agent_mounted_secret_warn 'AGENT_MOUNTED_SECRET_FILE and AGENT_MOUNTED_SECRET_NAME must be set together.'
    return 1
  fi
  enabled=$(state_get agent_release.enabled)
  if [ "$enabled" != true ]; then
    _agent_mounted_secret_warn 'Mounted Agent secret delivery requires the optional Agent runtime to be enabled.'
    return 1
  fi
  agent_mounted_secret_name_is_safe "$name" || {
    _agent_mounted_secret_warn 'AGENT_MOUNTED_SECRET_NAME is not a safe mounted-secret filename.'
    return 1
  }
  catalog=${AGENT_MODEL_PROFILES_FILE:-}
  _agent_mounted_secret_catalog_references_name "$catalog" "$name" || {
    _agent_mounted_secret_warn 'AGENT_MOUNTED_SECRET_NAME is not referenced by the reviewed Agent model-profile catalog.'
    return 1
  }
  source=$(_agent_mounted_secret_canonical_file "$source") || {
    _agent_mounted_secret_warn 'AGENT_MOUNTED_SECRET_FILE must be a readable, regular non-symlink file.'
    return 1
  }
  if _agent_mounted_secret_is_managed_local_path "$source"; then
    _agent_mounted_secret_warn 'AGENT_MOUNTED_SECRET_FILE must stay outside the deployer repository and service work directory.'
    return 1
  fi
  _agent_mounted_secret_file_is_safe "$source" || {
    _agent_mounted_secret_warn 'AGENT_MOUNTED_SECRET_FILE must contain one non-empty single-line token of at most 16 KiB.'
    return 1
  }
  AGENT_MOUNTED_SECRET_FILE_RESOLVED=$source
}

agent_mounted_secret_delivery_is_configured() {
  [ -n "${AGENT_MOUNTED_SECRET_FILE_RESOLVED:-}" ] && [ -n "${AGENT_MOUNTED_SECRET_NAME:-}" ]
}

_agent_mounted_secret_canonical_ipv4() {
  local value=${1:-} octet octet2 octet3 octet4 extra
  case "$value" in
    *[!0-9.]*|.*|*..*|*.) return 1 ;;
  esac
  IFS=. read -r octet octet2 octet3 octet4 extra <<EOF
$value
EOF
  [ -n "$octet" ] && [ -n "$octet2" ] && [ -n "$octet3" ] && [ -n "$octet4" ] && [ -z "$extra" ] || return 1
  for octet in "$octet" "$octet2" "$octet3" "$octet4"; do
    [ "$octet" = "0" ] || [ "${octet#0}" = "$octet" ] || return 1
    [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] || return 1
  done
}

_agent_mounted_secret_delivery_remote_command() {
  local name=$1 quoted_name remote
  printf -v quoted_name '%q' "$name"
  remote=$(cat <<'EOF'
set -eu
cd /var/dirextalk-message-server
exec sudo -n docker compose --env-file .env run --rm -T --no-deps --entrypoint /bin/sh agent-runtime-init -c '
set -eu
name=$1
case "$name" in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]* ) exit 64 ;;
esac
[ "${#name}" -le 128 ] || exit 64
dest=/run/dirextalk-agent/mounted-secrets
[ -d "$dest" ]
tmp=$(mktemp "$dest/.${name}.XXXXXX")
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT HUP INT TERM
cat > "$tmp"
bytes=$(wc -c < "$tmp" | tr -d "[:space:]")
[ "${bytes:-0}" -gt 0 ] && [ "$bytes" -le 16384 ]
hex=$(LC_ALL=C od -An -v -tx1 "$tmp" | tr -d "[:space:]")
case "$hex" in *00*) exit 65 ;; esac
LC_ALL=C awk "NR > 1 || \$0 == \"\" || \$0 ~ /[[:space:]]/ { invalid = 1 } END { exit (NR == 1 && !invalid ? 0 : 1) }" "$tmp"
chown 65532:65532 "$tmp"
chmod 0400 "$tmp"
mv -f "$tmp" "$dest/$name"
trap - EXIT HUP INT TERM
' agent-mounted-secret-delivery __DIREXTALK_AGENT_SECRET_NAME__
EOF
)
  printf '%s\n' "${remote/__DIREXTALK_AGENT_SECRET_NAME__/$quoted_name}"
}

agent_mounted_secret_deliver_lightsail() {
  local public_ip=$1 keyfile=$2 known_hosts=$3 source=${AGENT_MOUNTED_SECRET_FILE_RESOLVED:-}
  local name=${AGENT_MOUNTED_SECRET_NAME:-} ssh_user=${DIREXTALK_BOOTSTRAP_SSH_USER:-ubuntu}
  local diagnostic_log remote
  _agent_mounted_secret_canonical_ipv4 "$public_ip" || return 1
  [ "$ssh_user" = ubuntu ] && [ -f "$keyfile" ] && [ -s "$known_hosts" ] || return 1
  _agent_mounted_secret_file_is_safe "$source" || return 1
  agent_mounted_secret_name_is_safe "$name" || return 1
  diagnostic_log="$DIREXTALK_WORKDIR/agent-mounted-secret-delivery-ssh.log"
  : > "$diagnostic_log"
  restrict_private_file "$diagnostic_log"
  remote=$(_agent_mounted_secret_delivery_remote_command "$name") || return 1
  if ssh -T -i "$keyfile" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=$known_hosts" \
      "$ssh_user@$public_ip" "$remote" < "$source" >>"$diagnostic_log" 2>&1; then
    return 0
  fi
  _agent_mounted_secret_warn 'Could not deliver the mounted Agent secret over the verified SSH connection.'
  return 1
}

_agent_mounted_secret_cleanup_remote_command() {
  cat <<'EOF'
set -eu
cd /var/dirextalk-message-server
exec sudo -n docker compose --env-file .env run --rm -T --no-deps --entrypoint /bin/sh agent-runtime-init -c '
set -eu
dest=/run/dirextalk-agent/mounted-secrets
[ -d "$dest" ]
find "$dest" -mindepth 1 -maxdepth 1 -type f -delete
'
EOF
}

agent_mounted_secret_cleanup_lightsail() {
  local public_ip=$1 keyfile=$2 known_hosts=$3 ssh_user=${DIREXTALK_BOOTSTRAP_SSH_USER:-ubuntu}
  local remote
  _agent_mounted_secret_canonical_ipv4 "$public_ip" || return 2
  [ "$ssh_user" = ubuntu ] && [ -f "$keyfile" ] && [ -s "$known_hosts" ] || return 2
  remote=$(_agent_mounted_secret_cleanup_remote_command) || return 1
  ssh -T -i "$keyfile" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts" \
    "$ssh_user@$public_ip" "$remote" >/dev/null 2>&1
}
