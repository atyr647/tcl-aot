# Roadmap

Work that is planned, in the order it is expected to pay off, with the measurement that motivates it.  Nothing here is done; `decisions.md` records what is.
An item moves out of this file when it is measured, tested and written up there.

## Next

1. **Integer loops: fewer overflow checks.**  Measured and not worth it: removing every overflow check gains at most 0-4% (decision 24).
2. **String commands in loops**: done (decision 28; `str_ops` 1.4x to 4.8x).
3. **Keys of arrays**: done for integer and literal keys (decision 25).
4. **Calls into procs that need a frame** (global, namespace and `upvar` variables).  The interpreter's call costs about 900 instructions more than it
   needs to.  Building the call frame directly and running the compiled body in it, without the stub bytecode and its second dispatch, is possible with
   Tcl's exported frame functions but must reproduce argument binding, error messages and error info exactly.
5. **Namespace and global arrays** (`nn::fill`: 2.1x counted in instructions of one cold run, 3.9x in wall time of the best of five).  These stay in Tcl's hash table
   because other code can reach them.  Caching the element found for a constant key, guarded by the array's trace and write state, would help loops that use a few fixed keys.
6. **A table of instruction effects.**  Each bytecode instruction declares what it may read, write and throw, in one place.  Today this is spread over the
   liveness, purity and caller-safety analyses.  Moving code across instructions (hoisting, discarding results that nobody reads) needs it.
7. **Compile-time and run-time reports.**  Where the time of a compiled proc goes (boxed accesses, native arithmetic, transitions to the interpreter), and which
   instruction made typed code hand over most often.  `tbc::report` says which procs run compiled; this would say how well.
8. **More tests.**  Metamorphic tests (the same program with a statement reordered or a variable renamed must give the same result) and fuzzing of the
   hand-over paths: force typed code to hand over at every instruction of every test proc and compare.

## Coroutines

* **Hand-over at every instruction, for the callee side**: the forced hand-over test covers typed to boxed; the other direction (boxed to typed at a loop head) does
  not exist yet and is the same entry point as above.

## Smaller items

* `lsort -command` with a compiled comparator (needs a stand-in command whose name shows in the error info of a failing comparator, or a copy of Tcl's merge sort).
* A native regexp matcher for literal patterns (decision 28 has the measurement and what it would take).
* An element cache for namespace and global arrays, for loops that revisit keys.

## Replaced commands

Checked at proc entry (decisions 19).  Not shown for every case: a replacement made by a proc while it is itself running and using the built-in
(two shapes tested, no difference found).

## Instructions typed code still hands over at

`dict for`, `lmap`, `unset`, `info exists` of a plain local, `array exists`, `append` and `lappend` on frame variables, `lsort` (a comparison proc could be
compiled to a native comparator), and `try`/`finally`.  `TBC_DEADOPS=1` lists them for your own procs.

## Not planned

* Anything that needs run-time feedback or recompilation (this is an ahead-of-time compiler for a stock Tcl).
* Tagged pointers or NaN boxing of `Tcl_Obj`: Tcl's object and reference-count rules are the contract.
* Anything that needs a modified Tcl, or private Tcl structures beyond what the build already uses, unless it sits behind a version check.
