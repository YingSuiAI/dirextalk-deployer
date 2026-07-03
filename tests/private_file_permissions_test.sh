#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
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
printf 'ADAM\\84960\r\n'
EOF
chmod 700 "$tmp/bin/powershell.exe"

cat > "$tmp/bin/icacls" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ICACLS_LOG"
EOF
chmod 700 "$tmp/bin/icacls"

export PATH="$tmp/bin:$PATH"
export USERDOMAIN=ADAM
export ICACLS_LOG="$tmp/icacls.log"

# shellcheck disable=SC1090
source "$ROOT/scripts/lib/state.sh"

key="$tmp/key.pem"
printf 'PRIVATE KEY\n' > "$key"
restrict_private_file "$key"

grep -Fq '/inheritance:r' "$ICACLS_LOG"
grep -Fq 'ADAM\CodexSandboxUsers' "$ICACLS_LOG"
grep -Fq 'NT AUTHORITY\SYSTEM:F' "$ICACLS_LOG"
grep -Fq 'BUILTIN\Administrators:F' "$ICACLS_LOG"
grep -Fq 'ADAM\84960:F' "$ICACLS_LOG"

echo "private file permissions ok"
