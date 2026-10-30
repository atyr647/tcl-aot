# tcl-aot

Ahead-of-time compilation of Tcl procs to C, for programs that embed Tcl 8.6.

`tcl-aot` reads the bytecode that stock Tcl 8.6.14 compiles for your procs and writes C.  You link that C into your program next to a static libtcl.
When the program defines a proc the module has compiled code for, the module attaches the code to that proc.  The program is not changed, Tcl is not
changed, and the proc stays a proc: `info body`, `info frame`, error messages, `errorInfo`, traces, coroutines and `rename` behave as with the
interpreter alone.  The test suite compares result, return code, error code and error info over about 9000 calls, and the fuzzers over 49,000 random
calls per seed.

Integer and floating-point loops, and loops over arrays and variables reached by `upvar`, `global` and `variable`, run as C.  Code that spends its time
in Tcl's own library (regular expressions, list and string commands, hash tables) runs at about interpreter speed, because it calls the same library.

Status: experimental.  Tcl 8.6.14 on Linux/x86-64 is what the test suite runs on.  The suite was also run as a wasm32-wasip3 guest (see decision 11 in
`docs/decisions.md`); the build recipe for that is not part of this repository.

## Try it

```
make tcl shell          # downloads Tcl 8.6.14, checks its sha256, builds a static libtcl and the translator shell under build/
examples/run.sh         # translates examples/collatz.tcl, links it, runs main.tcl with the interpreter alone and compiled
```

On the machine this was written on, `examples/run.sh` prints something like:

```
-- interpreter alone
26623 307
322 ms
-- compiled
26623 307
16 ms
procs run compiled: 2 (30000 calls; ...)
```

Wall-clock times vary; `bench/run.sh count` counts instructions instead:

| benchmark | interpreter / compiled (instructions) |
|---|---|
| integer loop with arithmetic | 33.9x |
| counter through `global` | 10.2x |
| counter in a namespace variable | 8.6x |
| counter through `upvar` | 6.6x |
| array histogram | 5.2x |
| array sieve | 2.1x |
| namespace array fill | 2.1x |
| array Fibonacci | 1.8x |
| matrix product over a 2-D array | 1.7x |

On thirteen tcllib-based workloads (sha1, md5, regexp-heavy text splitting, JSON and CSV parsing, `struct::list`, ...) compiled code is between 0.7x and 1.2x
of the interpreter: the time is in Tcl's library.  `docs/decisions.md` has the numbers and what was tried.

## Use it on your program

```
build/tcl-aot-sh src/translate.tcl myprocs.tcl mymodule.c MyModule        # translate (. tools/env.sh sets TCL_LIBRARY)
. tools/env.sh
cc -O2 -DMODULE=MyModule $TBC_INC tools/module-shell.c mymodule.c $TBC_LIBS -o myshell
```

Then, in the script `myshell` runs, `load {} MyModule` before the procs are defined.  `tbc::report -text` says which procs run compiled and why the others
do not.  Everything is in `docs/usage.md`.

## How it works, briefly

The translator infers, for every proc, which locals and stack slots hold machine integers or doubles and keeps them in C variables; the rest follows the
bytecode executor instruction by instruction, with the same reference counting.  When an assumption fails at run time (integer overflow, a non-numeric
operand, a trace on a variable, an instruction the typed code does not implement) the call continues in the second form at the same instruction.  Compiled
code is attached to a proc only while the bytecode the interpreter would run for it is the one that was translated.  See `docs/design.md`.

## Limits

* Valid for one Tcl release (8.6.14); a module refuses to load into another.  It uses Tcl's internal headers, so Tcl must be built as a static library.
* Procs containing `yield`, `yieldto` or `tailcall`, and procs shorter than the entry stub, stay interpreted; calls inside a coroutine use the interpreter.
* Typed code stops, and boxed code (about interpreter speed) continues, at `foreach`, `lmap`, `switch`, `catch`, `try`, `unset`, math functions such as
  `sqrt` and `int`, and commands that name variables.  `TBC_DEADOPS=1` lists the places for your procs.

## Tests

```
make test-quick        # about a minute: the differential test (interpreter against compiled), report and proc-wrapper tests, split and single-file builds
make test              # adds the build guard, recursion caps, capture loop, unmodified-Tcl check, fuzzing, valgrind if installed
```

## Layout

```
src/translate.tcl   the translator            include/    runtime headers the generated C includes
tools/              environment, shells, module build script      tests/    differential tests and checks
fuzz/               random programs against the interpreter       bench/    benchmark procs and runner
examples/           a small program, translated and run            docs/     design, usage, decisions
```

## License

MIT, see `LICENSE`.  Tcl is built from its own sources, which carry the Tcl license; they are not part of this repository.
