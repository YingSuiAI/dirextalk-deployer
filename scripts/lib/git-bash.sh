#!/usr/bin/env bash
# git-bash.sh - public Windows shell contract.

dirextalk_git_bash_tools_available() {
  local git_version git_exec_path git_root exe_path bash_path git_path cygpath_path
  command -v git >/dev/null 2>&1 || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  git_version=$(git --version 2>/dev/null || true)
  case "$git_version" in *'.windows.'*) ;; *) return 1 ;; esac

  # MSYS2 may also advertise MINGW64 and expose a Git for Windows git.exe.
  # Require Bash, Git, cygpath, and EXEPATH to belong to the same Git for
  # Windows installation root before accepting the public Windows entrypoint.
  git_exec_path=$(git --exec-path 2>/dev/null || true)
  git_exec_path=$(cygpath -m "$git_exec_path" 2>/dev/null || true)
  case "$git_exec_path" in
    */mingw64/libexec/git-core) git_root=${git_exec_path%/mingw64/libexec/git-core} ;;
    *) return 1 ;;
  esac
  [ -n "${EXEPATH:-}" ] || return 1
  exe_path=$(cygpath -m "$EXEPATH" 2>/dev/null || true)
  bash_path=$(cygpath -m "$(type -P bash 2>/dev/null || true)" 2>/dev/null || true)
  git_path=$(cygpath -m "$(type -P git 2>/dev/null || true)" 2>/dev/null || true)
  cygpath_path=$(cygpath -m "$(type -P cygpath 2>/dev/null || true)" 2>/dev/null || true)

  git_root=$(printf '%s' "$git_root" | tr '[:upper:]' '[:lower:]')
  exe_path=$(printf '%s' "$exe_path" | tr '[:upper:]' '[:lower:]')
  bash_path=$(printf '%s' "$bash_path" | tr '[:upper:]' '[:lower:]')
  git_path=$(printf '%s' "$git_path" | tr '[:upper:]' '[:lower:]')
  cygpath_path=$(printf '%s' "$cygpath_path" | tr '[:upper:]' '[:lower:]')
  [ "$exe_path" = "$git_root/bin" ] || return 1
  case "$bash_path:$git_path:$cygpath_path" in
    "$git_root"/*:"$git_root"/*:"$git_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

dirextalk_require_git_bash_on_windows() {
  case "${WSL_INTEROP:-}${WSL_DISTRO_NAME:-}" in
    ?*)
      printf '%s\n' "Dirextalk on Windows uses Git Bash only. Install Git for Windows from https://git-scm.com/download/win, open Git Bash, and rerun this command." >&2
      return 1
      ;;
  esac
  case "$(uname -r 2>/dev/null || printf unknown)" in
    *[Mm]icrosoft*|*[Ww][Ss][Ll]*)
      printf '%s\n' "Dirextalk on Windows uses Git Bash only. Install Git for Windows from https://git-scm.com/download/win, open Git Bash, and rerun this command." >&2
      return 1
      ;;
  esac
  case "$(uname -s 2>/dev/null || printf unknown)" in
    *MSYS*|*CYGWIN*)
      printf '%s\n' "Dirextalk on Windows uses Git Bash only. Install Git for Windows from https://git-scm.com/download/win, open Git Bash, and rerun this command." >&2
      return 1
      ;;
    *MINGW*)
      if ! dirextalk_git_bash_tools_available; then
        printf '%s\n' "Git for Windows is required for Dirextalk on Windows. Install it from https://git-scm.com/download/win, open Git Bash, and rerun this command." >&2
        return 1
      fi
      ;;
  esac
}
