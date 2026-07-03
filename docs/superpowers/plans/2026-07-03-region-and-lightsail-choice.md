# Region And Lightsail Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unspecified AWS regions timezone-recommended and require explicit user choice before switching from unavailable Lightsail to EC2.

**Architecture:** Add a focused Bash region helper and keep region resolution in `scripts/orchestrate.sh`. Keep provider selection in S1, but replace automatic Lightsail-to-EC2 fallback with a waiting-user branch that records an EC2 estimate under `cloud_recommendation.ec2_cost_estimate`.

**Tech Stack:** Bash state-machine phases, AWS CLI, Node-backed JSON helper, shell tests.

---

## File Structure

- Create `scripts/lib/region.sh`: timezone detection and default AWS region recommendation.
- Modify `scripts/orchestrate.sh`: source the helper and use it in `ensure_region_selected`.
- Modify `scripts/phases/s1_preflight.sh`: remove automatic EC2 fallback, record user-choice guidance and EC2 estimate.
- Modify `tests/s1_lightsail_availability_fallback_test.sh`: change expected behavior to waiting-user with no EC2 API calls.
- Create `tests/region_recommendation_test.sh`: cover timezone-derived non-interactive region selection.
- Modify `tests/skill_structure_test.sh`: include the new test and updated documentation expectations.
- Modify `README.md`, `README_zh.md`, `SKILL.md`, and `references/deployment-workflow.md`: align published deployment contract.

### Task 1: Region Helper

**Files:**
- Create: `scripts/lib/region.sh`
- Test: `tests/region_recommendation_test.sh`

- [x] **Step 1: Write the failing test**

Create `tests/region_recommendation_test.sh` with a fake AWS CLI that returns no configured region and `TZ=Asia/Shanghai`. Source `scripts/orchestrate.sh` dependencies enough to call `state_init` and `ensure_region_selected`, then assert `state.region` is an Asia Pacific recommendation and `region_recommendation.source === "timezone"`.

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/region_recommendation_test.sh`
Expected: FAIL because `scripts/lib/region.sh` does not exist or `ensure_region_selected` still blocks/uses no recommendation.

- [x] **Step 3: Implement the helper**

Create `scripts/lib/region.sh` with:

```bash
direxio_timezone_name() {
  if [ -n "${TZ:-}" ]; then printf '%s\n' "$TZ"; return 0; fi
  if [ -f /etc/timezone ]; then sed -n '1p' /etc/timezone; return 0; fi
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl 2>/dev/null | sed -nE 's/^[[:space:]]*Time zone:[[:space:]]*([^[:space:]]+).*/\1/p' | sed -n '1p'
  fi
}

direxio_utc_offset_hours() {
  date +%z 2>/dev/null | awk '
    /^[+-][0-9][0-9][0-9][0-9]$/ {
      sign=substr($0,1,1); h=substr($0,2,2)+0; m=substr($0,4,2)+0;
      v=h+(m/60); if (sign=="-") v=-v; printf "%.2f\n", v
    }'
}

