#!/usr/bin/env bash
# lib/aws.sh - shared AWS setup sourced by phases.
#
# Some local proxy setups truncate AWS API TLS (UNEXPECTED_EOF). Bypass proxies
# for AWS endpoints in every phase that calls aws.

AWS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$AWS_LIB_DIR/json.sh"

aws_env_prep() {
  local region=${AWS_DEFAULT_REGION:-${AWS_REGION:-}}
  if [ -n "${STATE_JSON:-}" ] && [ -f "$STATE_JSON" ]; then
    local state_region
    state_region=$(json_get "$STATE_JSON" region 2>/dev/null || true)
    [ -n "$state_region" ] && region="$state_region"
  fi
  if [ -z "$region" ]; then
    region=$(aws_configured_region)
  fi
  [ -n "$region" ] && export AWS_DEFAULT_REGION="$region"
  export NO_PROXY="*"; export no_proxy="*"
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy 2>/dev/null || true
}

aws_configured_region() {
  if [ -n "${AWS_PROFILE:-}" ]; then
    aws configure get region --profile "$AWS_PROFILE" 2>/dev/null || true
  else
    aws configure get region 2>/dev/null || true
  fi
}

aws_identity_arn() {
  aws sts get-caller-identity --query Arn --output text 2>/dev/null || true
}

aws_identity_account() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null || true
}

aws_arn_is_root() {
  case "$1" in
    arn:aws*:iam::*:root) return 0 ;;
    *) return 1 ;;
  esac
}

aws_redact_arn() {
  printf '%s\n' "$1" | sed -E 's/::[0-9]{12}:/::<account>:/'
}

# EC2 vCPU quota code: Running On-Demand Standard instances.
EC2_STD_QUOTA_CODE="L-1216C47A"

# EC2-VPC Elastic IP addresses per region.
EC2_VPC_EIP_QUOTA_CODE="L-0263D0A3"

# Dynamically resolve the latest Ubuntu 24.04 amd64 AMI; never hard-code AMI IDs.
aws_lookup_ubuntu_ami() {
  local ami
  ami=$(aws ssm get-parameters \
    --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query 'Parameters[0].Value' --output text 2>/dev/null || true)
  if [ -n "$ami" ] && [ "$ami" != "None" ]; then
    echo "$ami"
    return 0
  fi

  # Some AWS CLI environments return an empty SSM public parameter result.
  # Fall back to Canonical's official owner and select the newest Noble image.
  aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
      'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
      'Name=architecture,Values=x86_64' \
      'Name=virtualization-type,Values=hvm' \
      'Name=root-device-type,Values=ebs' \
    --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' --output text 2>/dev/null || echo "None"
}
