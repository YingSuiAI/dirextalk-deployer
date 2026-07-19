#!/usr/bin/env bash
# Shared safety gate for tests that resolve agent or Dirextalk home paths.

dirextalk_test_assert_path_isolated() {
  local value=$1 root=$2 label=${3:-path}
  case "$value" in
    "$root"|"$root"/*) return 0 ;;
    *)
      printf '%s escaped test root: %s (root=%s)\n' "$label" "$value" "$root" >&2
      return 1
      ;;
  esac
}

dirextalk_test_assert_isolated_homes() {
  local root=$1 name value
  for name in \
    HOME USERPROFILE HOMEDRIVE APPDATA LOCALAPPDATA XDG_CONFIG_HOME DIREXTALK_HOME TMPDIR \
    ACP_HOME ANTIGRAVITY_HOME AGY_HOME HERMES_HOME CODEX_HOME CLAUDE_HOME CLAUDECODE_HOME \
    GEMINI_HOME CURSOR_HOME COPILOT_HOME DEVIN_HOME IFLOW_HOME KIMI_HOME OPENCODE_HOME \
    OPEN_CODE_HOME PI_CODING_AGENT_DIR PI_HOME QODER_HOME REASONIX_HOME TMUX_HOME OPENCLAW_HOME
  do
    value=$(printenv "$name" 2>/dev/null || true)
    [ -n "$value" ] || {
      echo "$name must be set before running an isolated runtime test" >&2
      return 1
    }
    dirextalk_test_assert_path_isolated "$value" "$root" "$name" || return 1
  done
}

dirextalk_test_isolate_homes() {
  local root=$1 name suffix value
  export HOME="$root/home"
  export USERPROFILE="$root/userprofile"
  export HOMEDRIVE="$root/homedrive"
  export HOMEPATH=/homepath
  export APPDATA="$root/appdata"
  export LOCALAPPDATA="$root/localappdata"
  export XDG_CONFIG_HOME="$root/xdg"
  export DIREXTALK_HOME="$root/dirextalk"
  export TMPDIR="$root/tmp"

  for name in \
    ACP_HOME ANTIGRAVITY_HOME AGY_HOME HERMES_HOME CODEX_HOME CLAUDE_HOME CLAUDECODE_HOME \
    GEMINI_HOME CURSOR_HOME COPILOT_HOME DEVIN_HOME IFLOW_HOME KIMI_HOME OPENCODE_HOME \
    OPEN_CODE_HOME PI_CODING_AGENT_DIR PI_HOME QODER_HOME REASONIX_HOME TMUX_HOME OPENCLAW_HOME
  do
    suffix=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    value="$root/runtime-homes/$suffix"
    export "$name=$value"
  done

  mkdir -p \
    "$HOME" "$USERPROFILE" "$HOMEDRIVE$HOMEPATH" "$APPDATA" "$LOCALAPPDATA" \
    "$XDG_CONFIG_HOME" "$DIREXTALK_HOME" "$TMPDIR" "$root/runtime-homes" || return 1
  dirextalk_test_assert_isolated_homes "$root"
}
