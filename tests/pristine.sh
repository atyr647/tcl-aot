#!/bin/bash
# The project never changes Tcl or its libraries.  This checks that what it builds against and loads into is stock:
#  1. the Tcl source tree whose headers and library script directory the generated code is compiled against and run with is byte-identical to the
#     official 8.6.14 release (tests/tcl-8.6.14.sha256 holds the sha256 of every file of generic/, unix/, library/, libtommath/ and tools/ in the
#     release tarball, whose own sha256 is 5880225babf7954c58d4fb0f5cf6279104ce1cd6aa9b71e9a6322540e1c4de66);
#  2. the libtcl that is linked in was configured from that tree and built out of it.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
status=0

bad=$(cd "$TCL_SRC" && sha256sum -c --quiet "$TBC_ROOT/tests/tcl-8.6.14.sha256" 2>&1 | grep -c 'FAILED\|No such')
if [ "$bad" = 0 ]; then
  echo "pristine: $TCL_SRC is identical to the Tcl 8.6.14 release: ok"
else
  echo "pristine: $bad files of $TCL_SRC differ from the Tcl 8.6.14 release: FAILED"; status=1
fi

if [ "$TCL_OBJ" != "$TCL_SRC" ] && grep -q "^TOP_DIR[[:space:]]*=[[:space:]]*$TCL_SRC\$" "$TCL_OBJ/Makefile" 2>/dev/null; then
  echo "pristine: libtcl ($TCL_OBJ) is built out of tree from that source: ok"
else
  echo "pristine: libtcl ($TCL_OBJ) was not built out of tree from $TCL_SRC: FAILED"; status=1
fi
exit $status
