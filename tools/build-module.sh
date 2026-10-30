#!/bin/bash
# Build a module written by `translate.tcl ... -split N` into one object file.
#
#   tools/build-module.sh <module.c> <out.o> [-j N]
#
# The typed code (<module>_v*.c) is compiled with CFLAGS_V (default -O2), the boxed code (<module>_g*.c) with CFLAGS_G (-Og with gcc, -O1 with
# clang), the tables and Init (<module>.c) with CFLAGS_I (-O1), all in parallel.  The parts are linked with `ld -r` into one relocatable object
# that exports only <Init>_Init, so that two modules in one program cannot clash.  With MERGE=0 the parts are left in an archive <out>.a instead
# (for a toolchain whose linker has no relocatable output).
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <module.c> <out.o> [-j N]" >&2; exit 2; }
mod=$1
out=$2
jobs=$(nproc 2>/dev/null || echo 4)
[ "${3:-}" = "-j" ] && jobs=${4:?"-j needs a number"}

. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
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

for f in "$base"_v*.c; do
  compile "$CFLAGS_V" "$f" &
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
done
for f in "$base"_g*.c "$mod"; do
  flags=$CFLAGS_G; [ "$f" = "$mod" ] && flags=$CFLAGS_I
  compile "$flags" "$f" &
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
done
while [ "$(jobs -rp | wc -l)" -gt 0 ]; do wait -n; done

if [ "${MERGE:-1}" = 1 ]; then
  ld -r -o "$tmp/all.o" "$tmp"/*.o
  objcopy --keep-global-symbol="$init" "$tmp/all.o" "$out"
else
  rm -f "${out%.o}.a"
  ar rcs "${out%.o}.a" "$tmp"/*.o
fi
