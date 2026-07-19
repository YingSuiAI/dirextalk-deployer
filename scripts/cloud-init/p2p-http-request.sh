#!/bin/sh
# Send one complete raw HTTP request received on stdin to the local P2P
# listener. BusyBox wget cannot read a protected config from stdin and would
# put an Authorization header in argv, so keep the bearer only in this pipe.
set -eu

umask 077
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dirextalk-p2p.XXXXXX")
request_file="$work_dir/request"
response_file="$work_dir/response"
request_pipe="$work_dir/request.pipe"

cleanup() {
  exec 3>&- 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

cat > "$request_file"
[ -s "$request_file" ] || exit 1
mkfifo "$request_pipe"

# Hold the write end open only until the HTTP response headers arrive. BusyBox
# nc otherwise closes the TCP connection as soon as stdin reaches EOF, which
# cancels an in-process P2P handler before it can write its response.
exec 3<> "$request_pipe"
nc -w 20 127.0.0.1 8008 < "$request_pipe" > "$response_file" &
nc_pid=$!
cat "$request_file" >&3

headers_ready=0
attempt=0
while [ "$attempt" -lt 150 ]; do
  if awk 'BEGIN { found=0 } { sub(/\r$/, ""); if ($0 == "") { found=1; exit } } END { exit(found ? 0 : 1) }' "$response_file"; then
    headers_ready=1
    break
  fi
  if ! kill -0 "$nc_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
exec 3>&-

if ! wait "$nc_pid" || [ "$headers_ready" -ne 1 ]; then
  exit 1
fi

status=$(awk 'NR == 1 { sub(/\r$/, ""); print $2; exit }' "$response_file")
case "$status" in
  2??) ;;
  *) exit 1 ;;
esac

awk 'BEGIN { body=0 } { sub(/\r$/, ""); if (body) print; else if ($0 == "") body=1 }' "$response_file"
