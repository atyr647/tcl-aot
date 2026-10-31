# Using tcl-aot

## Requirements

* Tcl **8.6.14**, built as a static library from its own source tree.  The generated code uses Tcl's internal headers (`tclInt.h`, `tclCompile.h`), so it is
  valid for exactly one Tcl release; a module refuses to load into any other.  `make tcl` downloads, verifies and builds the release for you.
* A C compiler (gcc or clang), GNU make, curl, `ld` and `objcopy` (for split builds).  Linux on x86-64 is what is tested.
* The program must be able to embed Tcl: the compiled code is linked into the executable together with libtcl.  A script run by an ordinary `tclsh` cannot
  load a module (a shared-library build is not supported).

## Build

```
make tcl        # build/tcl8.6.14 (sources, sha256-checked) and build/tcl-obj/libtcl8.6.a
make shell      # build/tcl-aot-sh, the shell the translator runs in
```

To use a Tcl you built yourself, give the source tree and the (out-of-tree) build directory: `make shell TCL_SRC=/path/tcl8.6.14 TCL_OBJ=/path/build`.  The scripts
in `tools/` read the same two variables (see `tools/env.sh`).  The compile flags that decide how Tcl objects are allocated are taken from the build's
`tclConfig.sh`.

## Translate

```
build/tcl-aot-sh src/translate.tcl procs.tcl module.c InitName [-hints file] [-untyped] [-split N]
```

(`tcl-aot-sh` needs `TCL_LIBRARY` to point at the `library` directory of the Tcl sources: `. tools/env.sh` sets it.)

`procs.tcl` is sourced by the translator; every proc it defines, in any namespace, is a candidate.  It can `package require` libraries and define procs in
loops (`foreach name {a b c} { proc $name ... }`): what matters is the proc definitions that exist after the file has run.  Procs the translator cannot
handle are left to the interpreter and listed with a reason on stderr (the same reason is available at run time from `tbc::report`).

| option | effect |
|---|---|
| `-hints file` | extra entry signatures to generate typed code for: lines of `procname II ID DI`, one letter per argument (`I` int, `D` double, `B` object). Without a hint a proc gets an all-int and a generic variant, and the variants its callers need |
| `-untyped` | boxed code only |
| `-split N` | write the typed and the boxed code as N files each, to be built in parallel with `tools/build-module.sh`; for large modules (one of 694 procs and 1321 typed variants, 20 MB of C, builds in 28 s instead of 158 s on four cores) |

`TBC_CENSUS=1` prints which procs can be translated and stops; `TBC_DEADOPS=1` logs every instruction at which typed code gives up, which is the place to
look when a hot proc is slower than expected.

`TBC_REPORT=1` prints one line per variant of every proc to stderr: its instructions, how many of them have typed code, how many of those can hand over to the boxed
code when a check fails ("guarded": an operand that is not the kind the code assumes, an overflow, a variable with a trace), the instructions typed code has no code
for at all ("unsupported": it hands over there every time, and what follows runs boxed), the kinds of the locals and of the result:

    REPORT ::h_sum/Bw      17 instructions,  12 typed (70%),   3 guarded, 0 unsupported; returns B; locals l=B s=W v=B
    REPORT ::u_dict/B      31 instructions,   5 typed (16%),   1 guarded, 1 unsupported; returns B; locals d=B n=I k=B v=B #4=B #5=B
    REPORT     unsupported: dictFirst@12

(`#4` is a temporary the compiler made; the number after `@` is the instruction.)  What the compiled code did at run time is in `tbc::hot`, below.

## Link

The module is plain C: compile it with Tcl's headers and `include/`, with the macros of the Tcl build, and link it with libtcl.

```
. tools/env.sh
cc -O2 $TBC_INC module.c main.c $TBC_LIBS -o program
```

`tools/module-shell.c` is a complete `main` for a tclsh with one module (`-DMODULE=InitName`).  In your own `main`, call `InitName_Init(interp)` after
`Tcl_Init`, or register it with `Tcl_StaticPackage` and `load {} InitName` from a script.  Do this *before* the program defines the procs: a proc defined
earlier is not attached (the report lists it as `early`).

For a split module: `tools/build-module.sh module.c module.o` produces one object file that exports only `InitName_Init`.

