#!/usr/bin/env bash
# aws-credentials.sh - import/verify AWS deployment credentials.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/aws.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/aws-credentials.sh import-csv <aws-access-key.csv> [profile] [region]
  scripts/aws-credentials.sh verify [profile]

Default profile: direxio-deployer
Root identities are allowed when the operator explicitly chooses them.
EOF
}

aws_credentials_file() {
  printf '%s\n' "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
}

aws_config_file() {
  printf '%s\n' "${AWS_CONFIG_FILE:-$HOME/.aws/config}"
}

ensure_aws_file() {
  local file=$1
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")" 2>/dev/null || true
  [ -f "$file" ] || : > "$file"
  chmod 600 "$file" 2>/dev/null || true
}

csv_column_index() {
  local header=$1 wanted=$2
  awk -v header="$header" -v wanted="$wanted" '
    BEGIN {
      n = split(header, cols, ",")
      for (i = 1; i <= n; i++) {
        sub(/^\xef\xbb\xbf/, "", cols[i])
        gsub(/^"|"$/, "", cols[i])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cols[i])
        if (tolower(cols[i]) == tolower(wanted)) {
          print i
          exit
        }
      }
    }
  '
}

csv_field() {
  local row=$1 index=$2
  awk -v row="$row" -v idx="$index" '
    BEGIN {
      n = split(row, cols, ",")
      value = cols[idx]
      gsub(/^"|"$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
    }
  '
}

read_csv_credentials() {
  local csv=$1 header row ak_i sk_i token_i access_key secret_key session_token
  [ -f "$csv" ] || {
    echo "CSV file not found: $csv" >&2
    return 1
  }
  IFS= read -r header < "$csv" || return 1
  row=$(tail -n +2 "$csv" | sed '/^[[:space:]]*$/d' | head -n 1)
  [ -n "$row" ] || {
    echo "CSV has no credential row: $csv" >&2
    return 1
  }
  ak_i=$(csv_column_index "$header" "Access key ID")
  [ -n "$ak_i" ] || ak_i=$(csv_column_index "$header" "Access key id")
  sk_i=$(csv_column_index "$header" "Secret access key")
  token_i=$(csv_column_index "$header" "Session token")
  [ -n "$ak_i" ] && [ -n "$sk_i" ] || {
    echo "CSV must contain Access key ID and Secret access key columns" >&2
    return 1
  }
  access_key=$(csv_field "$row" "$ak_i")
  secret_key=$(csv_field "$row" "$sk_i")
  session_token=""
  [ -n "$token_i" ] && session_token=$(csv_field "$row" "$token_i")
  [ -n "$access_key" ] && [ -n "$secret_key" ] || {
    echo "CSV credential values are incomplete" >&2
    return 1
  }
  printf '%s\t%s\t%s\n' "$access_key" "$secret_key" "$session_token"
}

profile_header() {
  local profile=$1 config=${2:-0}
  if [ "$config" = "1" ] && [ "$profile" != "default" ]; then
    printf 'profile %s\n' "$profile"
  else
    printf '%s\n' "$profile"
  fi
}

remove_profile_section() {
  local file=$1 header=$2 tmp
  tmp="$file.tmp.$$"
  awk -v target="[$header]" '
    /^\[/ {
      skip = ($0 == target)
    }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

write_profile() {
  local profile=$1 region=$2 access_key=$3 secret_key=$4 session_token=${5:-}
  local credentials config cred_header config_header
  credentials=$(aws_credentials_file)
  config=$(aws_config_file)
  ensure_aws_file "$credentials"
  ensure_aws_file "$config"
  cred_header=$(profile_header "$profile" 0)
  config_header=$(profile_header "$profile" 1)
  remove_profile_section "$credentials" "$cred_header"
  remove_profile_section "$config" "$config_header"
  {
    printf '[%s]\n' "$cred_header"
    printf 'aws_access_key_id = %s\n' "$access_key"
    printf 'aws_secret_access_key = %s\n' "$secret_key"
    [ -n "$session_token" ] && printf 'aws_session_token = %s\n' "$session_token"
    printf '\n'
  } >> "$credentials"
  {
    printf '[%s]\n' "$config_header"
    printf 'region = %s\n' "$region"
    printf 'output = json\n\n'
  } >> "$config"
  chmod 600 "$credentials" "$config" 2>/dev/null || true
}

verify_env_identity() {
  local access_key=$1 secret_key=$2 session_token=${3:-} arn
  arn=$(AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" AWS_SESSION_TOKEN="$session_token" aws_identity_arn)
  [ -n "$arn" ] && [ "$arn" != "None" ] || {
    echo "AWS credentials could not be verified with sts get-caller-identity" >&2
    return 1
  }
  printf '%s\n' "$arn"
}

verify_profile() {
  local profile=$1 arn root_identity=false
  arn=$(AWS_PROFILE="$profile" aws_identity_arn)
  [ -n "$arn" ] && [ "$arn" != "None" ] || {
    echo "AWS profile could not be verified with sts get-caller-identity: $profile" >&2
    return 1
  }
  aws_arn_is_root "$arn" && root_identity=true
  printf 'AWS identity verified: profile=%s root=%s arn=%s\n' "$profile" "$root_identity" "$(aws_redact_arn "$arn")"
}

cmd_import_csv() {
  local csv=${1:-} profile=${2:-direxio-deployer} region=${3:-${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}}
  local access_key secret_key session_token arn root_identity=false
  [ -n "$csv" ] || {
    usage
    return 1
  }
  IFS=$'\t' read -r access_key secret_key session_token < <(read_csv_credentials "$csv")
  arn=$(verify_env_identity "$access_key" "$secret_key" "$session_token")
  aws_arn_is_root "$arn" && root_identity=true
  write_profile "$profile" "$region" "$access_key" "$secret_key" "$session_token"
  printf 'AWS credentials imported: profile=%s region=%s root=%s arn=%s\n' "$profile" "$region" "$root_identity" "$(aws_redact_arn "$arn")"
  printf 'Credentials file: %s (0600)\n' "$(aws_credentials_file)"
  printf 'Config file: %s (0600)\n' "$(aws_config_file)"
}

case "${1:-}" in
  import-csv)
    shift
    cmd_import_csv "$@"
    ;;
  verify)
    shift
    verify_profile "${1:-${AWS_PROFILE:-direxio-deployer}}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
