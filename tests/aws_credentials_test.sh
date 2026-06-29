#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
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
      arn="arn:aws:iam::123456789012:user/DirexioDeployer-20260628"
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

cat > "$tmp/direxio.csv" <<'CSV'
User name,Access key ID,Secret access key
DirexioDeployer-20260628,AKIADIREXIOTEST,SECRET_DIREXIO_VALUE
CSV

out=$(bash "$ROOT/scripts/aws-credentials.sh" import-csv "$tmp/direxio.csv" direxio-deployer ap-southeast-1)

[[ "$out" == *"profile=direxio-deployer"* ]]
[[ "$out" == *"arn:aws:iam::<account>:user/DirexioDeployer-20260628"* ]]
if [[ "$out" == *"AKIADIREXIOTEST"* || "$out" == *"SECRET_DIREXIO_VALUE"* ]]; then
  echo "aws-credentials output leaked credential values" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

grep -q '^\[direxio-deployer\]$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_access_key_id = AKIADIREXIOTEST$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^aws_secret_access_key = SECRET_DIREXIO_VALUE$' "$AWS_SHARED_CREDENTIALS_FILE"
grep -q '^\[profile direxio-deployer\]$' "$AWS_CONFIG_FILE"
grep -q '^region = ap-southeast-1$' "$AWS_CONFIG_FILE"

credential_perm=$(file_mode "$AWS_SHARED_CREDENTIALS_FILE")
config_perm=$(file_mode "$AWS_CONFIG_FILE")
[ "$credential_perm" = "600" ]
[ "$config_perm" = "600" ]

verify_out=$(AWS_PROFILE=direxio-deployer bash "$ROOT/scripts/aws-credentials.sh" verify direxio-deployer)
[[ "$verify_out" == *"profile=direxio-deployer"* ]]
[[ "$verify_out" == *"root=false"* ]]

cat > "$tmp/root.csv" <<'CSV'
Access key ID,Secret access key
AKIAROOTTEST,SECRET_ROOT_VALUE
CSV

if bash "$ROOT/scripts/aws-credentials.sh" import-csv "$tmp/root.csv" root-profile us-east-1 >"$tmp/root.out" 2>"$tmp/root.err"; then
  echo "root CSV import should fail" >&2
  exit 1
fi
grep -q 'root AWS access key is not allowed' "$tmp/root.err"
if grep -q 'SECRET_ROOT_VALUE\|AKIAROOTTEST' "$AWS_SHARED_CREDENTIALS_FILE" 2>/dev/null; then
  echo "root credential should not be written to credentials file" >&2
  cat "$AWS_SHARED_CREDENTIALS_FILE" >&2
  exit 1
fi

set +e
s0_output=$(
  P2P_WORKDIR="$tmp/state-root" AWS_PROFILE=root-profile bash -c '
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
[ "$s0_rc" -eq 2 ]
[[ "$s0_output" == *"Root AWS access keys are not allowed"* ]]

echo "aws credentials ok"
