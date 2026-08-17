#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
helper=$script_dir/prepare-host-dependencies.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-host-deps.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && printf '0\n'
EOF
cat >"$tmp/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$DIREXTALK_HOST_DEPS_LOG"
[ "${DIREXTALK_HOST_DEPS_APT_FAIL:-false}" != true ] || exit 42
if [ "${1:-}" = install ]; then
  printf '#!/usr/bin/env bash\nexit 0\n' >"$DIREXTALK_HOST_DEPS_BIN/dirextalk-json-fixture"
  chmod 755 "$DIREXTALK_HOST_DEPS_BIN/dirextalk-json-fixture"
fi
EOF
chmod 755 "$tmp/bin/id" "$tmp/bin/apt-get"

export DIREXTALK_HOST_DEPS_LOG=$tmp/apt.log
export DIREXTALK_HOST_DEPS_BIN=$tmp/bin
export DIREXTALK_SPLIT_JSON_CLI=dirextalk-json-fixture
export DIREXTALK_SPLIT_TEST_MODE=true
export PATH=$tmp/bin:$PATH

printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/dirextalk-json-fixture"
chmod 755 "$tmp/bin/dirextalk-json-fixture"
"$helper"
[ ! -e "$tmp/apt.log" ]

rm -f "$tmp/bin/dirextalk-json-fixture"
"$helper"
grep -Fqx update "$tmp/apt.log"
grep -Fqx 'install -y --no-install-recommends jq' "$tmp/apt.log"

rm -f "$tmp/bin/dirextalk-json-fixture"
: >"$tmp/apt.log"
if DIREXTALK_HOST_DEPS_APT_FAIL=true "$helper" >/dev/null 2>&1; then
  echo 'host dependency preparation unexpectedly ignored apt failure' >&2
  exit 1
fi
grep -Fqx update "$tmp/apt.log"

printf 'production host dependency preparation verified\n'
