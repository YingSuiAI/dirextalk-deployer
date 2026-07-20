#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DIREXTALK_WORKDIR="$tmp/work" CALLS="$tmp/calls"
export REMOTE_BUNDLE="$tmp/remote-bundle.tar.gz" REMOTE_COMMAND="$tmp/remote-command"
mkdir -p "$HOME" "$DIREXTALK_WORKDIR" "$tmp/bin" "$tmp/old-remote/updater"
printf 'old ticket-3 bootstrap\n' > "$tmp/old-remote/updater/bootstrap-host.sh"
printf 'key\n' > "$tmp/key.pem"
: > "$CALLS"

cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >> "$CALLS"
printf ' %q' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
printf '%s\n' "${!#}" > "$REMOTE_COMMAND"
cat > "$REMOTE_BUNDLE"
if [ "${SSH_MODE:-success}" != success ]; then
  exit 88
fi
printf 'v1.0.10\ta8971d7b04e8fef29b35ef889cc1b70d7ceca7a5\t730f3d1e4c6f604069e1b6eed60121bffb47f32d2f1d960cb3f8a0121974b6b8\n'
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/state.sh"
state_init >/dev/null 2>&1
state_set_raw updater_release '{"version":"v0.9.0","commit":"1111111111111111111111111111111111111111","sha256":"2222222222222222222222222222222222222222222222222222222222222222"}'
printf '203.0.113.44 ssh-ed25519 pinned-test-key\n' > "$tmp/known_hosts"
res_set lightsail_ssh_known_hosts "$tmp/known_hosts"
# shellcheck disable=SC1091
source "$ROOT/scripts/phases/s3_provision.sh"

export DIREXTALK_BOOTSTRAP_SSH_ATTEMPTS=1 DIREXTALK_BOOTSTRAP_SSH_DELAY=0 SSH_MODE=success
_resume_host_bootstrap 203.0.113.44 "$tmp/key.pem"

tar -tzf "$REMOTE_BUNDLE" > "$tmp/bundle.list"
for path in \
  cloud-init/init-tokens.sh \
  updater/bootstrap-host.sh \
  updater/install.sh \
  updater/reconcile-host.sh \
  updater/set-desired-state.sh \
  updater/release.env \
  updater/config.json \
  updater/dirextalk-updater.service; do
  grep -Fx -q "$path" "$tmp/bundle.list" || { echo "missing updater integration file: $path" >&2; exit 1; }
done
if grep -Eq 'dirextalk-updater-discovery\.(service|timer)' "$tmp/bundle.list"; then
  echo "integration bundle must not include retired discovery units" >&2
  exit 1
fi
if grep -Eq '(^|/)dirextalk-updater$' "$tmp/bundle.list"; then
  echo "integration bundle must not transport the updater binary" >&2
  exit 1
fi
tar -xzf "$REMOTE_BUNDLE" -C "$tmp/old-remote"
cmp "$ROOT/scripts/updater/bootstrap-host.sh" "$tmp/old-remote/updater/bootstrap-host.sh"
grep -F -q 'tar -xzf -' "$REMOTE_COMMAND"
grep -F -q 'reconcile-host.sh' "$REMOTE_COMMAND"
grep -F -q 'systemctl is-active' "$tmp/old-remote/updater/reconcile-host.sh"
grep -F -q '/usr/local/bin/dirextalk-updater version' "$tmp/old-remote/updater/reconcile-host.sh"
grep -F -q 'sha256sum /usr/local/bin/dirextalk-updater' "$tmp/old-remote/updater/reconcile-host.sh"
grep -F -q 'init-tokens.sh' "$tmp/old-remote/updater/reconcile-host.sh"
[ "$(json_get "$STATE_JSON" updater_release.version)" = v1.0.10 ]
[ "$(json_get "$STATE_JSON" updater_release.commit)" = a8971d7b04e8fef29b35ef889cc1b70d7ceca7a5 ]

state_set_raw updater_release '{"version":"v0.9.0","commit":"1111111111111111111111111111111111111111","sha256":"2222222222222222222222222222222222222222222222222222222222222222"}'
export SSH_MODE=fail
if _resume_host_bootstrap 203.0.113.44 "$tmp/key.pem" >/dev/null 2>&1; then
  echo "failed remote migration was accepted" >&2
  exit 1
fi
[ "$(json_get "$STATE_JSON" updater_release.version)" = v0.9.0 ] || {
  echo "failed migration overwrote the previously proven updater state" >&2
  exit 1
}

echo "s3 updater integration migration ok"
