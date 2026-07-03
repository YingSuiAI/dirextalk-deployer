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

echo "local paths ok"
