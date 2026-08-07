#!/usr/bin/env bash
# Atomically advance only the deploy-tooling split source revision. Existing
# nodes retain their protected product image/source facts; the package release
# file describes fresh-deploy defaults and is not an active-runtime receipt.
set -euo pipefail

die() { printf 'split source revision advance: %s\n' "$*" >&2; exit 1; }
negative() { printf 'split source revision advance: %s\n' "$*" >&2; exit 3; }

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || die 'usage: advance-split-source-revision.sh ROOT_ENV EXPECTED_OLD_REVISION RELEASE_PIN [--check]'
env_file=$1
expected_old=$2
release_pin=$3
mode=${4:-commit}
[ "$mode" = commit ] || [ "$mode" = --check ] || die 'fourth argument must be --check'
command -v flock >/dev/null 2>&1 || die 'flock is required'

printf '%s\n' "$expected_old" | grep -Eq '^[0-9a-f]{40}$' || die 'expected old split source revision is invalid'
[ -f "$env_file" ] && [ ! -L "$env_file" ] || die 'protected root environment is unavailable'
[ -f "$release_pin" ] && [ ! -L "$release_pin" ] || die 'production release pin is unavailable'
[ "$(stat -c '%u:%g:%a' -- "$env_file")" = 0:0:600 ] || die 'protected root environment must be root-owned mode 0600'
[ "$(stat -c '%u:%g:%a' -- "$release_pin")" = 0:0:400 ] || die 'production release pin must be root-owned mode 0400'
if [ "$mode" = commit ]; then
  umask 077
  lock_file=${env_file%/*}/.split-source-revision.lock
  exec 9>>"$lock_file" || die 'could not open the split source revision lock'
  chmod 0600 -- "$lock_file" || die 'could not protect the split source revision lock'
  chown 0:0 -- "$lock_file" || die 'could not bind the split source revision lock owner'
  [ -f "$lock_file" ] && [ ! -L "$lock_file" ] \
    && [ "$(stat -c '%u:%g:%a' -- "$lock_file")" = 0:0:600 ] \
    || die 'split source revision lock identity is invalid'
  flock -n 9 || die 'another split source revision advance owns the environment'
fi

file_identity() { stat -c '%d:%i:%u:%g:%a' -- "$1"; }
read_unique() {
  local file=$1 key=$2 count value
  count=$(awk -F= -v wanted="$key" '$1 == wanted {n++} END {print n+0}' "$file")
  [ "$count" -eq 1 ] || die "$file must contain exactly one $key"
  value=$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0,length(wanted)+2); exit}' "$file")
  [ -n "$value" ] || die "$file contains an empty $key"
  printf '%s' "$value"
}

env_identity=$(file_identity "$env_file")
pin_identity=$(file_identity "$release_pin")
env_sha=$(sha256sum -- "$env_file" | awk '{print $1}')
pin_sha=$(sha256sum -- "$release_pin" | awk '{print $1}')

current_split_revision=$(read_unique "$release_pin" DIREXTALK_SPLIT_SOURCE_REVISION)
printf '%s\n' "$current_split_revision" | grep -Eq '^[0-9a-f]{40}$' \
  || die 'tooling release pin contains an invalid split source revision'
recorded_split_revision=$(read_unique "$env_file" SPLIT_SOURCE_REVISION)
case "$recorded_split_revision" in
  "$current_split_revision") exit 0 ;;
  "$expected_old") ;;
  *) negative 'recorded split source revision differs from the authorized old/current revisions' ;;
esac

if [ "$mode" = --check ]; then
  printf 'split source revision preflight passed: old=%s target=%s\n' \
    "$recorded_split_revision" "$current_split_revision"
  exit 0
fi

[ "$(file_identity "$release_pin")" = "$pin_identity" ] \
  && [ "$(sha256sum -- "$release_pin" | awk '{print $1}')" = "$pin_sha" ] \
  || die 'production release pin changed during authorization'
[ "$(file_identity "$env_file")" = "$env_identity" ] \
  && [ "$(sha256sum -- "$env_file" | awk '{print $1}')" = "$env_sha" ] \
  || die 'protected root environment changed during authorization'

tmp=$(mktemp "${env_file%/*}/.env.split-source.XXXXXX") || die 'could not create the replacement environment'
cleanup() { [ -z "${tmp:-}" ] || rm -f -- "$tmp"; }
trap cleanup EXIT
awk -F= -v replacement="$current_split_revision" '
  $1 == "SPLIT_SOURCE_REVISION" {$0="SPLIT_SOURCE_REVISION=" replacement; seen++}
  {print}
  END {if (seen != 1) exit 1}
' "$env_file" >"$tmp" || die 'could not render the replacement environment'
chmod 0600 -- "$tmp" || die 'could not protect the replacement environment'
chown 0:0 -- "$tmp" || die 'could not bind the replacement environment owner'
[ -f "$tmp" ] && [ ! -L "$tmp" ] \
  && [ "$(stat -c '%u:%g:%a' -- "$tmp")" = 0:0:600 ] \
  || die 'replacement root environment identity is invalid'
[ "$(read_unique "$tmp" SPLIT_SOURCE_REVISION)" = "$current_split_revision" ] \
  || die 'replacement root environment has the wrong split source revision'
[ "$(file_identity "$release_pin")" = "$pin_identity" ] \
  && [ "$(sha256sum -- "$release_pin" | awk '{print $1}')" = "$pin_sha" ] \
  || die 'production release pin changed before environment replacement'
[ "$(file_identity "$env_file")" = "$env_identity" ] \
  && [ "$(sha256sum -- "$env_file" | awk '{print $1}')" = "$env_sha" ] \
  || die 'protected root environment changed before replacement'
mv -f -- "$tmp" "$env_file" || die 'could not atomically replace the protected root environment'
tmp=
# Every property of the replacement was verified while it was still the
# same-filesystem temporary file. The rename above is the final fallible step:
# never report failure after the new revision has become authoritative.
printf 'split source revision advance passed: revision=%s\n' "$current_split_revision"
