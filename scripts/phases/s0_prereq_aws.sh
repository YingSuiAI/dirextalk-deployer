#!/usr/bin/env bash
# S0 PREREQ_AWS - validate that AWS credentials are usable.
#
# User-side AWS account/IAM/key setup is documented in references/user-journey.md.
# This phase only validates credentials and reports actionable blockers.

run_phase() {
  aws_env_prep

  # STS is the source of truth and supports env keys, AWS_PROFILE, instance roles, SSO, etc.
  phase_set S0_PREREQ_AWS in_progress "validating AWS credentials"
  local acct arn
  arn=$(aws_identity_arn)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    if aws_arn_is_root "$arn"; then
      phase_set S0_PREREQ_AWS waiting_user "root AWS identity is not allowed"
      warn "Root AWS access keys are not allowed for deployment."
      warn "Create or use a temporary non-root DirexioDeployer IAM user/profile, then rerun."
      return 2
    fi
    acct=$(aws_identity_account)
    state_set region "${AWS_DEFAULT_REGION:-$(state_get region)}"
    phase_set S0_PREREQ_AWS done "sts ok account=$acct profile=${AWS_PROFILE:-<env/ak>} arn=$(aws_redact_arn "$arn") region=${AWS_DEFAULT_REGION:-$(state_get region)}"
    ok "AWS credentials are valid (account=$acct${AWS_PROFILE:+, profile=$AWS_PROFILE}, arn=$(aws_redact_arn "$arn"))."
    return 0
  fi

  # Distinguish missing credentials from invalid/not-yet-active credentials.
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_PROFILE:-}" ]; then
    phase_set S0_PREREQ_AWS waiting_user "no usable AWS credentials (no env keys or AWS_PROFILE)"
    warn "No usable AWS credentials found. Choose one:"
    warn "  1. Configure a temporary non-root DirexioDeployer IAM user key, then export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=..."
    warn "  2. Or use an existing non-root profile: export AWS_PROFILE=<your-profile>"
    return 2
  fi

  phase_set S0_PREREQ_AWS waiting_user "sts failed (invalid credentials, not active yet, or proxy/TLS issue)"
  warn "AWS credential validation failed (profile=${AWS_PROFILE:-<env/ak>}). Possible causes:"
  warn "  1. AK/SK or profile is incorrect."
  warn "  2. Newly created credentials are not active yet; wait a few minutes."
  warn "  3. Local proxy/network is breaking TLS; AWS proxy bypass is already attempted."
  return 2
}
