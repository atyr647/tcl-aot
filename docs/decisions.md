# Design decisions

Each entry says what was decided, why, and what was measured.  Timings are from a four-core virtual machine whose wall-clock time varies by 20-50 % from
run to run, so where a number decides something it is an instruction count (`valgrind --tool=callgrind`), which does not.  "tcllib workloads" are
small programs built on tcllib 1.21 packages (sha1, md5, crc32, base64, json, csv, textutil, struct, math::statistics, math::numtheory, uuid); they are not
part of this repository.

## 1. Attach to the program's own procs; never alter Tcl

A compiled body replaces nothing the program can see.  The program defines a proc; the runtime recognises the definition and swaps the in-memory bytecode
of that proc for a stub that calls the compiled code in the proc's own frame (see `design.md`).  The alternative, registering compiled code as new
commands, would change `info procs`, `info body`, argument handling, `rename` and error messages, and every caller that expects a proc.  Tcl's source
tree and library are used unmodified; the module only reads Tcl's internal headers and calls its internal functions, all in memory.  `tests/pristine.sh`
checks that the tree compiled against is byte-identical to the 8.6.14 release and that libtcl was built out of it.

## 2. Input is bytecode, not source

The translator works from `tcl::unsupported::disassemble`.  Source-to-C would have to reimplement the compiler's decisions (constant folding, which
commands are expanded inline, exception ranges, the shape of `foreach`/`switch`/`try`) and would diverge from the interpreter in the cases that matter.
The price is that the output is valid for one Tcl release and that the compiler's output depends on state; both are handled by checks (fingerprints,
the build guard) rather than assumed.

## 3. Compiled code is used only while its bytecode is the interpreter's

The compiler emits different bytecode after a package redefines a core command (`::fileutil::find` compiled to 466 instructions at its definition and 474
once the package set was loaded), or while `string` is hidden.  A fingerprint of the interpreter's bytecode at attach time must equal the translator's;
otherwise the proc stays interpreted.  Attaching at the first call (the default) rather than at definition removes most of these mismatches, because the
interpreter itself compiles a body at its first call, and it is cheaper: loading 20 tcllib packages cost 252 M more instructions with eager attach
(157 M of it compiling bodies that were never called).  The fingerprint includes the exact bits of double literals whose printed form does not parse back to
them (`9223372036854775807 / 0.5` is folded to 2^64, which Tcl prints as `1.844674407370955e+19`, one ulp below), because the literal table shares
objects by text.  A rule that followed: no value whose text matters passes through `expr` in the translator.

## 4. Recursion limit at the exact edge

Typed chains (direct calls) carry a depth register initialised from `maxNestingDepth - numLevels` and fail at exactly the interpreter's level, at every
nesting tested (top level, `eval`, `uplevel`, wrapper procs).  A proc entered from the interpreter at the very last level fails one level early: the
stub's own evaluation is checked by the interpreter before any of our code runs.  The error has the same message and code and the same length of error
info; its topmost entry names the callee's first command instead of the calling command.  Closing this would need a patch to Tcl or a raised
`maxNestingDepth`; neither was acceptable.

## 5. Coroutines, `yield`, `tailcall`

Compiled code runs on the C stack and a coroutine suspends by unwinding the interpreter's own stack, which cannot cross a C frame.  A call that arrives
while a coroutine is running is therefore evaluated by the interpreter (the original body, in the already-built frame, with the stub's nesting level given
back), so a `yield` anywhere below a compiled proc works.  Procs that contain `yield`, `yieldto` or `tailcall` themselves stay interpreted
(about 1 % of procs in the packages measured; 20 of 1731).  Making compiled code resumable would need a state machine at every suspension point for a class of
procs that mostly wait; not built.

## 6. Command frames and error info are the interpreter's

The stub's bytecode keeps the original body's location tables and its pc is moved to the command being run before each command is invoked, so
`info frame`, `-errorinfo` and `-errorline` are equal, including inside coroutines and through `uplevel` and `eval`.  Errors are logged with Tcl's own
`TclLogCommandInfo` from the original bytecode.

