#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export DIREXTALK_HOME="$HOME/.dirextalk"
mkdir -p "$HOME" "$tmp/bin"

cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'MINGW64_NT-10.0\n'
EOF
chmod 700 "$tmp/bin/uname"

cat > "$tmp/bin/cygpath" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-w" ] || exit 2
printf 'C:\\Users\\test\\.dirextalk\\nodes\\svc\\key.pem\n'
EOF
chmod 700 "$tmp/bin/cygpath"

cat > "$tmp/bin/cmd.exe" <<'EOF'
#!/usr/bin/env bash
echo "cmd.exe must not be used for ACL user detection" >&2
exit 42
EOF
chmod 700 "$tmp/bin/cmd.exe"

cat > "$tmp/bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${DIREXTALK_PRIVATE_PATH:-}" "${DIREXTALK_PRIVATE_KIND:-}" "$*" >> "$POWERSHELL_LOG"
[ "${POWERSHELL_FAIL:-0}" != "1" ]
EOF
chmod 700 "$tmp/bin/powershell.exe"

cat > "$tmp/bin/icacls" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ICACLS_LOG"
EOF
chmod 700 "$tmp/bin/icacls"

export PATH="$tmp/bin:$PATH"
export USERDOMAIN=ADAM
export POWERSHELL_LOG="$tmp/powershell.log"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"

key="$tmp/key.pem"
printf 'PRIVATE KEY\n' > "$key"
restrict_private_file "$key"

private_dir="$tmp/private-dir"
mkdir -p "$private_dir"
dirextalk_restrict_private_directory "$private_dir"

grep -Fq 'C:\Users\test\.dirextalk\nodes\svc\key.pem|file|' "$POWERSHELL_LOG"
grep -Fq 'C:\Users\test\.dirextalk\nodes\svc\key.pem|dir|' "$POWERSHELL_LOG"
if POWERSHELL_FAIL=1 restrict_private_file "$key" 2>/dev/null; then
  echo "private file ACL failures must propagate" >&2
  exit 1
fi

echo "private file permissions ok"
