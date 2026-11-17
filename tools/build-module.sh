#!/bin/sh
# Build a module written by `translate.tcl ... -split N` into one object file.
#
#   tools/build-module.sh <module.c> <out.o> [-j N]
#
# The typed code (<module>_v*.c) is compiled with CFLAGS_V (default -O2), the boxed code (<module>_g*.c) with CFLAGS_G (-Og with gcc, -O1 with
# clang), the tables and Init (<module>.c) with CFLAGS_I (-O1), all in parallel.  The parts are linked with `ld -r` into one relocatable object
# that exports only <Init>_Init, so that two modules in one program cannot clash.  With MERGE=0 the parts are left in an archive <out>.a instead
# (for a toolchain whose linker has no relocatable output).
#
# POSIX sh: the parallelism is a pool of tokens in a FIFO (`mkfifo`, `exec 3<>`), so no `wait -n`, no `jobs -p`, no polling.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 <module.c> <out.o> [-j N]" >&2; exit 2; }
mod=$1
out=$2
jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
[ "${3:-}" = "-j" ] && jobs=${4:?"-j needs a number"}

TBC_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$TBC_ROOT/tools/env.sh"
if "$CC" --version 2>/dev/null | grep -qi clang; then boxed_default=-O1; else boxed_default=-Og; fi
CFLAGS_V=${CFLAGS_V:--O2}
CFLAGS_G=${CFLAGS_G:-$boxed_default}
CFLAGS_I=${CFLAGS_I:--O1}

base=${mod%.c}
init=$(grep -o -m1 '^int [A-Za-z0-9_]*_Init' "$mod" | awk '{print $2}')
[ -n "$init" ] || { echo "$0: no Init function found in $mod" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

compile() {
  # shellcheck disable=SC2086  # the flag variables hold several words
  "$CC" $1 -w $TBC_INC -I"$(dirname "$mod")" -c "$2" -o "$tmp/$(basename "${2%.c}").o"
}

# a token pool: one token per job that may run at once; a job takes one before it starts and puts it back when it ends (also when it fails)
mkfifo "$tmp/tokens"
exec 3<>"$tmp/tokens"
n=0
while [ "$n" -lt "$jobs" ]; do echo >&3; n=$((n + 1)); done
n=0
for f in "$base"_v*.c "$base"_g*.c "$mod"; do
  flags=$CFLAGS_V
  case $f in "$base"_g*.c) flags=$CFLAGS_G ;; "$mod") flags=$CFLAGS_I ;; esac
  read -r _ <&3
  if [ -f "$tmp/failed" ]; then break; fi
  n=$((n + 1))
  ( compile "$flags" "$f" || : > "$tmp/failed"; echo >&3 ) &
done
wait
if [ -f "$tmp/failed" ]; then echo "$0: a compile failed" >&2; exit 1; fi

if [ "${MERGE:-1}" = 1 ]; then
  # one relocatable object that exports only <Init>_Init: the one place where platforms differ (Mach-O has no objcopy; its linker has the switch)
  case "$(uname -s)" in
    Darwin) ld -r -exported_symbol "_$init" -o "$out" "$tmp"/*.o ;;
    *)      ld -r -o "$tmp/all.o" "$tmp"/*.o
            objcopy --keep-global-symbol="$init" "$tmp/all.o" "$out" ;;
  esac
else
  rm -f "${out%.o}.a"
  ar rcs "${out%.o}.a" "$tmp"/*.o
fi
