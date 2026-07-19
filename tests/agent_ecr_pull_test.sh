#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
export DIREXTALK_WORKDIR="$tmp/work"
export AWS_DEFAULT_REGION=ap-northeast-3
export CALLS="$tmp/aws.calls"
export POLICY_CAPTURE="$tmp/session-policy.json"
export FAKE_CALLER_ACCOUNT=123456789012
export FAKE_CALLER_ARN=arn:aws:iam::123456789012:root
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin"
: > "$CALLS"

cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    case "$*" in
      *"--query Account"*) printf '%s\n' "$FAKE_CALLER_ACCOUNT" ;;
      *"--query Arn"*) printf '%s\n' "$FAKE_CALLER_ARN" ;;
      *) printf '{"Account":"%s","Arn":"%s"}\n' "$FAKE_CALLER_ACCOUNT" "$FAKE_CALLER_ARN" ;;
    esac
    ;;
  "sts get-federation-token")
    policy=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --policy) policy=${2#file://}; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "$policy" "$POLICY_CAPTURE"
    printf '%s\n' '{"Version":1,"AccessKeyId":"TESTSESSIONACCESS","SecretAccessKey":"TESTSESSIONSECRET","SessionToken":"TESTSESSIONTOKEN","Expiration":"2030-01-01T00:00:00Z"}'
    ;;
  "ecr get-login-password")
    [ -f "$AWS_CONFIG_FILE" ] && [ ! -s "$AWS_CONFIG_FILE" ]
    [ -f "$AWS_SHARED_CREDENTIALS_FILE" ]
    grep -q 'aws_access_key_id = TESTSESSIONACCESS' "$AWS_SHARED_CREDENTIALS_FILE"
    grep -q 'aws_secret_access_key = TESTSESSIONSECRET' "$AWS_SHARED_CREDENTIALS_FILE"
    grep -q 'aws_session_token = TESTSESSIONTOKEN' "$AWS_SHARED_CREDENTIALS_FILE"
    printf '%s\n' 'test-only-ecr-password'
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod 0700 "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set region ap-northeast-3
state_set run_id ecr-pull-test

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/agent-ecr-pull.sh"
[ "$AGENT_ECR_ASSUME_ROLE_DURATION_SECONDS" = 3600 ]
_agent_ecr_canonical_ipv4 203.0.113.44
if _agent_ecr_canonical_ipv4 999.0.0.1; then
  echo "ECR cleanup accepted a non-canonical public IP" >&2
  exit 1
fi

image='123456789012.dkr.ecr.ap-northeast-3.amazonaws.com/dirextalk-agent:v0.1.0-alpha.20260718.1-abcdef123456@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
agent_ecr_prepare_state "$image"
json_test_check "$STATE_JSON" "data.agent_registry.source === 'private_ecr' && data.agent_registry.account_id === '123456789012' && data.agent_registry.region === 'ap-northeast-3' && data.agent_registry.registry === '123456789012.dkr.ecr.ap-northeast-3.amazonaws.com' && data.agent_registry.repository === 'dirextalk-agent' && data.agent_registry.repository_arn === 'arn:aws:ecr:ap-northeast-3:123456789012:repository/dirextalk-agent' && data.agent_registry.auth_mode === 'federation_token' && data.agent_registry.pull_role_arn === ''"

if agent_ecr_prepare_state '123456789012.dkr.ecr.ap-northeast-3.amazonaws.com/other:v0.1.0-alpha.1-abcdef1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1; then
  echo "private Agent image must use the fixed dirextalk-agent repository" >&2
  exit 1
fi
if agent_ecr_prepare_state '999999999999.dkr.ecr.ap-northeast-3.amazonaws.com/dirextalk-agent:v0.1.0-alpha.1-abcdef1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1; then
  echo "private Agent image must use the confirmed caller account" >&2
  exit 1
fi
if agent_ecr_prepare_state '123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/dirextalk-agent:v0.1.0-alpha.1-abcdef1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1; then
  echo "private Agent image must use the deployment region" >&2
  exit 1
fi

password=$(agent_ecr_stream_login_password)
[ "$password" = test-only-ecr-password ]
grep -q 'sts get-federation-token' "$CALLS"
grep -q -- '--name dirextalk-agent-pull' "$CALLS"
grep -q -- '--duration-seconds 3600' "$CALLS"
grep -q 'ecr get-login-password.*--region ap-northeast-3' "$CALLS"
json_test_check "$POLICY_CAPTURE" "data.Version === '2012-10-17' && data.Statement.some(s => s.Effect === 'Allow' && s.Resource === '*' && s.Action.includes('ecr:GetAuthorizationToken')) && data.Statement.some(s => s.Effect === 'Allow' && s.Resource === 'arn:aws:ecr:ap-northeast-3:123456789012:repository/dirextalk-agent' && s.Action.includes('ecr:BatchCheckLayerAvailability') && s.Action.includes('ecr:BatchGetImage') && s.Action.includes('ecr:GetDownloadUrlForLayer'))"
if grep -Eq 'TESTSESSION(ACCESS|SECRET|TOKEN)|test-only-ecr-password' "$CALLS" "$STATE_JSON"; then
  echo "temporary STS or ECR credentials leaked into calls/state" >&2
  exit 1
fi
if find "$DIREXTALK_WORKDIR" -maxdepth 1 -name '.agent-ecr-auth.*' -print -quit | grep -q .; then
  echo "temporary ECR credential transport residue remains" >&2
  exit 1
fi

export FAKE_CALLER_ARN=arn:aws:sts::123456789012:assumed-role/ExistingSession/test
if agent_ecr_auth_mode_for_caller "$FAKE_CALLER_ACCOUNT" "$FAKE_CALLER_ARN" '' >/dev/null 2>&1; then
  echo "an assumed-role caller must fail closed without an explicit same-account pull role" >&2
  exit 1
fi
[ "$(agent_ecr_auth_mode_for_caller "$FAKE_CALLER_ACCOUNT" "$FAKE_CALLER_ARN" 'arn:aws:iam::123456789012:role/DirextalkAgentEcrPull')" = assume_role ]
if agent_ecr_auth_mode_for_caller "$FAKE_CALLER_ACCOUNT" "$FAKE_CALLER_ARN" 'arn:aws:iam::999999999999:role/DirextalkAgentEcrPull' >/dev/null 2>&1; then
  echo "cross-account pull roles must be rejected" >&2
  exit 1
fi

echo "Agent private ECR pull contract ok"
