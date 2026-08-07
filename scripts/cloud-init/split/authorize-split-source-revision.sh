#!/usr/bin/env bash
# Run split revision authorization from an isolated root-owned staging area
# before any canonical runtime or production-ops file is replaced.
set -euo pipefail

die() { printf 'split source authorization staging: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 5 ] || die 'usage: authorize-split-source-revision.sh SOURCE_HELPER SOURCE_PIN ROOT_ENV EXPECTED_OLD_REVISION EXPECTED_STABLE_IP'
source_helper=$1
source_pin=$2
env_file=$3
expected_old=$4
expected_stable_ip=$5
stable_ip_file=${env_file%/*}/stable-public-ip

valid_public_ip() {
  local ip=$1 part
  local -a parts
  case "$ip" in *$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;; esac
  printf '%s\n' "$ip" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' || return 1
  IFS=. read -r -a parts <<<"$ip"
  for part in "${parts[@]}"; do
    [ "$part" -le 255 ] || return 1
  done
}

valid_public_ip "$expected_stable_ip" || die 'expected stable public IP is invalid'
[ -f "$stable_ip_file" ] && [ ! -L "$stable_ip_file" ] \
  || die 'protected stable public IP receipt is unavailable'
[ "$(stat -c '%u:%g:%a' -- "$stable_ip_file")" = 0:0:600 ] \
  || die 'protected stable public IP receipt must be root-owned mode 0600'
stable_ip_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$stable_ip_file")
stable_ip_sha=$(sha256sum -- "$stable_ip_file" | awk '{print $1}')
recorded_stable_ip=$(cat -- "$stable_ip_file")
valid_public_ip "$recorded_stable_ip" || die 'protected stable public IP receipt is malformed'
[ "$recorded_stable_ip" = "$expected_stable_ip" ] \
  || { printf 'split source authorization staging: expected stable public IP differs from the protected receipt\n' >&2; exit 3; }

[ -f "$source_helper" ] && [ ! -L "$source_helper" ] || die 'source revision helper is unavailable'
[ -f "$source_pin" ] && [ ! -L "$source_pin" ] || die 'source release pin is unavailable'
source_helper_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$source_helper")
source_pin_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$source_pin")
source_helper_sha=$(sha256sum -- "$source_helper" | awk '{print $1}')
source_pin_sha=$(sha256sum -- "$source_pin" | awk '{print $1}')

stage=$(mktemp -d "${env_file%/*}/.split-source-authorization.XXXXXX") || die 'could not create authorization staging'
chmod 0700 -- "$stage" || die 'could not protect authorization staging'
chown 0:0 -- "$stage" || die 'could not bind authorization staging owner'
stage_identity=$(stat -c '%d:%i:%u:%g:%a' -- "$stage")
[ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(stat -c '%u:%g:%a' -- "$stage")" = 0:0:700 ] \
  || die 'authorization staging identity is invalid'
# shellcheck disable=SC2329
cleanup() {
  status=$?
  trap - EXIT
  if [ -d "$stage" ] && [ ! -L "$stage" ] \
    && [ "$(stat -c '%d:%i:%u:%g:%a' -- "$stage")" = "$stage_identity" ]; then
    rm -rf -- "$stage"
  else
    printf 'split source authorization staging: staging identity changed before cleanup\n' >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

[ "$(stat -c '%d:%i:%u:%g:%a' -- "$source_helper")" = "$source_helper_identity" ] \
  && [ "$(sha256sum -- "$source_helper" | awk '{print $1}')" = "$source_helper_sha" ] \
  || die 'source revision helper changed before staging'
[ "$(stat -c '%d:%i:%u:%g:%a' -- "$source_pin")" = "$source_pin_identity" ] \
  && [ "$(sha256sum -- "$source_pin" | awk '{print $1}')" = "$source_pin_sha" ] \
  || die 'source release pin changed before staging'
[ "$(stat -c '%d:%i:%u:%g:%a' -- "$stable_ip_file")" = "$stable_ip_identity" ] \
  && [ "$(sha256sum -- "$stable_ip_file" | awk '{print $1}')" = "$stable_ip_sha" ] \
  || die 'protected stable public IP receipt changed before authorization'
install -o root -g root -m 0700 "$source_helper" "$stage/advance-split-source-revision.sh" \
  || die 'could not stage the revision helper'
install -o root -g root -m 0400 "$source_pin" "$stage/release.env" \
  || die 'could not stage the release pin'
[ "$(stat -c '%d:%i:%u:%g:%a' -- "$stage")" = "$stage_identity" ] \
  || die 'authorization staging identity changed before execution'

if "$stage/advance-split-source-revision.sh" "$env_file" "$expected_old" "$stage/release.env" --check; then
  exit 0
else
  status=$?
  case "$status" in
    3) exit 3 ;;
    *) exit 1 ;;
  esac
fi
