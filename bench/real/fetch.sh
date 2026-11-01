#!/bin/bash
# Fetch tclbench (the Tcl community's benchmark programs, Tcl license) into build/tclbench; they are not part of this repository.
cd "$(dirname "$0")/../.." || exit 1
mkdir -p build/tclbench && curl -sSf -m 60 -o build/tclbench.tgz https://core.tcl-lang.org/tclbench/tarball/trunk/tclbench.tar.gz && tar -xzf build/tclbench.tgz -C build/tclbench && ls build/tclbench/tclbench/tcl/*.bench | wc -l
