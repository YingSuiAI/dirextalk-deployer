#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/local-paths.sh"
# shellcheck disable=SC1090
source "$ROOT/tests/lib/json_test.sh"
# shellcheck disable=SC1090
source "$ROOT/tests/lib/isolated_home.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dirextalk_test_isolate_homes "$tmp"

assert_equal() {
  local actual=$1 expected=$2 message=$3
  if [ "$actual" != "$expected" ]; then
    echo "$message; expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_paths_equal() {
  local left=$1 right=$2 message=$3
  if ! DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_paths_equal "$left" "$right"; then
    echo "$message; expected paths to match: '$left' vs '$right'" >&2
    exit 1
  fi
}

assert_paths_differ() {
  local left=$1 right=$2 message=$3
  if DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_paths_equal "$left" "$right"; then
    echo "$message; expected paths to differ: '$left' vs '$right'" >&2
    exit 1
  fi
}

assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path 'C:\Users\alice\.dirextalk')" "C:/Users/alice/.dirextalk" "native Windows paths normalize to forward slashes"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path 'C:/Users/alice/.dirextalk')" "C:/Users/alice/.dirextalk" "slash-normalized Windows paths stay native"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path '/mnt/c/Users/alice/.dirextalk')" "C:/Users/alice/.dirextalk" "POSIX Windows mount paths become native Windows paths"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path '/cygdrive/c/Users/alice/.dirextalk')" "C:/Users/alice/.dirextalk" "Cygwin mount paths become native Windows paths"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path '/c/Users/alice/.dirextalk')" "C:/Users/alice/.dirextalk" "Git Bash drive paths become native Windows paths"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path 'dirextalk-connect')" "dirextalk-connect" "plain command names are not rewritten as paths"

assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_normalize_local_path '/c/Users/alice/.dirextalk/')" "C:/Users/alice/.dirextalk" "Windows normalization trims trailing slash after drive conversion"
assert_paths_equal "/c/Users/Alice/.dirextalk/" "C:/users/alice/.dirextalk" "Windows path comparison is case-insensitive across supported path spellings"
assert_paths_differ "/home/alice/.dirextalk" "/home/bob/.dirextalk" "POSIX paths still compare literally when they are not Windows drive paths"

assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_normalize_local_path '/c/Users/alice/.dirextalk/')" "/c/Users/alice/.dirextalk" "POSIX normalization does not reinterpret Git Bash drive paths as Windows paths"

declare -F dirextalk_render_local_command >/dev/null || {
  echo "missing unified local command renderer" >&2
  exit 1
}
declare -F dirextalk_native_tool_path >/dev/null || {
  echo "missing native tool path normalizer" >&2
  exit 1
}
declare -F dirextalk_native_tool_at_path >/dev/null || {
  echo "missing native tool @file path normalizer" >&2
  exit 1
}
case "$(uname -s 2>/dev/null || printf unknown)" in
  *MINGW*|*MSYS*|*CYGWIN*)
    assert_equal "$(dirextalk_native_tool_path "$tmp/native-tool.json")" "$(cygpath -m "$tmp/native-tool.json")" "native Windows tools receive a path to the shell-created temp file"
    assert_equal "$(dirextalk_native_tool_at_path "$tmp/native-tool.json")" "@$(cygpath -m "$tmp/native-tool.json")" "native Windows @file arguments target the shell-created temp file"
    assert_equal "$(dirextalk_native_null_device)" "NUL" "native Windows tools use the Windows null device"
    ;;
  *)
    assert_equal "$(dirextalk_native_tool_path "$tmp/native-tool.json")" "$tmp/native-tool.json" "POSIX native tools retain the shell temp path"
    assert_equal "$(dirextalk_native_tool_at_path "$tmp/native-tool.json")" "@$tmp/native-tool.json" "POSIX @file arguments retain the shell temp path"
    assert_equal "$(dirextalk_native_null_device)" "/dev/null" "POSIX native tools use the POSIX null device"
    ;;
