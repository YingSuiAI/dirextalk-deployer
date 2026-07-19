#!/usr/bin/env bash
# S0 PREREQ_AWS - validate that AWS credentials are usable.
#
# User-side AWS account/IAM/key setup is documented in references/user-journey.md.
# This phase only validates credentials and reports actionable blockers.

_print_aws_onboarding_guide() {
  warn "First question: do you already have an AWS account with an access-key CSV or configured AWS profile?"
  warn "  If no AWS account exists yet:"
  warn "    1. Open https://aws.amazon.com/ and create an account with email, phone verification, billing card, and the Basic support plan."
  warn "    2. Wait until the account is fully activated, then open the AWS Billing Console and create an AWS Budget or billing alert."
  warn "    3. Create credentials: fastest is a root access key CSV for the first deployment; safer is an IAM user named DirextalkDeployer with AdministratorAccess."
  warn "    4. Download the access-key CSV once, store it securely, and never paste the key values into chat or commits."
  warn "  If you already have the CSV:"
  warn "    bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer <region>"
  warn "    export AWS_PROFILE=dirextalk-deployer"
  warn "    bash scripts/aws-credentials.sh verify dirextalk-deployer"
}

run_phase() {
  aws_env_prep

  # STS is the source of truth and supports env keys, AWS_PROFILE, instance roles, SSO, etc.
  phase_set S0_PREREQ_AWS in_progress "validating AWS credentials"
  local acct arn
  arn=$(aws_identity_arn)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    local root_identity=false
    aws_arn_is_root "$arn" && root_identity=true
    acct=$(aws_identity_account)
    state_set region "${AWS_DEFAULT_REGION:-$(state_get region)}"
    phase_set S0_PREREQ_AWS done "sts ok account=$acct profile=${AWS_PROFILE:-<env/ak>} root=$root_identity arn=$(aws_redact_arn "$arn") region=${AWS_DEFAULT_REGION:-$(state_get region)}"
    ok "AWS credentials are valid (account=$acct${AWS_PROFILE:+, profile=$AWS_PROFILE}, root=$root_identity, arn=$(aws_redact_arn "$arn"))."
    return 0
  fi

  # Distinguish missing credentials from invalid/not-yet-active credentials.
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_PROFILE:-}" ]; then
    phase_set S0_PREREQ_AWS waiting_user "no usable AWS credentials (no env keys or AWS_PROFILE)"
    warn "No usable AWS credentials found. Choose one:"
    warn "  1. Configure a deployment access key, then export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=..."
    warn "  2. Or use an existing profile: export AWS_PROFILE=<your-profile>"
    _print_aws_onboarding_guide
    return 2
  fi

  phase_set S0_PREREQ_AWS waiting_user "sts failed (invalid credentials, not active yet, or proxy/TLS issue)"
  warn "AWS credential validation failed (profile=${AWS_PROFILE:-<env/ak>}). Possible causes:"
  warn "  1. AK/SK or profile is incorrect."
  warn "  2. Newly created credentials are not active yet; wait a few minutes."
  warn "  3. Local proxy/network is breaking TLS; AWS proxy bypass is already attempted."
  _print_aws_onboarding_guide
  return 2
}
