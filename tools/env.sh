# Locations and compiler flags shared by the scripts of this repository.  Source this file; override any variable from the environment.
#
#   TCL_SRC   the unpacked Tcl 8.6.14 source tree (its internal headers are compiled against)
#   TCL_OBJ   the directory libtcl8.6.a was built in (out of tree, from TCL_SRC)
#   BUILD     where this repository puts what it builds
# `make tcl` fetches and builds Tcl into the defaults below.

TBC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD=${BUILD:-$TBC_ROOT/build}
TCL_SRC=${TCL_SRC:-$BUILD/tcl8.6.14}
TCL_OBJ=${TCL_OBJ:-$BUILD/tcl-obj}
CC=${CC:-cc}
export TCL_LIBRARY=${TCL_LIBRARY:-$TCL_SRC/library}

if [ ! -f "$TCL_OBJ/tclConfig.sh" ] || [ ! -f "$TCL_SRC/generic/tclInt.h" ]; then
  echo "tcl-aot: no Tcl 8.6.14 build found (TCL_SRC=$TCL_SRC, TCL_OBJ=$TCL_OBJ); run 'make tcl' or set both variables" >&2
  return 1 2>/dev/null || exit 1
fi

# The macros of Tcl's headers that decide how objects are allocated and laid out must match the build of libtcl: take them from its tclConfig.sh.
. "$TCL_OBJ/tclConfig.sh"
TBC_DEFS=""
for d in TCL_THREADS USE_THREAD_ALLOC _REENTRANT TCL_WIDE_INT_IS_LONG TCL_MEM_DEBUG; do
  case " $TCL_DEFS " in *" -D$d=1 "*) TBC_DEFS="$TBC_DEFS -D$d=1" ;; esac
done
# compile flags for generated code, the libraries to link, and the shell translate.tcl runs in
TBC_INC="-I$TCL_SRC/generic -I$TCL_SRC/unix -I$TBC_ROOT/include$TBC_DEFS"
TBC_LIBS="$TCL_OBJ/libtcl8.6.a $TCL_LIBS"
TCLSH=${TCLSH:-$BUILD/tcl-aot-sh}

# Portability helpers: GNU `timeout` and `sha256sum` are not on a stock macOS (they come with coreutils), so fall back to what the system has.
# TBC_TIMEOUT is a command prefix (empty when there is no timeout command: the run is then not limited); tbc_sha256_check is `sha256sum -c --quiet`.
if command -v timeout >/dev/null 2>&1; then TBC_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then TBC_TIMEOUT=gtimeout
else TBC_TIMEOUT=""; fi
tbc_sha256_check() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c --quiet "$@"; else shasum -a 256 -c --quiet "$@"; fi
}