## 7. A module is valid only for the Tcl it was compiled against

Generated code compiled without the macros libtcl was built with (`TCL_THREADS`, `USE_THREAD_ALLOC`, `TCL_WIDE_INT_IS_LONG`) took objects from a free list
nothing refills: 80 bytes leaked per loop iteration in boxed code (54 KB per call of `sha1::SHA1Transform`).  `tools/env.sh` takes the macros from the Tcl
build's `tclConfig.sh`; `tbc_check_build`, the first thing every module's Init does, refuses a Tcl whose thread/allocator settings, version or patch level
differ; `tests/guard.sh` builds a module without the macros and requires the refusal; the memory-growth loops of the differential test (`t_leak_g`) fail
by 120 MB when the guard is removed.  Patch-level equality is stricter than the layouts need; only 8.6.14 has been tested.

## 8. Seeing what runs interpreted: `tbc::report`, `tbc::profile`, `tbc::capture`

Whether a program would gain from more compilation depends on what actually runs interpreted, which cannot be known from the source alone.  The three
commands answer it using only Tcl's public interfaces: the report states the fate of every definition (compiled, waiting, `no-code`, `changed`, `differs`,
`refused` with the translator's reason, `demoted`, `early`); the profile counts calls of interpreted procs and scripts evaluated at run time; the capture
writes the procs a program builds at run time as source that can be translated into a second module (`tests/capture.sh`).  Over the tcllib workloads,
320276 calls were of compiled procs and 13 of interpreted ones, and the scripts evaluated at run time were the drivers' own top-level loops; precompiling
literal `eval`/`uplevel` bodies would need the interpreter to accept a bytecode object built for a script, a dependence on Tcl's structures not worth
having for that evidence.  Not done.

## 9. Bodies shorter than the stub stay interpreted

A body of less than 5 bytes of bytecode (the stub is `push1 0; invokeStk1 1; done`) is run faster by the interpreter than by a call into compiled code;
tcllib has several two-to-four-instruction procs.  Growing the bytecode object to fit the stub would risk the interpreter's own structures.

## 10. Where compiled code is not faster, and what was tried

