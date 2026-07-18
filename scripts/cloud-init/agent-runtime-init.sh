#!/bin/sh
# Create the private Agent TLS/material directory. The Message Server image
# already ships the reviewed generate-keys binary used by its own bootstrap;
# this script uses it only inside the private Compose volume.
set -eu

runtime_dir=${AGENT_RUNTIME_DIR:?AGENT_RUNTIME_DIR is required}
profiles_source=${AGENT_MODEL_PROFILES_SOURCE:?AGENT_MODEL_PROFILES_SOURCE is required}
ca_cert="$runtime_dir/agent-ca.crt"
tls_cert="$runtime_dir/agent-tls.crt"
tls_key="$runtime_dir/agent-tls.key"
certificate_tmp="$runtime_dir/.agent-tls.crt.tmp"
key_tmp="$runtime_dir/.agent-tls.key.tmp"
ca_tmp="$runtime_dir/.agent-ca.crt.tmp"
pepper_file="$runtime_dir/agent-service-key-pepper"
master_key_file="$runtime_dir/agent-master-key"
service_key_file="$runtime_dir/message-server.service-key"
profiles_file="$runtime_dir/agent-model-profiles.json"
mounted_secrets="$runtime_dir/mounted-secrets"

die() {
  printf '%s\n' "agent runtime initialization failed: $*" >&2
  exit 1
}

random_url_key() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\n'
}

write_random_secret_once() {
  local path=$1 value
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ -s "$path" ] || die "existing $(basename "$path") is not a non-empty regular file"
    return 0
  fi
  value=$(random_url_key)
  [ "${#value}" -ge 32 ] || die "could not generate $(basename "$path")"
  printf '%s\n' "$value" > "$path"
  unset value
}

mkdir -p "$runtime_dir" "$mounted_secrets"
umask 077
[ -f "$profiles_source" ] && [ -s "$profiles_source" ] || die 'model-profile catalog is missing or empty'

if [ -e "$profiles_file" ]; then
  cmp -s "$profiles_source" "$profiles_file" || die 'model-profile catalog changed after initialization'
else
  cp "$profiles_source" "$profiles_file"
fi

if [ -e "$tls_cert" ] || [ -e "$tls_key" ] || [ -e "$ca_cert" ]; then
  [ -f "$tls_cert" ] && [ -s "$tls_cert" ] && [ -f "$tls_key" ] && [ -s "$tls_key" ] && [ -f "$ca_cert" ] && [ -s "$ca_cert" ] \
    || die 'existing Agent TLS material is incomplete'
  # generate-keys only creates server certificates, not CA certificates. The
  # Message Server therefore trusts the exact self-signed Agent leaf. Refuse
  # the retired pseudo-CA layout instead of silently retaining a TLS chain
  # that every strict client rejects.
  cmp -s "$ca_cert" "$tls_cert" || die 'existing Agent TLS trust material uses the retired signer layout; recreate the Agent runtime volume'
else
  trap 'rm -f "$certificate_tmp" "$key_tmp" "$ca_tmp"' EXIT HUP INT TERM
  /usr/bin/generate-keys \
    --tls-cert "$certificate_tmp" \
    --tls-key "$key_tmp" \
    --server agent >/dev/null
  cp "$certificate_tmp" "$ca_tmp"
  mv "$certificate_tmp" "$tls_cert"
  mv "$key_tmp" "$tls_key"
  mv "$ca_tmp" "$ca_cert"
  trap - EXIT HUP INT TERM
fi

write_random_secret_once "$pepper_file"
write_random_secret_once "$master_key_file"
if [ ! -e "$service_key_file" ]; then
  service_key=$(random_url_key)
  [ "${#service_key}" -ge 32 ] || die 'could not generate Message Server service key'
  printf 'message-server.%s\n' "$service_key" > "$service_key_file"
  unset service_key
fi
[ -f "$service_key_file" ] && [ -s "$service_key_file" ] || die 'existing Message Server service key is not a non-empty regular file'

chmod 0444 "$ca_cert" "$tls_cert" "$profiles_file"
chmod 0400 "$tls_key" "$pepper_file" "$master_key_file" "$service_key_file"
chmod 0700 "$mounted_secrets"
chown 65532:65532 "$ca_cert" "$tls_cert" "$tls_key" "$pepper_file" "$master_key_file" "$service_key_file" "$profiles_file" "$mounted_secrets"
