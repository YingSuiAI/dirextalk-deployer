#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/local-paths.sh"

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
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_to_windows_local_path '/mnt/c/Users/alice/.dirextalk')" "C:/Users/alice/.dirextalk" "WSL mount paths become native Windows paths"
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
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_local_command "C:/Program Files/O'Brien/connect.cmd" daemon status --service-name service.example.test)" "& 'C:/Program Files/O''Brien/connect.cmd' 'daemon' 'status' '--service-name' 'service.example.test'" "Windows commands use PowerShell argv quoting"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_render_local_command "/opt/Agent O'Brien/connect" daemon status --service-name service.example.test)" "/opt/Agent\\ O\\'Brien/connect daemon status --service-name service.example.test" "POSIX commands use Bash argv quoting"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_env_command DOMAIN service.example.test '.\scripts\orchestrate.ps1' verify runtime)" "\$env:DOMAIN = 'service.example.test'; & '.\\scripts\\orchestrate.ps1' 'verify' 'runtime'" "Windows env commands use PowerShell syntax"
assert_equal "$(DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_render_env_command DOMAIN service.example.test bash scripts/orchestrate.sh verify runtime)" "DOMAIN=service.example.test bash scripts/orchestrate.sh verify runtime" "POSIX env commands use Bash syntax"
if DIREXTALK_LOCAL_PATH_STYLE=posix dirextalk_render_env_command 'BAD-NAME' value command >/dev/null 2>&1; then
  echo "environment command renderer must reject invalid variable names" >&2
  exit 1
fi
if DIREXTALK_LOCAL_PATH_STYLE=windows dirextalk_render_env_command '' value command >/dev/null 2>&1; then
  echo "environment command renderer must reject an empty variable name" >&2
  exit 1
fi

echo "local paths ok"
