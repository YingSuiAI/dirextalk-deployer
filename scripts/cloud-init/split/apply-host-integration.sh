#!/usr/bin/env bash
# Preflight, stage, reconcile, and atomically commit a split tooling revision.
set -euo pipefail

die() { printf 'host integration apply: %s\n' "$*" >&2; exit 1; }
report_failed_command() {
  local status=$1 line=$2 command=$3
  printf 'host integration apply: command failed at line %s (rc=%s): %s\n' \
    "$line" "$status" "$command" >&2
  return "$status"
}
trap 'report_failed_command "$?" "$LINENO" "$BASH_COMMAND"' ERR

[ "$#" -eq 5 ] || die 'usage: apply-host-integration.sh STAGE SPLIT_BUNDLE DEPLOYMENT_DIR EXPECTED_OLD_REVISION EXPECTED_STABLE_IP'
stage=$1
split_bundle=$2
base=$3
expected_old=$4
expected_stable_ip=$5

[ -d "$stage" ] && [ ! -L "$stage" ] \
  && [ "$(stat -c '%u:%g:%a' -- "$stage")" = 0:0:700 ] \
  || die 'transport staging must be root-owned mode 0700'
stage_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$stage")
[ -f "$split_bundle" ] && [ ! -L "$split_bundle" ] || die 'staged split bundle is unavailable'
bundle_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$split_bundle")
bundle_sha=$(sha256sum -- "$split_bundle" | awk '{print $1}')

authorization="$stage/cloud-init/split/authorize-split-source-revision.sh"
advance="$stage/cloud-init/split/advance-split-source-revision.sh"
release_pin="$stage/cloud-init/split/release.env"
if bash "$authorization" "$advance" "$release_pin" "$base/.env" "$expected_old" "$expected_stable_ip"; then
  :
else
  status=$?
  case "$status" in 3) exit 3 ;; *) exit 1 ;; esac
fi

[ "$(stat -c '%d:%i:%u:%g:%a' -- "$stage")" = "$stage_identity" ] \
  || die 'transport staging identity changed after authorization'
[ "$(stat -c '%d:%i:%u:%g:%a' -- "$split_bundle")" = "$bundle_identity" ] \
  && [ "$(sha256sum -- "$split_bundle" | awk '{print $1}')" = "$bundle_sha" ] \
  || die 'staged split bundle changed after authorization'

read_unique() {
  local file=$1 key=$2 count value
  count=$(awk -F= -v wanted="$key" '$1 == wanted {n++} END {print n+0}' "$file")
  [ "$count" -eq 1 ] || die "$file must contain exactly one $key"
  value=$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0,length(wanted)+2); exit}' "$file")
  [ -n "$value" ] || die "$file contains an empty $key"
  printf '%s' "$value"
}

target_revision=$(read_unique "$release_pin" DIREXTALK_SPLIT_SOURCE_REVISION)
printf '%s\n' "$target_revision" | grep -Eq '^[0-9a-f]{40}$' \
  || die 'release split source revision is invalid'

