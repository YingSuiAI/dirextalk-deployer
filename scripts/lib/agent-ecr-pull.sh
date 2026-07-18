#!/usr/bin/env bash
# Short-lived, least-privilege authentication for the optional private Agent
# image. Persistent AWS credentials and Docker registry credentials never
# cross the SSH boundary or enter deployment state.

AGENT_ECR_REPOSITORY=dirextalk-agent
AGENT_ECR_SESSION_NAME=dirextalk-agent-pull
AGENT_ECR_FEDERATION_DURATION_SECONDS=3600
AGENT_ECR_ASSUME_ROLE_DURATION_SECONDS=3600

_agent_ecr_warn() {
  if declare -F warn >/dev/null 2>&1; then
    warn "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}

agent_ecr_parse_image() {
  local value=${1:-} account region registry repository
  case "$value" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;;
  esac
  printf '%s\n' "$value" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/dirextalk-agent:v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)[A-Za-z0-9.-]*-[0-9a-f]{7,40}@sha256:[0-9a-f]{64}$' || return 1
  registry=${value%%/*}
  repository=${value#*/}
  repository=${repository%%:*}
  account=${registry%%.*}
  region=${registry#*.dkr.ecr.}
  region=${region%%.amazonaws.com}
  [ "$repository" = "$AGENT_ECR_REPOSITORY" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$account" "$region" "$registry" "$repository"
}

agent_ecr_role_arn_is_same_account() {
  local account=${1:-} role_arn=${2:-}
  printf '%s\n' "$account" | grep -Eq '^[0-9]{12}$' || return 1
  printf '%s\n' "$role_arn" | grep -Eq "^arn:aws:iam::${account}:role/[A-Za-z0-9+=,.@_/-]+$"
}

_agent_ecr_canonical_ipv4() {
  local value=${1:-} octet octet2 octet3 octet4 extra
  case "$value" in
    *[!0-9.]*|.*|*..*|*.) return 1 ;;
  esac
  IFS=. read -r octet octet2 octet3 octet4 extra <<EOF
$value
EOF
  [ -n "$octet" ] && [ -n "$octet2" ] && [ -n "$octet3" ] && [ -n "$octet4" ] && [ -z "$extra" ] || return 1
  for octet in "$octet" "$octet2" "$octet3" "$octet4"; do
    [ "$octet" = 0 ] || [ "${octet#0}" = "$octet" ] || return 1
    [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] || return 1
  done
}

agent_ecr_auth_mode_for_caller() {
  local account=${1:-} caller_arn=${2:-} pull_role_arn=${3:-}
  case "$caller_arn" in
    "arn:aws:iam::$account:root"|"arn:aws:iam::$account:user/"*)
      [ -z "$pull_role_arn" ] || agent_ecr_role_arn_is_same_account "$account" "$pull_role_arn" || return 1
      if [ -n "$pull_role_arn" ]; then
        printf 'assume_role\n'
      else
        printf 'federation_token\n'
      fi
      ;;
    "arn:aws:sts::$account:assumed-role/"*)
      agent_ecr_role_arn_is_same_account "$account" "$pull_role_arn" || {
        _agent_ecr_warn 'An assumed-role AWS caller cannot use GetFederationToken; set an explicit same-account DIREXTALK_ECR_PULL_ROLE_ARN or use a root/IAM-user deployment profile.'
        return 1
      }
      printf 'assume_role\n'
      ;;
    *)
      _agent_ecr_warn 'The AWS caller type is not approved for private Agent ECR authorization.'
      return 1
      ;;
  esac
}

agent_ecr_state_is_enabled() {
  local source=${1:-} account=${2:-} region=${3:-} registry=${4:-} repository=${5:-}
  local repository_arn=${6:-} auth_mode=${7:-} pull_role_arn=${8:-}
  [ "$source" = private_ecr ] \
    && printf '%s\n' "$account" | grep -Eq '^[0-9]{12}$' \
    && printf '%s\n' "$region" | grep -Eq '^[a-z0-9-]+$' \
    && [ "$registry" = "$account.dkr.ecr.$region.amazonaws.com" ] \
    && [ "$repository" = "$AGENT_ECR_REPOSITORY" ] \
    && [ "$repository_arn" = "arn:aws:ecr:$region:$account:repository/$AGENT_ECR_REPOSITORY" ] \
    && { [ "$auth_mode" = federation_token ] || [ "$auth_mode" = assume_role ]; } \
    && { [ "$auth_mode" != federation_token ] || [ -z "$pull_role_arn" ]; } \
    && { [ "$auth_mode" != assume_role ] || agent_ecr_role_arn_is_same_account "$account" "$pull_role_arn"; }
}