esac
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_local_command "C:/Program Files/O'Brien/connect.cmd" daemon status --service-name service.example.test)" "C:/Program\\ Files/O\\'Brien/connect.cmd daemon status --service-name service.example.test" "Windows Git Bash commands use Bash argv quoting"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_render_local_command "/opt/Agent O'Brien/connect" daemon status --service-name service.example.test)" "/opt/Agent\\ O\\'Brien/connect daemon status --service-name service.example.test" "POSIX commands use Bash argv quoting"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_env_command DOMAIN service.example.test bash scripts/orchestrate.sh verify runtime)" "DOMAIN=service.example.test bash scripts/orchestrate.sh verify runtime" "Windows Git Bash env commands use Bash syntax"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_render_env_command DOMAIN service.example.test bash scripts/orchestrate.sh verify runtime)" "DOMAIN=service.example.test bash scripts/orchestrate.sh verify runtime" "POSIX env commands use Bash syntax"
if DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_render_env_command 'BAD-NAME' value command >/dev/null 2>&1; then
  echo "environment command renderer must reject invalid variable names" >&2
  exit 1
fi
if DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_env_command '' value command >/dev/null 2>&1; then
  echo "environment command renderer must reject an empty variable name" >&2
  exit 1
fi

# Keep the old default-path contract with the local-path checks: a no-domain
# status is a read-only inventory, while DOMAIN and explicit workdirs still
# resolve to the expected service state file.
export DIREXTALK_LOCAL_PATH_STYLE=posix
export DIREXTALK_HOME="$HOME/.dirextalk"
export DOMAIN="Service.Example.test"
unset DIREXTALK_WORKDIR
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"
assert_equal "$DIREXTALK_WORKDIR" "$HOME/.dirextalk/nodes/service.example.test" "domain selects its normalized service workdir"
assert_equal "$STATE_JSON" "$HOME/.dirextalk/nodes/service.example.test/state.json" "domain selects its normalized state file"
(
  export DIREXTALK_WORKDIR="$HOME/.dirextalk/custom-workdir"
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib/state.sh"
  [ "$DIREXTALK_WORKDIR" = "$HOME/.dirextalk/custom-workdir" ]
  [ "$STATE_JSON" = "$HOME/.dirextalk/custom-workdir/state.json" ]
)

dirextalk_test_assert_path_isolated "$HOME/.dirextalk" "$tmp" "default path test home"
rm -rf "$HOME/.dirextalk"
(
  unset DOMAIN DIREXTALK_WORKDIR
  HOME="$HOME" DIREXTALK_HOME="$HOME/.dirextalk" DIREXTALK_LOCAL_PATH_STYLE=posix bash "$ROOT/scripts/orchestrate.sh" status >/dev/null 2>&1
)
[ ! -e "$HOME/.dirextalk/deploy" ]
[ ! -e "$HOME/.dirextalk/nodes/state.json" ]

mkdir -p "$HOME/.dirextalk/nodes/solo.example.test"
json_build object domain=solo.example.test phase=S3_PROVISION 'resources={"instance_id":"i-solo"}' > "$HOME/.dirextalk/nodes/solo.example.test/state.json"
(
  unset DOMAIN DIREXTALK_WORKDIR
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib/state.sh"
  [ "$DIREXTALK_WORKDIR" = "$HOME/.dirextalk/nodes" ]
  [ "$STATE_JSON" = "$HOME/.dirextalk/nodes/state.json" ]
)
mkdir -p "$HOME/.dirextalk/nodes/second.example.test"
json_build object domain=second.example.test phase=S6_WIRE_LOCAL 'resources={"instance_id":"i-second"}' > "$HOME/.dirextalk/nodes/second.example.test/state.json"
status_output=$(
  unset DOMAIN DIREXTALK_WORKDIR
  HOME="$HOME" DIREXTALK_HOME="$HOME/.dirextalk" DIREXTALK_LOCAL_PATH_STYLE=posix bash "$ROOT/scripts/orchestrate.sh" status
)
[[ "$status_output" == *"solo.example.test"* ]]
[[ "$status_output" == *"second.example.test"* ]]
[[ "$status_output" == *"i-solo"* ]]
[[ "$status_output" == *"i-second"* ]]

echo "local paths ok"