Measured on the tcllib workloads (instructions, compiled against interpreted; 1.0 is parity): sha1 0.93, md5 1.22, crc32 1.03, base64 1.13, json 1.02,
csv 1.04, textsplit 1.00, adjust 0.92, structlist 0.70, structset 0.93, stats 0.91, numtheory 0.75, uuid 1.17 (all 13 results equal the interpreter's).
Self cost of the generated code is 0-20 % of each workload's instructions; the rest is Tcl's own library (the regexp engine, list parsing, `regsub`, hash
tables, the thread allocator), which compiled code calls exactly as the interpreter does.  Consequences:

* **Typed strings and direct untyped calls were not built.**  They act on the generated-code share of string workloads (0-7 %) and on the call machinery
  (at most 5 %).
* **An inline integer fast path at every operator** was tried: 2.5 % fewer instructions, 34 % more code (367 KB to 491 KB for the md5 function), and slower in
  wall time.  Not kept.
* **Unboxed integer temporaries in boxed code** could remove at most the per-operator helper cost (19-25 % of sha1, crc32, stats; under 10 % elsewhere).
  Those procs are in boxed code because typed code ended at `upvar`, arrays and `unset` (see 13); the better fix was to let typed code take those.
* **Bignum arithmetic** (`<<`, `>>`, `&`, `|`, `^`, `+`, `-`, `*` beyond 64 bits) is done natively as the executor does it, not through a micro-bytecode run:
  md5 went from 1.34 to 1.21.
* Typed code is where the gain is: 3.7x to 113x on integer and floating-point loops.  Untyped code with many calls is 0.57-0.75x.

## 11. WebAssembly

The suite was run as a wasm32-wasip3 guest under wasmtime with its default 512 KiB call stack.  It found a defect that cannot show natively: recursion
reaching Tcl's limit of 1000 levels trapped the guest instead of raising "too many nested evaluations", because a failed typed chain is redone in boxed
code where every level is an entry through Tcl's invoke machinery (about 0.7 KB of C stack each).  `TBC_NEST_CAP` (200 when compiling for wasm) makes the
interpreter run calls past that many live compiled entries, with identical results and error info; `tests/nestcap.sh` runs the suite with caps of 1, 3
and 40 natively.  A host that lets guests recurse deeper than 1000 levels still needs a larger call stack.  The four differential calls that stop an
infinite loop with an asynchronous handler marked from a second thread are left out in a guest (`TBC_NOASYNC=1`); a guest has no second thread.

## 12. Size of the output, build time, start-up

* Boxed functions had an entry for every instruction so typed code could hand over anywhere; only the entries some call names are emitted (about 5 % of them), and
  the error-logging sequences are one macro.  The C of a 694-proc module went from 25.6 MB to 19.6 MB.
* `-split N` writes typed and boxed code into separate files and `tools/build-module.sh` compiles them in parallel, boxed code at `-Og` (it gains little
  from more): 158 s to 28 s on four cores, object file 24.8 MB to 16.2 MB, at a cost of 0-3 % more instructions.  All runtime variables are shared across the
  files (`TBC_SHARED`).
* Noticing procs with an execution trace on `proc` passes every body to the trace handler as a list element: startup of 20 packages cost 101.7 M more
  instructions (+12 %).  The module now wraps the C function behind `proc` instead (the same command, so renames and traces of the program follow it):
  +26.6 M (+3.2 %), `trace info execution proc` shows nothing of ours, and a `proc` run through `uplevel` is looked up in the variable frame, as Tcl does
  (the trace handler used the call frame and never attached such procs in eager mode).

## 13. Variables in the frame

Typed code ended at `upvar`, `global`, `variable` and any array element, so a proc using them ran the rest of each call in boxed code: an array sieve was
1.2x the interpreter, an array histogram, array Fibonacci and a counter through `upvar` within 10 % of it.  Such variables now have kind `F` and typed
code works on them in the frame through fast paths that complete or leave everything unchanged and continue in boxed code at that instruction (see
`design.md`).  Instruction counts, compiled against interpreted: sieve 2.1x, histogram 5.2x, array Fibonacci 1.9x, matrix product 1.7x, `upvar` counter
6.6x, `global` counter 10.3x, namespace-variable counter 8.7x, namespace array fill 2.1x; what is left in the array cases is Tcl's hash table (about 40 % of
the sieve).  Consequences worked out with it:

* In a proc with frame variables, typed code can no longer start the whole call over in boxed code when a step fails (earlier steps had effects); the exit
  resumes at the failing instruction.  `tf_resume` increments an array element, then fails in `lindex` on an unbalanced list; the element must be
  incremented once.
* Variables assigned on some paths only were all held boxed in procs that can be asked about their variables by name; they now stay unboxed with an
  "assigned" flag, so loop counters initialised inside an `if` stay in registers.
* `strcat` in boxed code is the executor's own algorithm (one allocation, byte arrays stay byte arrays): building the key `$i,$k` was 36 % slower than the
  interpreter and is now level with it.
* `incr` on a number kept as text (`variable cnt 0`) is taken by the fast path, reading it as the interpreter does.
* Tests: `tf_*` procs (about 600 calls: all key forms, `5`/`05`/`5.0`, missing elements, not-an-array, `incr` on every kind of value, shared values, links to
  scalars, arrays, elements and namespace variables, traces of every kind on the variable, the array and an element, an active array search), a memory-growth
  test that fails with a deliberately leaked key object (11.7 MB), and fifty random programs per fuzz seed mixing typed arithmetic with arrays and the
  three kinds of link.

Not taken yet, and listed with `TBC_DEADOPS=1`: `unset`, `info exists` of a plain local, `array exists`, `append`/`lappend` on a frame variable, commands that
name variables (`array names`, `uplevel`), `foreach`, `lmap`, `switch`, `catch`/`try`, and math functions: calls of `tcl::mathfunc::*` (`sqrt`, `int`, `double`,
`abs`...) end typed code today.
