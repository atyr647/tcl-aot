# tcl-aot: build the Tcl the generated code is compiled against, the translator shell, and run the tests.
#
#   make tcl      download Tcl 8.6.14, check its sha256, unpack it and build a static libtcl (out of tree) under build/
#   make shell    build build/tcl-aot-sh, the shell translate.tcl runs in
#   make test     run the whole test suite (tests/run.sh); make test-quick runs the differential, report and proc wrapper tests only
#   make bench    time the benchmark procs, interpreter alone against compiled
#   make clean    remove build/ (the downloaded tarball stays); make distclean removes the tarball too
#
# To use a Tcl 8.6.14 of your own instead of the downloaded one, set TCL_SRC (its source tree) and TCL_OBJ (the directory it was built in, out of tree).

SHELL := /bin/bash

TCL_VERSION := 8.6.14
TCL_SHA256  := 5880225babf7954c58d4fb0f5cf6279104ce1cd6aa9b71e9a6322540e1c4de66
TCL_URL     := https://downloads.sourceforge.net/project/tcl/Tcl/$(TCL_VERSION)/tcl$(TCL_VERSION)-src.tar.gz

BUILD    ?= $(CURDIR)/build
TCL_SRC  ?= $(BUILD)/tcl$(TCL_VERSION)
TCL_OBJ  ?= $(BUILD)/tcl-obj
TARBALL  := $(BUILD)/tcl$(TCL_VERSION)-src.tar.gz
export BUILD TCL_SRC TCL_OBJ

.PHONY: all tcl shell test test-quick bench clean distclean

all: shell

tcl: $(TCL_OBJ)/libtcl8.6.a

$(TARBALL):
	mkdir -p $(BUILD)
	curl -fsSL -o $@.part $(TCL_URL)
	echo "$(TCL_SHA256)  $@.part" | sha256sum -c --quiet -
	mv $@.part $@

$(TCL_SRC)/generic/tclInt.h: $(TARBALL)
	mkdir -p $(dir $(TCL_SRC))
	tar -xzf $(TARBALL) -C $(dir $(TCL_SRC))
	test -f $@ && touch $@

$(TCL_OBJ)/libtcl8.6.a: $(TCL_SRC)/generic/tclInt.h
	mkdir -p $(TCL_OBJ)
	cd $(TCL_OBJ) && $(TCL_SRC)/unix/configure --disable-shared > configure.log 2>&1
	$(MAKE) -s -C $(TCL_OBJ) libtcl8.6.a

shell: $(BUILD)/tcl-aot-sh

$(BUILD)/tcl-aot-sh: tools/translator-shell.c include/tbc_hook.h include/tbc_runtime.h $(TCL_OBJ)/libtcl8.6.a
	. tools/env.sh && $$CC -O1 -w $$TBC_INC tools/translator-shell.c $$TBC_LIBS -o $@

test: shell
	tests/run.sh

test-quick: shell
	tests/run.sh quick

bench: shell
	bench/run.sh

clean:
	rm -rf $(BUILD)/tcl-obj $(BUILD)/tcl$(TCL_VERSION) $(BUILD)/tcl-aot-sh

distclean:
	rm -rf $(BUILD)