`examples/run.sh` does all of this for `examples/collatz.tcl`.

## What the program sees

Nothing changes in the program.  Procs are defined and called as before; the compiled body is attached when the proc is first called (or defined, with
`tbc::attach eager` or `TBC_EAGER=1`).  Results, return codes, error messages, `errorInfo`, `errorCode`, `errorLine`, `info body`, `info args`, `info
frame`, `info level`, traces and coroutines behave as with the interpreter alone; the test suite compares them.

The module adds commands in the `::tbc` namespace:

| command | |
|---|---|
| `tbc::report ?-text?` | what became of every proc definition the module has seen: compiled (with call counts), waiting for its first call, left to the interpreter and why. As a dict, or as text |
| `tbc::hot ?-top n? ?-dict? ?-reset?` | in a module built with `-DTBC_COV` only (a measuring build: a counter per entry and per hand-over site, no other change): for every proc how often typed code was entered (by variant), how often it was entered again at a loop head from the boxed code, how often it handed over at an instruction and after a call, and the `n` instructions (default 5) it handed over at most often, with `unsupported` (no typed code for that instruction) or `guard` (a check failed). `-dict` gives it as a dict, `-reset` zeroes the counters. Without `-DTBC_COV` the command does not exist and the code has no counters |
| `tbc::attached` | the names of the procs that have a compiled body attached |
| `tbc::attach eager\|lazy\|status` | when compiled bodies are attached |
| `tbc::profile on\|off\|reset\|status` | count the calls of procs left to the interpreter and the scripts evaluated at run time (`eval`, `uplevel`, `source`...). It runs a Tcl trace on every command: a measuring tool, not for production |
| `tbc::capture on\|off\|clear\|count\|get\|write path` | record the definitions of procs the module has no code for, as `proc` commands. Translating that file and linking the result in gives procs a program builds at run time (from `regsub`, `string map`...) their compiled bodies; `tests/capture.sh` is the whole loop |
| `tbc::fingerprint`, `tbc::invalidate`, `tbc::lazy` | internal |

## Limits

* One Tcl release (8.6.14).  Porting to another 8.6.x release means running the test suite against it and relaxing the patch-level check in `tbc_check_build`.
* Procs whose bytecode is shorter than the entry stub stay with the interpreter (a body of one or two instructions runs faster interpreted).  `tailcall` is
  compiled.  Inside a coroutine, a proc that cannot yield runs compiled (it calls only built-in commands that run no script, and procs of that kind that are still
  the compiled ones), and so does a proc that yields itself when everything else it runs is of that kind: its boxed code suspends the coroutine through the
  interpreter's callbacks and, where a loop without a yield can follow, typed code is entered again after the yield.  A proc that yields inside a `dict for`
  or an argument expansion stays interpreted, as does any other proc inside a coroutine.
* A proc is compiled only if the program defines it with exactly the namespace, argument list and body the translator saw.
* Translation time: about linear in the size of a proc (2000 statements: 23 s; one generated proc of 71000 lines: 67 s), but the typed analysis grows somewhat faster than linearly, so a generated proc of a megabyte takes
  minutes.  A module of 6840 procs (all of tcllib) translates in chunks of a few hundred procs in 20 to 40 seconds each.
* Compiled code recurses on the C stack. `TBC_NEST_CAP` (a macro to define when compiling the module; default off natively and 200 when compiling for WebAssembly)
  hands calls past that many live compiled entries to the interpreter, which has its own stack. A WebAssembly guest has 512 KiB of call stack by default.
* Typed code stops at instructions it does not implement and continues in boxed code: `dict for`, `lmap`, `unset`, `lsort`, commands
  that name variables, and calls of commands not known to leave the caller's variables alone (`TBC_DEADOPS=1` lists them for your procs).  Boxed code
  is about as fast as the interpreter.
* Redefining a command a compiled proc depends on (a callee, or a core command the compiler inlined) is handled: calls fall back or the proc is demoted.
  A built-in a proc was compiled against that is shadowed, aliased, imported, hidden or replaced is noticed when the proc is next entered (decisions 19); a replacement made by the proc itself while it runs is checked only by the tests listed in decisions 19.
