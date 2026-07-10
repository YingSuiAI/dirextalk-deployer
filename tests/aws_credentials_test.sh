#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
mkdir -p "$HOME"

fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"

case "${1:-} ${2:-}" in
  "configure get")
    exit 1
    ;;
  "sts get-caller-identity")
    profile=${AWS_PROFILE:-}
    key=${AWS_ACCESS_KEY_ID:-}
    if [ "$profile" = "root-profile" ] || [ "$key" = "AKIAROOTTEST" ]; then
      arn="arn:aws:iam::123456789012:root"
      account="123456789012"
    else
      arn="arn:aws:iam::123456789012:user/DirextalkDeployer-20260628"
      account="123456789012"
    fi
    case "$*" in
      *"--query Arn"*) printf '%s\n' "$arn" ;;
      *"--query Account"*) printf '%s\n' "$account" ;;
      *) printf '{"Account":"%s","Arn":"%s"}\n' "$account" "$arn" ;;
    esac
    ;;
  *)
    echo "unexpected aws call: $*" >&2
    exit 2
    ;;
esac
EOF
chmod 700 "$fakebin/aws"

CALLS="$tmp/aws.calls"
export CALLS
export PATH="$fakebin:$PATH"
export AWS_SHARED_CREDENTIALS_FILE="$tmp/aws/credentials"
export AWS_CONFIG_FILE="$tmp/aws/config"

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

cat > "$tmp/dirextalk.csv" <<'CSV'
User name,Access key ID,Secret access key
DirextalkDeployer-20260628,AKIADIREXTALKTEST,SECRET_DIREXTALK_VALUE
CSV

out=$(bash "$ROOT/scripts/aws-credentials.sh" import-csv "$tmp/dirextalk.csv" dirextalk-deployer ap-southeast-1)

[[ "$out" == *"profile=dirextalk-deployer"* ]]
[[ "$out" == *"arn:aws:iam::<account>:user/DirextalkDeployer-20260628"* ]]
if [[ "$out" == *"AKIADIREXTALKTEST"* || "$out" == *"SECRET_DIREXTALK_VALUE"* ]]; then
  echo "aws-credentials output leaked credential values" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

grep -q '^\[dirextalk-deployer\]$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_access_key_id = AKIADIREXTALKTEST$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_secret_access_key = SECRET_DIREXTALK_VALUE$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^\[profile dirextalk-deployer\]$' "$AWS_CONFIG_FILE"
grep -q '^region = ap-southeast-1$' "$AWS_CONFIG_FILE"

credential_perm=$(file_mode "$AWS_SHARED_CREDENTIALS_FILE")
config_perm=$(file_mode "$AWS_CONFIG_FILE")
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    [[ "$credential_perm" == "600" || "$credential_perm" == "644" ]]
    [[ "$config_perm" == "600" || "$config_perm" == "644" ]]
    ;;
  *)
    [ "$credential_perm" = "600" ]
    [ "$config_perm" = "600" ]
    ;;
esac

verify_out=$(AWS_PROFILE=dirextalk-deployer bash "$ROOT/scripts/aws-credentials.sh" verify dirextalk-deployer)
[[ "$verify_out" == *"profile=dirextalk-deployer"* ]]
[[ "$verify_out" == *"root=false"* ]]

cat > "$tmp/root.csv" <<'CSV'
Access key ID,Secret access key
AKIAROOTTEST,SECRET_ROOT_VALUE
CSV

root_out=$(bash "$ROOT/scripts/aws-credentials.sh" import-csv "$tmp/root.csv" root-profile us-east-1)
[[ "$root_out" == *"profile=root-profile"* ]]
[[ "$root_out" == *"root=true"* ]]
if [[ "$root_out" == *"AKIAROOTTEST"* || "$root_out" == *"SECRET_ROOT_VALUE"* ]]; then
  echo "aws-credentials root output leaked credential values" >&2
  printf '%s\n' "$root_out" >&2
  exit 1
fi
grep -q '^\[root-profile\]$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_access_key_id = AKIAROOTTEST$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_secret_access_key = SECRET_ROOT_VALUE$' "$AWS_SHARED_CREDENTIALS_FILE"

root_verify_out=$(AWS_PROFILE=root-profile bash "$ROOT/scripts/aws-credentials.sh" verify root-profile)
[[ "$root_verify_out" == *"profile=root-profile"* ]]
[[ "$root_verify_out" == *"root=true"* ]]

printf '\xef\xbb\xbfAccess key ID,Secret access key\nAKIABOMTEST,SECRET_BOM_VALUE\n' > "$tmp/bom.csv"
bom_out=$(bash "$ROOT/scripts/aws-credentials.sh" import-csv "$tmp/bom.csv" bom-profile us-west-2)
[[ "$bom_out" == *"profile=bom-profile"* ]]
if [[ "$bom_out" == *"AKIABOMTEST"* || "$bom_out" == *"SECRET_BOM_VALUE"* ]]; then
  echo "aws-credentials BOM output leaked credential values" >&2
  printf '%s\n' "$bom_out" >&2
  exit 1
fi
grep -q '^\[bom-profile\]$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_access_key_id = AKIABOMTEST$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_secret_access_key = SECRET_BOM_VALUE$' "$AWS_SHARED_CREDENTIALS_FILE"

set +e
s0_output=$(
  DIREXTALK_WORKDIR="$tmp/state-root" AWS_PROFILE=root-profile bash -c '
    set -uo pipefail
    cd "$1"
    source scripts/lib/state.sh
    state_init >/dev/null 2>&1
    source scripts/lib/aws.sh
    source scripts/phases/s0_prereq_aws.sh
    run_phase
  ' _ "$ROOT" 2>&1
)
s0_rc=$?
set -e
[ "$s0_rc" -eq 0 ]
[[ "$s0_output" == *"AWS credentials are valid"* ]]

echo "aws credentials ok"
