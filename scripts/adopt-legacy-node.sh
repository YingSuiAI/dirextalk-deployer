#!/usr/bin/env bash
# Explicitly adopt the one approved pre-updater d1 host without changing its running image.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$HERE/lib/git-bash.sh"
# shellcheck disable=SC1090
source "$HERE/lib/paths.sh"
# shellcheck disable=SC1090
source "$HERE/lib/state.sh"
# shellcheck disable=SC1090
source "$HERE/lib/server-release.sh"
# shellcheck disable=SC1090
source "$HERE/lib/updater-release.sh"
# shellcheck disable=SC1090
source "$HERE/phases/s3_provision.sh"

dirextalk_require_git_bash_on_windows || exit 1

dry_run=0
if [ "${1:-}" = --dry-run ]; then
  dry_run=1
  shift
fi
STATE_JSON=$(dirextalk_execution_path "${1:-$STATE_JSON}")
DIREXTALK_WORKDIR=${STATE_JSON%/state.json}
[ -f "$STATE_JSON" ] || { echo "state.json not found: $STATE_JSON" >&2; exit 1; }

source_dir=${DIREXTALK_LEGACY_ADOPT_SOURCE_DIR:-}
ssh_user=${DIREXTALK_LEGACY_ADOPT_SSH_USER:-}
[ "$source_dir" = /root/dirextalk/dirextalk-message-server ] || {
  echo "legacy adoption supports only the approved d1 source directory" >&2
  exit 1
}
[ "$ssh_user" = root ] || { echo "legacy d1 adoption requires the explicit root SSH identity" >&2; exit 1; }

existing_source=$(state_get server_release.source)
case "$existing_source" in
  '') ;;
  legacy_adopted)
    server_release_state_is_legacy_adopted \
      "$(state_get server_release.source)" \
      "$(state_get server_release.version)" \
      "$(state_get server_release.image)" \
      "$(state_get server_release.digest)" \
      "$(state_get server_release.image_ref)" || {
      echo "existing legacy adoption state is inconsistent" >&2
      exit 1
    }
    ;;
  *) echo "existing server release state is authoritative; refusing legacy adoption" >&2; exit 1 ;;
esac

public_ip=$(res_get public_ip)
key_file=$(res_get key_file)
_is_canonical_ipv4 "$public_ip" && [ -f "$key_file" ] || {
  echo "legacy adoption requires the recorded canonical public IP and SSH key" >&2
  exit 1
}

known_hosts="$DIREXTALK_WORKDIR/known_hosts"
probe_bundle=$(mktemp "$DIREXTALK_WORKDIR/.legacy-adopt-probe.XXXXXX.tar.gz")
trap 'rm -f "$probe_bundle"' EXIT
tar -C "$HERE" -cf - \
  updater/adopt-legacy-host.sh \
  updater/legacy-d1-compose.p2p.yml \
  updater/legacy-adopt-compose.yml | gzip -n > "$probe_bundle"
remote_probe="stage=\$(mktemp -d /tmp/dirextalk-legacy-probe.XXXXXX) && trap 'rm -rf \"\$stage\"' EXIT && tar -xzf - -C \"\$stage\" && bash \"\$stage/updater/adopt-legacy-host.sh\" probe '$source_dir' \"\$stage/updater\""
probe=$(ssh -T -i "$key_file" \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=$known_hosts" \
  "$ssh_user@$public_ip" "$remote_probe" < "$probe_bundle")
expected=$'legacy_adoptable\tv0.15.2\tdirextalk/message-server:v0.15.2@sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c\t/root/dirextalk/dirextalk-message-server\tdocker-compose.p2p.yml\tsystemd_caddy'
[ "$(printf '%s\n' "$probe" | tail -n 1)" = "$expected" ] || {
  echo "remote legacy probe did not return the approved identity" >&2
  exit 1
}

if [ "$dry_run" -eq 1 ]; then
  printf '%s\n' "$expected"
  exit 0
fi
confirm=${DIREXTALK_LEGACY_ADOPT_CONFIRM:-}
[ "$confirm" = adopt-legacy-v0.15.2-d57a0b7830f7248e ] || {
  echo "set DIREXTALK_LEGACY_ADOPT_CONFIRM=adopt-legacy-v0.15.2-d57a0b7830f7248e after reviewing --dry-run" >&2
  exit 1
}

if [ -z "$existing_source" ]; then
  state_set_raw server_release '{"source":"legacy_adopted","version":"v0.15.2","image":"dirextalk/message-server:v0.15.2","digest":"sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c","image_ref":"dirextalk/message-server:v0.15.2@sha256:d57a0b7830f7248e29fe7c45c0848cb1167454709fd33effe07ff074415f571c","manifest_digest":"","caddy_mode":"systemd"}'
fi

export DIREXTALK_BOOTSTRAP_SSH_USER="$ssh_user"
_resume_host_bootstrap "$public_ip" "$key_file" "$source_dir"
printf 'legacy adoption complete for %s at v0.15.2\n' "$public_ip"