# Validate archive paths before extraction. The canonical bundle owns exactly
# deploy/split-agent; extracting it into a new same-filesystem tree prevents
# removed files from surviving an update.
archive_list=$(tar -tzf "$split_bundle") || die 'could not list the canonical split bundle'
[ -n "$archive_list" ] || die 'canonical split bundle is empty'
while IFS= read -r entry; do
  case "$entry" in
    deploy|deploy/|deploy/split-agent|deploy/split-agent/|deploy/split-agent/*) ;;
    *) die "canonical split bundle contains an unexpected path: $entry" ;;
  esac
  case "/$entry/" in */../*|*/./*) die "canonical split bundle contains an unsafe path: $entry" ;; esac
done <<<"$archive_list"

[ -d "$base" ] && [ ! -L "$base" ] || die 'deployment directory is unavailable'
transaction=$(mktemp -d "$base/.host-integration.XXXXXX") || die 'could not create host integration transaction'
chmod 0700 "$transaction"
chown 0:0 "$transaction"
transaction_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$transaction")
candidate="$transaction/candidate"
backup="$transaction/backup"
install -d -o root -g root -m 0700 "$candidate" "$backup"

split_swapped=false
ops_swapped=false
updater_swapped=false
service_changed=false
service_existed=false
service_was_enabled=false
forward_only=false
committed=false
host_root=${DIREXTALK_HOST_INTEGRATION_ROOT:-}
recovery_service=$host_root/etc/systemd/system/dirextalk-split-recovery.service

rollback() {
  local status=$?
  trap - EXIT
  if [ "$forward_only" != true ] && [ "$committed" != true ]; then
    if [ "$updater_swapped" = true ]; then
      rm -rf -- "$base/updater"
      [ ! -e "$backup/updater" ] || mv -- "$backup/updater" "$base/updater"
    fi
    if [ "$ops_swapped" = true ]; then
      rm -rf -- "$base/production-ops"
      [ ! -e "$backup/production-ops" ] || mv -- "$backup/production-ops" "$base/production-ops"
    fi
    if [ "$split_swapped" = true ]; then
      rm -rf -- "$base/deploy/split-agent"
      [ ! -e "$backup/split-agent" ] || mv -- "$backup/split-agent" "$base/deploy/split-agent"
    fi
    if [ "$service_changed" = true ]; then
      if [ "$service_was_enabled" != true ]; then
        systemctl disable dirextalk-split-recovery.service >/dev/null 2>&1 || status=1
      fi
      if [ "$service_existed" = true ]; then
        install -o root -g root -m 0644 "$backup/dirextalk-split-recovery.service" "$recovery_service" || status=1
      else
        rm -f -- "$recovery_service" || status=1
      fi
      systemctl daemon-reload >/dev/null 2>&1 || status=1
    fi
  fi
  if [ -d "$transaction" ] && [ ! -L "$transaction" ] \
    && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$transaction")" = "$transaction_identity" ]; then
    rm -rf -- "$transaction"
  else
    printf 'host integration apply: transaction identity changed before cleanup\n' >&2
    [ "$committed" = true ] || status=1
  fi
  [ "$committed" != true ] || status=0
  case "$status" in 0|3) ;; *) status=1 ;; esac
  exit "$status"
}
trap rollback EXIT

tar --no-same-owner -xzf "$split_bundle" -C "$candidate" \
  || die 'could not extract the canonical split bundle'
candidate_split="$candidate/deploy/split-agent"
[ -d "$candidate_split" ] && [ ! -L "$candidate_split" ] \
  || die 'canonical split bundle lacks its runtime root'
if find "$candidate_split" -type l -o ! -type d ! -type f | grep -q .; then
  die 'canonical split bundle contains a non-regular runtime entry'
fi
[ -f "$candidate_split/SOURCE_REVISION" ] && [ ! -L "$candidate_split/SOURCE_REVISION" ] \
  || die 'canonical split bundle lacks SOURCE_REVISION'
[ "$(cat -- "$candidate_split/SOURCE_REVISION")" = "$target_revision" ] \
  || die 'canonical split runtime revision differs from the release pin'
[ -f "$candidate_split/SOURCE_FILES.sha256" ] && [ ! -L "$candidate_split/SOURCE_FILES.sha256" ] \
  || die 'canonical split bundle lacks SOURCE_FILES.sha256'
(cd "$candidate_split" && sha256sum -c --status SOURCE_FILES.sha256) \
  || die 'canonical split runtime differs from its manifest'
(cd "$candidate_split" && find . -type f ! -name SOURCE_FILES.sha256 -print | LC_ALL=C sort) >"$transaction/actual-files"
awk '{path=$2; sub(/^\*/, "", path); print path}' "$candidate_split/SOURCE_FILES.sha256" \
  | LC_ALL=C sort >"$transaction/manifest-files"
cmp -s "$transaction/actual-files" "$transaction/manifest-files" \
  || die 'canonical split runtime manifest is not exhaustive'
chown -R 0:0 "$candidate/deploy"

candidate_ops="$candidate/production-ops"
install -d -o root -g root -m 0700 "$candidate_ops"
install -o root -g root -m 0400 \
  "$stage/cloud-init/split/Caddyfile" \
  "$stage/cloud-init/split/edge-compose.override.yaml" \
  "$release_pin" "$candidate_ops/"