direxio_recommend_region() {
  local tz offset region reason
  tz=$(direxio_timezone_name)
  offset=$(direxio_utc_offset_hours)
  case "$tz" in
    Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Urumqi|Asia/Hong_Kong|Asia/Macau|Asia/Taipei)
      region=ap-east-1; reason="timezone $tz maps to Asia Pacific (Hong Kong)" ;;
    Asia/Tokyo) region=ap-northeast-1; reason="timezone $tz maps to Asia Pacific (Tokyo)" ;;
    Asia/Seoul) region=ap-northeast-2; reason="timezone $tz maps to Asia Pacific (Seoul)" ;;
    Asia/Singapore|Asia/Kuala_Lumpur|Asia/Manila) region=ap-southeast-1; reason="timezone $tz maps to Asia Pacific (Singapore)" ;;
    Asia/Bangkok|Asia/Jakarta|Asia/Ho_Chi_Minh) region=ap-southeast-1; reason="timezone $tz maps to Asia Pacific (Singapore)" ;;
    Australia/*|Pacific/Auckland) region=ap-southeast-2; reason="timezone $tz maps to Asia Pacific (Sydney)" ;;
    Europe/*|Africa/*) region=eu-central-1; reason="timezone $tz maps to EU (Frankfurt)" ;;
    America/Los_Angeles|America/Vancouver|America/Tijuana) region=us-west-2; reason="timezone $tz maps to US West (Oregon)" ;;
    America/New_York|America/Toronto|America/Detroit) region=us-east-1; reason="timezone $tz maps to US East (N. Virginia)" ;;
  esac
  if [ -z "$region" ] && [ -n "$offset" ]; then
    if awk -v o="$offset" 'BEGIN{exit !(o >= 7 && o <= 9)}'; then
      region=ap-east-1; reason="UTC offset $offset maps to Asia Pacific (Hong Kong)"
    elif awk -v o="$offset" 'BEGIN{exit !(o >= -8 && o <= -5)}'; then
      region=us-east-1; reason="UTC offset $offset maps to US East (N. Virginia)"
    else
      region=us-east-1; reason="UTC offset $offset has no specific mapping; using US East (N. Virginia)"
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "${region:-us-east-1}" "${tz:-unknown}" "${offset:-unknown}" "${reason:-no timezone data; using US East (N. Virginia)}"
}
```

- [x] **Step 4: Wire region selection**

Source `scripts/lib/region.sh` from `scripts/orchestrate.sh`. In `ensure_region_selected`, after state/env/profile checks and `DIREXIO_DEFAULT_REGION`, call `direxio_recommend_region`, set `region`, and write:

```bash
state_set_object region_recommendation \
  source=timezone \
  "region=$region" \
  "timezone=$tz" \
  "utc_offset_hours=$offset" \
  "reason=$reason"
```

For `DIREXIO_DEFAULT_REGION`, write `source=env`. For env/profile/state regions, avoid replacing an existing recommendation unless this run selected the region.

- [x] **Step 5: Run the test to verify it passes**

Run: `bash tests/region_recommendation_test.sh`
Expected: PASS and `region recommendation ok`.

### Task 2: Stop Automatic EC2 Fallback

**Files:**
- Modify: `scripts/phases/s1_preflight.sh`
- Modify: `tests/s1_lightsail_availability_fallback_test.sh`

- [x] **Step 1: Update the failing test**

Change the test fake AWS CLI so any `ec2 ...`, `service-quotas ...`, or `ssm ...` command fails. Run `run_phase`, expect exit code `2`, and assert:

```javascript
data.cloud_provider === 'lightsail' &&
data.cloud_recommendation.selected_provider === 'lightsail' &&
data.cloud_recommendation.recommended_provider === 'lightsail' &&
data.cloud_recommendation.ec2_cost_estimate.provider === 'ec2' &&
data.resources.lightsail_availability_status === 'unavailable' &&
data.phases.S1_PREFLIGHT.status === 'waiting_user'
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/s1_lightsail_availability_fallback_test.sh`
Expected: FAIL because current S1 auto-selects EC2 and calls EC2 APIs.

- [x] **Step 3: Implement waiting-user branch**

In `scripts/phases/s1_preflight.sh`, replace the `_cloud_provider_allows_availability_fallback` branch with `_wait_for_lightsail_or_ec2_choice`. The new function should:

```bash
_wait_for_lightsail_or_ec2_choice() {
  local region domain_mode estimate rc=0
  region=$(state_get region)
  domain_mode=$(state_get domain_mode)
  domain_mode=${domain_mode:-user}
  _record_cloud_recommendation lightsail "lightsail_unavailable"
  if estimate=$(bash "$S1_PHASE_DIR/../pricing-estimate.sh" --region "$region" --cloud-provider ec2 --instance-type "$DEFAULT_EC2_INSTANCE_TYPE" --disk-gb "${DIREXIO_ROOT_VOLUME_GB:-50}" --domain-mode "$domain_mode" 2>/dev/null); then
    state_set_raw cloud_recommendation.ec2_cost_estimate "$estimate"
  else
    rc=$?
    warn "Could not record EC2 cost estimate automatically; run scripts/pricing-estimate.sh manually before choosing EC2."
  fi
  phase_set S1_PREFLIGHT waiting_user "Lightsail unavailable in $region; waiting for region or explicit EC2 choice"
  warn "Lightsail is unavailable in AWS region $region for this deployment."
  warn "Choose another Lightsail-capable region, or explicitly choose EC2 after reviewing the EC2 estimate."
  warn "Lightsail region option: AWS_DEFAULT_REGION=<region> bash scripts/orchestrate.sh"
  warn "EC2 option: DIREXIO_CLOUD_PROVIDER=ec2 INSTANCE_TYPE=$DEFAULT_EC2_INSTANCE_TYPE bash scripts/orchestrate.sh"
  return 2
}
```

Define `S1_PHASE_DIR` like S3 does so the pricing script path is stable.

- [x] **Step 4: Adjust recommendation reason**

Update `_record_cloud_recommendation` so `cause=lightsail_unavailable` no longer recommends EC2 automatically. It should keep `recommended_provider=lightsail` and explain that the operator must choose another Lightsail region/zone or explicitly select EC2 after reviewing cost.

- [x] **Step 5: Run the test to verify it passes**

Run: `bash tests/s1_lightsail_availability_fallback_test.sh`
Expected: PASS and no EC2 calls in the fake AWS log.

### Task 3: Documentation And Structure Tests

**Files:**
- Modify: `README.md`
- Modify: `README_zh.md`
- Modify: `SKILL.md`
- Modify: `references/deployment-workflow.md`
- Modify: `tests/skill_structure_test.sh`

- [x] **Step 1: Update docs**

Replace statements that say Lightsail unavailability switches the recommendation to EC2. New text must say S1 waits for user choice, records an EC2 estimate, and requires explicit `DIREXIO_CLOUD_PROVIDER=ec2` for EC2.

- [x] **Step 2: Update default-region docs**

Document that if state/env/profile has no region, the deployer recommends a default from local timezone and uses it in non-interactive runs. Include `DIREXIO_DEFAULT_REGION` as an explicit override.

- [x] **Step 3: Update structure test**

Add `tests/region_recommendation_test.sh` to required test files and replace stale grep expectations for automatic EC2 fallback with checks for:

```bash
grep -q 'DIREXIO_DEFAULT_REGION' SKILL.md
grep -q 'timezone' references/deployment-workflow.md
grep -q 'does not automatically switch to EC2' README.md
grep -q '不会自动切换到 EC2' README_zh.md
```

- [x] **Step 4: Run structure test**

Run: `bash tests/skill_structure_test.sh`
Expected: PASS.

### Task 4: Final Verification And Commit

**Files:**
- All modified files.

- [x] **Step 1: Run focused validation**

Run:

```bash
bash tests/skill_structure_test.sh
bash tests/s1_lightsail_availability_fallback_test.sh
bash tests/s3_lightsail_provision_test.sh
bash tests/pricing_estimate_test.sh
git diff --check
```

Expected: all commands pass.

- [x] **Step 2: Run broader syntax checks**

Run:

```bash
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Expected: no syntax errors.

- [x] **Step 3: Review diff**

Run: `git diff --stat` and `git diff -- scripts/phases/s1_preflight.sh scripts/orchestrate.sh scripts/lib/region.sh`.
Expected: changes are scoped to region recommendation and provider choice.

- [x] **Step 4: Commit**

Run:

```bash
git status --short
git add docs/superpowers/plans/2026-07-03-region-and-lightsail-choice.md scripts tests README.md README_zh.md SKILL.md references/deployment-workflow.md
git commit -m "Require explicit EC2 choice when Lightsail unavailable"
```

Expected: commit succeeds with no generated credentials, state, logs, or binaries staged.
