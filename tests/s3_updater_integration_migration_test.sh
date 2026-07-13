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
printf 'v1.0.6\t586f5ee82f1697269cfd764545198d88707734b8\tfc25f8ff811313dfc18c2b4e0f01b46802697385b24395f9c78e634e5ac426e4\n'
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
  updater/dirextalk-updater.service \
  updater/dirextalk-updater-discovery.service \
  updater/dirextalk-updater-discovery.timer; do
  grep -Fx -q "$path" "$tmp/bundle.list" || { echo "missing updater integration file: $path" >&2; exit 1; }
done
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
[ "$(json_get "$STATE_JSON" updater_release.version)" = v1.0.6 ]
[ "$(json_get "$STATE_JSON" updater_release.commit)" = 586f5ee82f1697269cfd764545198d88707734b8 ]

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