install -o root -g root -m 0755 \
  "$stage/cloud-init/split/bootstrap-production.sh" "$advance" \
  "$stage/cloud-init/split/production-ops-common.sh" \
  "$stage/cloud-init/split/recover-production.sh" \
  "$stage/cloud-init/split/reconcile-production.sh" \
  "$stage/cloud-init/split/reset-production.sh" "$candidate_ops/"

candidate_updater="$candidate/updater"
install -d -o root -g root -m 0755 "$candidate_updater"
for file in bootstrap-host.sh install.sh reconcile-host.sh set-desired-state.sh; do
  install -o root -g root -m 0755 "$stage/updater/$file" "$candidate_updater/$file"
done
for file in release.env config.json dirextalk-updater.service; do
  install -o root -g root -m 0644 "$stage/updater/$file" "$candidate_updater/$file"
done

sshd_effective=$(sshd -T) || die 'could not read the effective SSH daemon configuration'
grep -Fx 'passwordauthentication no' <<<"$sshd_effective" >/dev/null \
  || die 'SSH password authentication must be disabled'
grep -Fx 'pubkeyauthentication yes' <<<"$sshd_effective" >/dev/null \
  || die 'SSH public-key authentication must be enabled'

install -d -o root -g root -m 0755 "$base/deploy"
if [ -e "$base/deploy/split-agent" ] || [ -L "$base/deploy/split-agent" ]; then
  [ -d "$base/deploy/split-agent" ] && [ ! -L "$base/deploy/split-agent" ] \
    || die 'live canonical split runtime is not a directory'
  mv -- "$base/deploy/split-agent" "$backup/split-agent"
fi
split_swapped=true
mv -- "$candidate_split" "$base/deploy/split-agent"
if [ -e "$base/production-ops" ] || [ -L "$base/production-ops" ]; then
  [ -d "$base/production-ops" ] && [ ! -L "$base/production-ops" ] \
    || die 'live production operations path is not a directory'
  mv -- "$base/production-ops" "$backup/production-ops"
fi
ops_swapped=true
mv -- "$candidate_ops" "$base/production-ops"
if [ -e "$base/updater" ] || [ -L "$base/updater" ]; then
  [ -d "$base/updater" ] && [ ! -L "$base/updater" ] \
    || die 'live updater integration path is not a directory'
  mv -- "$base/updater" "$backup/updater"
fi
updater_swapped=true
mv -- "$candidate_updater" "$base/updater"

install -d -o root -g root -m 0755 "${recovery_service%/*}"
if [ -e "$recovery_service" ] || [ -L "$recovery_service" ]; then
  [ -f "$recovery_service" ] && [ ! -L "$recovery_service" ] \
    || die 'live recovery service is not a regular file'
  cp --preserve=mode,ownership,timestamps -- "$recovery_service" "$backup/dirextalk-split-recovery.service"
  service_existed=true
fi
if systemctl is-enabled --quiet dirextalk-split-recovery.service >/dev/null 2>&1; then
  service_was_enabled=true
fi
service_changed=true
install -o root -g root -m 0644 \
  "$stage/cloud-init/split/dirextalk-split-recovery.service" "$recovery_service"
systemctl daemon-reload
systemctl enable dirextalk-split-recovery.service >/dev/null

# reconcile-host installs and activates host-level updater state that cannot be
# safely rolled back as a directory-only transaction. From this point onward,
# failures preserve the authorized candidate and the old revision receipt so
# the same update can converge forward on retry.
forward_only=true
if DIREXTALK_AUTHORIZED_SPLIT_SOURCE_REVISION="$target_revision" \
    bash "$base/updater/reconcile-host.sh" "$stage/updater" "$base" "$expected_stable_ip"; then
  :
else
  status=$?
  case "$status" in 3) exit 3 ;; *) exit 1 ;; esac
fi

# This is the only revision mutation and the final fallible commit step.
if bash "$base/production-ops/advance-split-source-revision.sh" \
    "$base/.env" "$expected_old" "$base/production-ops/release.env"; then
  :
else
  status=$?
  case "$status" in 3) exit 3 ;; *) exit 1 ;; esac
fi
committed=true
printf 'host integration apply passed: split_revision=%s\n' "$target_revision"
