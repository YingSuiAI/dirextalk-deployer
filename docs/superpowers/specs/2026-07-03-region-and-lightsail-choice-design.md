# Region Recommendation And Lightsail Choice Design

## Problem

Direxio deployer currently defaults region selection too weakly and handles an
unavailable Lightsail region too aggressively. If the selected region has no
usable Lightsail bundle or availability zone, S1 automatically changes the
deployment to EC2 when the operator did not explicitly force Lightsail.

That behavior is risky because Lightsail and EC2 both have common per-region
instance limits on new AWS accounts, and EC2 has a different billing shape. The
operator should see the EC2 estimate and choose EC2 explicitly, or choose a
different Lightsail-capable region or zone.

## Goals

- Recommend a default AWS region from the local host timezone when no region is
  supplied by state, environment, or AWS profile.
- Use that recommendation in both interactive and non-interactive deployment
  runs.
- Stop automatic Lightsail-to-EC2 fallback before provisioning.
- When Lightsail is unavailable in the selected region, record availability
  details, record an EC2 cost estimate, and wait for user choice.
- Keep EC2 supported as an explicit path through `DIREXIO_CLOUD_PROVIDER=ec2`.
- Keep docs, tests, and agent-facing instructions aligned.

## Non-Goals

- Do not query AWS Free Tier, credit usage, or account-specific billing
  eligibility.
- Do not preserve the legacy auto-EC2 fallback behavior.
- Do not build a full geolocation service. Timezone-based region selection is a
  local heuristic and must be explainable in state and logs.

## Design

### Region Recommendation

Add a shared Bash helper for region recommendation. Region resolution should
follow this order:

1. Existing `state.region`.
2. `AWS_DEFAULT_REGION` or `AWS_REGION`.
3. AWS profile configured region.
4. `DIREXIO_DEFAULT_REGION`, for explicit local preference.
5. Timezone-derived recommendation.

The timezone-derived recommendation should inspect `TZ`, `/etc/timezone`,
`timedatectl`, or the current numeric UTC offset where available. It should
return a stable AWS region and a short reason string. For `Asia/Shanghai` and
UTC+8-style offsets, recommend an Asia Pacific region instead of a US region.

`ensure_region_selected` should write both `region` and a recommendation record
to `state.json` when it selects a region automatically. In interactive runs, it
may still display the recommendation as the default prompt value. In
non-interactive runs, it should use the recommendation directly instead of
blocking.

### Lightsail Availability

S1 keeps Lightsail as the default provider. It continues checking bundles and
availability zones before provisioning. If the default zone is unavailable but
another zone in the same region is available, S1 may select the available
Lightsail zone automatically because the provider and billing class remain
Lightsail.

If no usable Lightsail bundle or no Lightsail availability zone exists in the
selected region, S1 must:

- Leave `cloud_provider=lightsail` unless the operator explicitly selected EC2.
- Record `resources.lightsail_availability_status=unavailable` and the available
  and unavailable zone lists when AWS returns them.
- Record `cloud_recommendation` with `selected_provider=lightsail`,
  `recommended_provider=lightsail`, and an action-required reason.
- Record an EC2 estimate for the same region, default `t3.small`, and the
  current domain mode.
- Set `S1_PREFLIGHT` to `waiting_user`.
- Print clear continuation commands:
  - choose another AWS region for Lightsail;
  - or set `DIREXIO_CLOUD_PROVIDER=ec2` after reviewing the EC2 estimate.

S1 should not call EC2 preflight checks merely because Lightsail is unavailable.
EC2 VPC, quota, EIP, and AMI checks should run only when EC2 is explicitly
selected.

### Cost Estimate

Existing `scripts/pricing-estimate.sh` remains the source for EC2 estimates.
S1 can call it with `--region`, `--cloud-provider ec2`, `--instance-type
t3.small`, and `--domain-mode`. The estimate should be stored under a distinct
state field such as `cloud_recommendation.ec2_cost_estimate` so it does not
replace the active Lightsail `cost_estimate` unless the operator selects EC2.

### Documentation

Update `README.md`, `README_zh.md`, `SKILL.md`, and
`references/deployment-workflow.md`:

- Default region is recommended from local timezone when unspecified.
- Non-interactive runs use that recommendation unless an explicit region is set.
- Lightsail unavailability does not automatically switch to EC2.
- EC2 requires explicit selection after reviewing estimated cost.
- Region and zone alternatives are preferred before EC2 for default deployments.

## Testing

- Replace the current S1 Lightsail availability fallback test with a waiting-user
  test that verifies no EC2 APIs are called and an EC2 estimate is recorded.
- Add a region recommendation test for an Asia/Shanghai or UTC+8 environment.
- Keep existing S3 Lightsail zone-selection test: when another Lightsail zone in
  the same region is available, selecting it automatically remains valid.
- Run focused validation:
  - `bash tests/skill_structure_test.sh`
  - `bash tests/s1_lightsail_availability_fallback_test.sh`
  - `bash tests/s3_lightsail_provision_test.sh`
  - `bash tests/pricing_estimate_test.sh`
  - `git diff --check`

## Open Assumptions

- For China/UTC+8 hosts, a nearby AWS Asia Pacific region is better than a US
  default. The exact region can be adjusted by `DIREXIO_DEFAULT_REGION`,
  `AWS_DEFAULT_REGION`, or AWS profile region.
- Lightsail zone selection inside the same region is not considered a provider
  fallback and may remain automatic.
