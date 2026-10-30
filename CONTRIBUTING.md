# Contributing

* `make test-quick` must pass before a change is proposed, and `make test` for anything that touches the translator or the runtime.  The central test,
  `tests/differential.tcl`, runs every call with the interpreter alone and with the compiled module and requires identical results, return codes, error
  codes and error info; a new construct or fast path needs procs and calls there that exercise it *and* its fall-backs (a trace on the variable, an
  operand of the wrong type, an error after a side effect).
* Behaviour that the interpreter has must be kept exactly; where it cannot be, write down the difference and the reason in `docs/decisions.md` with a test
  that shows its extent.
* Claims about speed need a number that someone else can reproduce: `bench/run.sh count` counts instructions and does not depend on the load of the machine.
* Tcl and its libraries are not modified, patched or vendored.  `tests/pristine.sh` checks the tree the code is built against.
* Shell scripts are bash; C is C99 with GNU extensions (`__builtin_*`, `always_inline`); Tcl is 8.6.