agent_ecr_prepare_state() {
  local image=${1:-} parsed image_account image_region registry repository
  local deployment_region caller_account caller_arn auth_mode pull_role_arn repository_arn
  local source stored_account stored_region stored_registry stored_repository stored_repository_arn stored_auth_mode stored_role
  parsed=$(agent_ecr_parse_image "$image") || {
    _agent_ecr_warn 'EC2 Agent images must use the exact private ECR dirextalk-agent repository with an immutable prerelease tag and digest.'
    return 1
  }
  IFS=$'\t' read -r image_account image_region registry repository <<EOF
$parsed
EOF
  deployment_region=$(state_get region)
  [ -n "$deployment_region" ] || deployment_region=${AWS_DEFAULT_REGION:-${AWS_REGION:-}}
  [ "$image_region" = "$deployment_region" ] || {
    _agent_ecr_warn 'The private Agent ECR image must be in the deployment region.'
    return 1
  }
  caller_account=$(aws sts get-caller-identity --query Account --output text) || return 1
  caller_arn=$(aws sts get-caller-identity --query Arn --output text) || return 1
  printf '%s\n' "$caller_account" | grep -Eq '^[0-9]{12}$' || return 1
  [ "$image_account" = "$caller_account" ] || {
    _agent_ecr_warn 'The private Agent ECR image must be in the confirmed deployment account.'
    return 1
  }
  pull_role_arn=${DIREXTALK_ECR_PULL_ROLE_ARN:-}
  auth_mode=$(agent_ecr_auth_mode_for_caller "$caller_account" "$caller_arn" "$pull_role_arn") || return 1
  repository_arn="arn:aws:ecr:$image_region:$image_account:repository/$repository"

  source=$(state_get agent_registry.source)
  stored_account=$(state_get agent_registry.account_id)
  stored_region=$(state_get agent_registry.region)
  stored_registry=$(state_get agent_registry.registry)
  stored_repository=$(state_get agent_registry.repository)
  stored_repository_arn=$(state_get agent_registry.repository_arn)
  stored_auth_mode=$(state_get agent_registry.auth_mode)
  stored_role=$(state_get agent_registry.pull_role_arn)
  if [ -n "$source$stored_account$stored_region$stored_registry$stored_repository$stored_repository_arn$stored_auth_mode$stored_role" ]; then
    agent_ecr_state_is_enabled "$source" "$stored_account" "$stored_region" "$stored_registry" "$stored_repository" "$stored_repository_arn" "$stored_auth_mode" "$stored_role" || {
      _agent_ecr_warn 'Private Agent registry state is incomplete or unsafe.'
      return 1
    }
    [ "$stored_account|$stored_region|$stored_registry|$stored_repository|$stored_repository_arn|$stored_auth_mode|$stored_role" = \
      "$image_account|$image_region|$registry|$repository|$repository_arn|$auth_mode|$pull_role_arn" ] || {
      _agent_ecr_warn 'Private Agent registry metadata is frozen and cannot be changed after selection.'
      return 1
    }
    return 0
  fi
  if [ -n "$(state_get resources.instance_id)" ]; then
    _agent_ecr_warn 'Existing infrastructure has no frozen private Agent registry metadata; refusing an unsafe auth migration.'
    return 1
  fi
  local resolved_json
  # Every value has already passed a strict ARN/registry/region grammar. Keep
  # the 12-digit account as JSON text so accounts with leading zeroes are not
  # normalized by a generic scalar builder.
  resolved_json=$(printf '{"source":"private_ecr","account_id":"%s","region":"%s","registry":"%s","repository":"%s","repository_arn":"%s","auth_mode":"%s","pull_role_arn":"%s"}\n' \
    "$image_account" "$image_region" "$registry" "$repository" "$repository_arn" "$auth_mode" "$pull_role_arn") || return 1
  state_set_raw agent_registry "$resolved_json"
}

_agent_ecr_write_session_policy() {
  local path=$1 repository_arn=$2
  cat > "$path" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "$repository_arn"
    }
  ]
}
EOF
  chmod 0600 "$path"
}

_agent_ecr_write_credentials_from_stdin() {
  local output=$1 native_output node
  native_output=$(dirextalk_native_tool_path "$output") || return 1
  node=$(json_node) || return 1
  "$node" -e '
const fs = require("fs");
const output = process.argv[1];
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => raw += chunk);
process.stdin.on("end", () => {
  const value = JSON.parse(raw);
  for (const key of ["AccessKeyId", "SecretAccessKey", "SessionToken"]) {
    if (typeof value[key] !== "string" || value[key].length === 0 || /[\r\n]/.test(value[key])) process.exit(64);
  }
  const body = `[dirextalk-agent-ecr-session]\naws_access_key_id = ${value.AccessKeyId}\naws_secret_access_key = ${value.SecretAccessKey}\naws_session_token = ${value.SessionToken}\n`;
  const fd = fs.openSync(output, "wx", 0o600);
  try { fs.writeFileSync(fd, body, { encoding: "utf8" }); } finally { fs.closeSync(fd); }
});
' "$native_output"
}

