#!/usr/bin/env bash
# Complete an interrupted first boot after the updater and stable public IP are available.
set -euo pipefail

root=${DIREXTALK_BOOTSTRAP_ROOT:-}
base="$root/var/dirextalk-message-server"
timeout=${DIREXTALK_BOOTSTRAP_TIMEOUT:-900}
stable_ip=${1:-}
lock_dir="$root/run/lock"
lock_file="$lock_dir/dirextalk-bootstrap.lock"

valid_public_ip() {
  local ip=$1 part
  local -a parts
  case "$ip" in *$'\n'*|*$'\r'*|*$'\t'*|*' '*) return 1 ;; esac
  printf '%s\n' "$ip" | grep -Eq '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$' || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [ "$part" -le 255 ] || return 1
  done
}

if [ -n "$stable_ip" ]; then
  valid_public_ip "$stable_ip" || { echo "invalid stable public IP" >&2; exit 1; }
  mkdir -p "$base"
  stable_tmp=$(mktemp "$base/.stable-public-ip.XXXXXX")
  printf '%s\n' "$stable_ip" > "$stable_tmp"
  chmod 0600 "$stable_tmp"
  mv -f "$stable_tmp" "$base/stable-public-ip"
fi

ready() {
  [ -s "$base/stable-public-ip" ] \
    && [ -f "$base/.env" ] \
    && [ -f "$base/docker-compose.yml" ] \
    && [ -x "$base/init-tokens.sh" ] \
    && [ -x "$base/updater/install.sh" ] \
    && [ -x "$base/dirextalk-updater" ]
}

deadline=$(($(date +%s) + timeout))
until ready; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out waiting ${timeout} seconds for stable IP and deployment prerequisites" >&2
    exit 1
  fi
  sleep 5
done

mkdir -p "$lock_dir"
exec 9>"$lock_file"
flock 9

# A concurrent cloud-init/S3 invocation may have completed while this process waited.
ready || { echo "deployment prerequisites disappeared while waiting for bootstrap lock" >&2; exit 1; }
stable_ip=$(cat "$base/stable-public-ip")
valid_public_ip "$stable_ip" || { echo "invalid recorded stable public IP" >&2; exit 1; }

first_nonempty_env_value() {
  local key=$1
  awk -F= -v key="$key" '
    $1 == key {
      value=substr($0, index($0, "=") + 1)
      if (value != "") { print value; exit }
    }
  ' "$base/.env"
}

turn_secret=$(first_nonempty_env_value TURN_SECRET)
if [ -z "$turn_secret" ]; then
  turn_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fi
p2p_portal_password=$(first_nonempty_env_value P2P_PORTAL_PASSWORD)
if [ -z "$p2p_portal_password" ]; then
  random_number=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  p2p_portal_password=$(printf '%08d' "$((random_number % 100000000))")
fi
[ -n "$turn_secret" ] && [ -n "$p2p_portal_password" ] || {
  echo "failed to establish non-empty service secrets" >&2
  exit 1
}

env_tmp=$(mktemp "$base/.env.XXXXXX")
awk '$0 !~ /^(PUBLIC_IP|TURN_SECRET|P2P_PORTAL_PASSWORD)=/' "$base/.env" > "$env_tmp"
printf 'PUBLIC_IP=%s\n' "$stable_ip" >> "$env_tmp"
printf 'TURN_SECRET=%s\n' "$turn_secret" >> "$env_tmp"
printf 'P2P_PORTAL_PASSWORD=%s\n' "$p2p_portal_password" >> "$env_tmp"
chmod 0600 "$env_tmp"
mv -f "$env_tmp" "$base/.env"

bash "$base/updater/install.sh" "$base/dirextalk-updater"
mkdir -p "$base/p2p"
chmod 0700 "$base"
cd "$base"
docker compose --env-file .env pull
docker compose --env-file .env up -d
domain=$(awk -F= '$1 == "DOMAIN" { print substr($0, index($0, "=") + 1); exit }' .env)
DOMAIN="$domain" bash init-tokens.sh
touch .deploy-done
