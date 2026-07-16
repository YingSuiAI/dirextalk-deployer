#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# shellcheck disable=SC1091
source scripts/lib/git-bash.sh
ORIGINAL_EXEPATH=${EXEPATH-}

uname() {
  case "${1:-}" in
    -r) printf '%s\n' '6.6.87.2-microsoft-standard-WSL2' ;;
    -s) printf '%s\n' 'Linux' ;;
    *) printf '%s\n' 'Linux' ;;
  esac
}
if ! WSL_INTEROP=1 WSL_DISTRO_NAME=Ubuntu dirextalk_require_git_bash_on_windows; then
  echo "a native WSL2 session must be accepted as a Linux lifecycle host" >&2
  exit 1
fi
unset -f uname

uname() {
  case "${1:-}" in
    -r) printf '%s\n' 'test-kernel' ;;
    -s) printf '%s\n' 'MINGW64_NT-test' ;;
    *) printf '%s\n' 'MINGW64_NT-test' ;;
  esac
}
dirextalk_git_bash_tools_available() { return 1; }
if missing_git_output=$(dirextalk_require_git_bash_on_windows 2>&1); then
  echo "missing Git for Windows must fail the preflight" >&2
  exit 1
fi
unset -f uname dirextalk_git_bash_tools_available
# shellcheck disable=SC1091
source scripts/lib/git-bash.sh
printf '%s\n' "$missing_git_output" | grep -q 'https://git-scm.com/download/win' || {
  echo "missing Git detection must provide the Git for Windows install URL" >&2
  exit 1
}

uname() {
  case "${1:-}" in
    -r) printf '%s\n' 'test-kernel' ;;
    -s) printf '%s\n' 'MSYS_NT-test' ;;
    *) printf '%s\n' 'MSYS_NT-test' ;;
  esac
}
if other_shell_output=$(dirextalk_require_git_bash_on_windows 2>&1); then
  echo "non-Git Windows Bash environments must be rejected" >&2
  exit 1
fi
unset -f uname
printf '%s\n' "$other_shell_output" | grep -q 'Git Bash only' || {
  echo "non-Git Windows Bash rejection must require Git Bash" >&2
  exit 1
}

git() {
  case "${1:-}" in
    --version) printf '%s\n' 'git version 2.50.1.windows.1' ;;
    --exec-path) printf '%s\n' 'C:/Git/mingw64/libexec/git-core' ;;
    *) return 2 ;;
  esac
}
cygpath() {
  [ "${1:-}" = -m ] || return 2
  case "${2:-}" in
    'C:\msys64\usr\bin') printf '%s\n' 'C:/msys64/usr/bin' ;;
    'C:/Git/mingw64/libexec/git-core') printf '%s\n' 'C:/Git/mingw64/libexec/git-core' ;;
    /usr/bin/bash) printf '%s\n' 'C:/msys64/usr/bin/bash.exe' ;;
    /mingw64/bin/git) printf '%s\n' 'C:/Git/mingw64/bin/git.exe' ;;
    /usr/bin/cygpath) printf '%s\n' 'C:/Git/usr/bin/cygpath.exe' ;;
    *) return 2 ;;
  esac
}
type() {
  if [ "${1:-}" = -P ]; then
    case "${2:-}" in
      bash) printf '%s\n' /usr/bin/bash ;;
      git) printf '%s\n' /mingw64/bin/git ;;
      cygpath) printf '%s\n' /usr/bin/cygpath ;;
      *) return 1 ;;
    esac
    return 0
  fi
  command type "$@"
}
EXEPATH='C:\msys64\usr\bin'
export EXEPATH
if dirextalk_git_bash_tools_available; then
  echo "a MINGW shell outside the Git for Windows installation must be rejected" >&2
  exit 1
fi
unset -f git cygpath type
if [ -n "$ORIGINAL_EXEPATH" ]; then
  export EXEPATH="$ORIGINAL_EXEPATH"
else
  unset EXEPATH
fi

case "$(uname -s 2>/dev/null || true)" in
  *MINGW*|*MSYS*|*CYGWIN*) ;;
  *)
    echo "Git Bash Windows contract test skipped on non-Windows host"
    exit 0
    ;;
esac

command -v git >/dev/null 2>&1 || {
  echo "Git Bash must provide git" >&2
  exit 1
}
command -v cygpath >/dev/null 2>&1 || {
  echo "Git Bash must provide cygpath" >&2
  exit 1
}

# shellcheck disable=SC1091
dirextalk_require_git_bash_on_windows

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-git-bash-contract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
unset DIREXTALK_HOME DIREXTALK_WORKDIR DIREXTALK_WINDOWS_HOME DIREXTALK_LOCAL_PATH_STYLE
mkdir -p "$HOME"

# shellcheck disable=SC1091
source scripts/lib/paths.sh

expected_home=$(cygpath -m "$HOME/.dirextalk")
actual_home=$(dirextalk_home)
[ "$actual_home" = "$expected_home" ] || {
  echo "Git Bash default home must be native for Windows Node consumers: expected $expected_home, got $actual_home" >&2
  exit 1
}

export DIREXTALK_WORKDIR="$tmp/explicit-workdir"
expected_workdir=$(cygpath -m "$DIREXTALK_WORKDIR")
# shellcheck disable=SC1091
source scripts/lib/state.sh
[ "$DIREXTALK_WORKDIR" = "$expected_workdir" ] || {
  echo "Git Bash explicit workdir must be native for Windows Node consumers" >&2
  exit 1
}
[ "$STATE_JSON" = "$expected_workdir/state.json" ] || {
  echo "state.json must use the normalized Git Bash workdir" >&2
  exit 1
}

unset DIREXTALK_WORKDIR
service_dir="$expected_home/nodes/git-bash-status.example.test"
mkdir -p "$service_dir"
node scripts/json.mjs build simple-state \
  domain=git-bash-status.example.test \
  phase=S7_VERIFY_E2E \
  'phases={"S0_PREREQ_AWS":{"status":"done"},"S1_PREFLIGHT":{"status":"done"},"S2_DOMAIN":{"status":"done"},"S3_PROVISION":{"status":"done"},"S4_BOOTSTRAP_STACK":{"status":"done"},"S5_INIT_TOKENS":{"status":"done"},"S6_WIRE_LOCAL":{"status":"done"},"S7_VERIFY_E2E":{"status":"done"}}' \
  > "$service_dir/state.json"

output=$(DOMAIN=git-bash-status.example.test bash scripts/orchestrate.sh status 2>&1)
printf '%s\n' "$output" | grep -q 'S7_VERIFY_E2E        done' || {
  echo "Git Bash status did not read the native Windows state path" >&2
  exit 1
}

echo "Git Bash Windows contract ok"
