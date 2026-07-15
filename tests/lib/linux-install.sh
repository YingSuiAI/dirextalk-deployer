#!/usr/bin/env bash
# Emulate the limited GNU install contract used by remote-Ubuntu updater tests
# only when Git Bash cannot express Linux ownership modes. Native Linux keeps
# using its real install binary, including its permission semantics.
set -euo pipefail

case "$(uname -s 2>/dev/null || printf unknown)" in
  *MINGW*|*MSYS*|*CYGWIN*) ;;
  *)
    last=${!#}
    if [ -n "${DIREXTALK_TEST_INSTALL_FAIL_PATTERN:-}" ] \
      && [[ "$last" == ${DIREXTALK_TEST_INSTALL_FAIL_PATTERN} ]]; then
      exit "${DIREXTALK_TEST_INSTALL_FAIL_CODE:-1}"
    fi
    real_install=${DIREXTALK_TEST_REAL_INSTALL:-/usr/bin/install}
    [ -x "$real_install" ] || { echo "missing native install binary: $real_install" >&2; exit 127; }
    exec "$real_install" "$@"
    ;;
esac

directory=0
mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) directory=1; shift ;;
    -m) mode=${2:?missing install mode}; shift 2 ;;
    --) shift; break ;;
    -*) echo "unsupported fake install option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

[ "$#" -gt 0 ] || { echo "missing fake install destination" >&2; exit 2; }
last=${!#}
if [ -n "${DIREXTALK_TEST_INSTALL_FAIL_PATTERN:-}" ] \
  && [[ "$last" == ${DIREXTALK_TEST_INSTALL_FAIL_PATTERN} ]]; then
  exit "${DIREXTALK_TEST_INSTALL_FAIL_CODE:-1}"
fi

if [ "$directory" = 1 ]; then
  for destination in "$@"; do
    mkdir -p "$destination"
    [ -z "$mode" ] || chmod "$mode" "$destination" 2>/dev/null || true
  done
  exit 0
fi

[ "$#" = 2 ] || { echo "fake install expects source and destination" >&2; exit 2; }
cp -- "$1" "$2"
[ -z "$mode" ] || chmod "$mode" "$2" 2>/dev/null || true
