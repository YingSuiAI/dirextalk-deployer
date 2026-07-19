#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export DIREXTALK_WORKDIR="$tmp/work"
export FAKE_DEPLOY_DIR="$tmp/root-owned-mode-0700-deploy-directory"
export REMOTE_CAPTURE="$tmp/remote-command"
export SUDO_CAPTURE="$tmp/sudo-command"
export CONTAINER_CAPTURE="$tmp/container-command"
export SECRET_STDIN_CAPTURE="$tmp/secret-stdin"
mkdir -p "$DIREXTALK_WORKDIR" "$FAKE_DEPLOY_DIR" "$tmp/bin"
chmod 0700 "$FAKE_DEPLOY_DIR"

cat > "$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 5 ]
[ "$1" = -n ] && [ "$2" = -- ] && [ "$3" = /bin/sh ] && [ "$4" = -c ]
root_command=$5
printf '%s' "$root_command" > "$SUDO_CAPTURE"
[[ "$root_command" == $'set -eu\ncd /var/dirextalk-message-server\nexec docker compose '* ]] || exit 1

# The SSH fixture represents a root:root mode-0700 deployment directory. This
# shim is the privileged side of that boundary and maps the fixed remote path
# to an isolated directory only after sudo has received the root shell body.
root_command=${root_command//\/var\/dirextalk-message-server/$FAKE_DEPLOY_DIR}
exec /bin/sh -c "$root_command"
EOF

cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = compose ]
shift
[ "$#" -ge 11 ]
[ "$1" = --env-file ] && [ "$2" = .env ] && [ "$3" = run ]
[ "$4" = --rm ] && [ "$5" = -T ] && [ "$6" = --no-deps ]
[ "$7" = --entrypoint ] && [ "$8" = /bin/sh ] && [ "$9" = agent-runtime-init ] && [ "${10}" = -c ]
container_body=${11}
printf '%s' "$container_body" > "$CONTAINER_CAPTURE"

case "$#" in
  13)
    [ "${12}" = agent-mounted-secret-delivery ] && [ "${13}" = test-token ]
    [[ "$container_body" == *'cat > "$tmp"'* ]] || exit 1
    cat > "$SECRET_STDIN_CAPTURE"
    printf '%s\n' 'mounted-secret-ready uid=65532 mode=0400'
    ;;
  11)
    [[ "$container_body" == *'find "$dest" -mindepth 1 -maxdepth 1 -type f -delete'* ]] || exit 1
    ;;
  *) exit 1 ;;
esac
EOF

chmod 0700 "$tmp/bin/"{sudo,docker}
export PATH="$tmp/bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/agent-secret-delivery.sh"

ssh() {
  local remote=${!#}
  printf '%s' "$remote" > "$REMOTE_CAPTURE"
  bash -n <<<"$remote"

  # An unprivileged SSH user cannot traverse bootstrap's root:root mode-0700
  # deployment directory. The prior v0.1.47 command fails here before Docker;
  # the fixed command reaches the sudo shim, then the fake container boundary.
  if [[ "$remote" == $'set -eu\ncd /var/dirextalk-message-server'* ]]; then
    printf '%s\n' 'cd: /var/dirextalk-message-server: Permission denied' >&2
    return 1
  fi
  /bin/bash -c "$remote"
}

assert_root_crossing() {
  local remote=$1 label=$2
  [[ "$remote" == *$'exec sudo -n -- /bin/sh -c \'set -eu\ncd /var/dirextalk-message-server\n'* ]] || {
    echo "$label must cross the root-owned mode-0700 deploy directory under noninteractive sudo" >&2
    exit 1
  }
}

fixture_secret="$tmp/fixture-token"
keyfile="$tmp/test-key.pem"
known_hosts="$tmp/known_hosts"
printf '%s\n' 'fixture-only-mounted-secret' > "$fixture_secret"
printf '%s\n' 'fixture-key' > "$keyfile"
printf '%s\n' '203.0.113.44 ssh-ed25519 fixture-host-key' > "$known_hosts"
restrict_private_file() { chmod 0600 "$1"; }
AGENT_MOUNTED_SECRET_FILE_RESOLVED=$fixture_secret
AGENT_MOUNTED_SECRET_NAME=test-token

agent_mounted_secret_deliver_pinned 203.0.113.44 "$keyfile" "$known_hosts"
cmp "$fixture_secret" "$SECRET_STDIN_CAPTURE"
assert_root_crossing "$(cat "$REMOTE_CAPTURE")" delivery
grep -F -q 'cat > "$tmp"' "$CONTAINER_CAPTURE"

agent_mounted_secret_cleanup_pinned 203.0.113.44 "$keyfile" "$known_hosts"
assert_root_crossing "$(cat "$REMOTE_CAPTURE")" cleanup
grep -F -q 'find "$dest" -mindepth 1 -maxdepth 1 -type f -delete' "$CONTAINER_CAPTURE"

if agent_mounted_secret_name_is_safe 'test-token;touch-owned'; then
  echo "unsafe mounted-secret name unexpectedly accepted" >&2
  exit 1
fi

echo "agent mounted secret root delivery ok"