# Writes only the short-lived Docker password to stdout. STS credentials exist
# briefly in a private local temp file, never in environment variables or argv,
# and the function's EXIT trap removes and verifies the whole temp directory.
agent_ecr_stream_login_password() (
  set -euo pipefail
  local source account region repository_arn auth_mode pull_role_arn caller_account caller_arn expected_mode
  local auth_dir policy_file credentials_file config_file policy_native credentials_native config_native
  source=$(state_get agent_registry.source)
  account=$(state_get agent_registry.account_id)
  region=$(state_get agent_registry.region)
  repository_arn=$(state_get agent_registry.repository_arn)
  auth_mode=$(state_get agent_registry.auth_mode)
  pull_role_arn=$(state_get agent_registry.pull_role_arn)
  agent_ecr_state_is_enabled "$source" "$account" "$region" "$(state_get agent_registry.registry)" \
    "$(state_get agent_registry.repository)" "$repository_arn" "$auth_mode" "$pull_role_arn" || return 1
  caller_account=$(aws sts get-caller-identity --query Account --output text)
  caller_arn=$(aws sts get-caller-identity --query Arn --output text)
  [ "$caller_account" = "$account" ] || return 1
  expected_mode=$(agent_ecr_auth_mode_for_caller "$account" "$caller_arn" "$pull_role_arn")
  [ "$expected_mode" = "$auth_mode" ] || return 1

  auth_dir=$(mktemp -d "$DIREXTALK_WORKDIR/.agent-ecr-auth.XXXXXX")
  chmod 0700 "$auth_dir"
  cleanup() {
    rm -rf -- "$auth_dir"
    [ ! -e "$auth_dir" ]
  }
  trap cleanup EXIT HUP INT TERM
  policy_file="$auth_dir/session-policy.json"
  credentials_file="$auth_dir/credentials"
  config_file="$auth_dir/config"
  _agent_ecr_write_session_policy "$policy_file" "$repository_arn"
  : > "$config_file"
  chmod 0600 "$config_file"
  policy_native=$(dirextalk_native_tool_path "$policy_file")
  credentials_native=$(dirextalk_native_tool_path "$credentials_file")
  config_native=$(dirextalk_native_tool_path "$config_file")
  case "$auth_mode" in
    federation_token)
      aws sts get-federation-token \
        --name "$AGENT_ECR_SESSION_NAME" \
        --duration-seconds "$AGENT_ECR_FEDERATION_DURATION_SECONDS" \
        --policy "file://$policy_native" \
        --query Credentials --output json \
        | _agent_ecr_write_credentials_from_stdin "$credentials_file"
      ;;
    assume_role)
      aws sts assume-role \
        --role-arn "$pull_role_arn" \
        --role-session-name "$AGENT_ECR_SESSION_NAME" \
        --duration-seconds "$AGENT_ECR_ASSUME_ROLE_DURATION_SECONDS" \
        --policy "file://$policy_native" \
        --query Credentials --output json \
        | _agent_ecr_write_credentials_from_stdin "$credentials_file"
      ;;
    *) return 1 ;;
  esac
  chmod 0600 "$credentials_file"
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN \
    -u AWS_ROLE_ARN -u AWS_ROLE_SESSION_NAME -u AWS_WEB_IDENTITY_TOKEN_FILE \
    -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONFIG_FILE="$config_native" \
    AWS_SHARED_CREDENTIALS_FILE="$credentials_native" \
    AWS_PROFILE=dirextalk-agent-ecr-session \
    aws ecr get-login-password --region "$region"
)

agent_ecr_auth_cleanup_pinned() {
  local public_ip=${1:-} keyfile=${2:-} known_hosts=${3:-} registry=${4:-}
  local ssh_user=${DIREXTALK_BOOTSTRAP_SSH_USER:-ubuntu} remote
  _agent_ecr_canonical_ipv4 "$public_ip" || return 2
  [ "$ssh_user" = ubuntu ] && [ -f "$keyfile" ] && [ -s "$known_hosts" ] || return 2
  printf '%s\n' "$registry" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$' || return 2
  remote="set -eu; auth_dir=/run/dirextalk-ecr-auth; sudo -n -- docker --config \"\$auth_dir\" logout '$registry' >/dev/null 2>&1 || true; sudo -n -- rm -rf -- \"\$auth_dir\"; sudo -n -- test ! -e \"\$auth_dir\""
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
