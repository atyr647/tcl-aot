# Roadmap

Work that is planned, in the order it is expected to pay off, with the measurement that motivates it.  Nothing here is done; `decisions.md` records what is.
An item moves out of this file when it is measured, tested and written up there.

## Next

1. **Integer loops: fewer overflow checks.**  An integer loop costs about 33 instructions per iteration where hand-written C needs 10 to 12.  Range analysis
   with induction variables and trip counts would remove the overflow tests that cannot fire (a counter bounded by a loop condition, a non-negative `%`), and
   loop versioning would let one check at the entry cover the loop.  Wrap and bignum promotion must stay exact: every rule needs a differential and a fuzz
   case that fails without it.
2. **String commands in loops** (`string length`, `string index`, `string first`: 1.4x).  The commands are called with boxed operands.  Direct length and index
   for strings known to be ASCII, hoisting the length out of loops, and comparing lengths before bytes.  Care with the string representation that Tcl
   caches in the object.
3. **Keys of arrays.**  The matrix product (`set a($i,$j)`) is 1.8x because each key is built as a string.  Integer-pair keys for a native array whose every
   access has the same shape (two integers and a fixed separator) would avoid the string; the table keeps the text for writing it out.
4. **Calls into procs that need a frame** (global, namespace and `upvar` variables).  The interpreter's call costs about 900 instructions more than it
   needs to.  Building the call frame directly and running the compiled body in it, without the stub bytecode and its second dispatch, is possible with
   Tcl's exported frame functions but must reproduce argument binding, error messages and error info exactly.
5. **Namespace and global arrays** (2.1x).  These stay in Tcl's hash table because other code can reach them.  Caching the element found for a constant key,
   guarded by the array's trace and write state, would help loops that use a few fixed keys.
6. **A table of instruction effects.**  Each bytecode instruction declares what it may read, write and throw, in one place.  Today this is spread over the
   liveness, purity and caller-safety analyses.  Moving code across instructions (hoisting, discarding results that nobody reads) needs it.
7. **Compile-time and run-time reports.**  Where the time of a compiled proc goes (boxed accesses, native arithmetic, transitions to the interpreter), and which
   instruction made typed code hand over most often.  `tbc::report` says which procs run compiled; this would say how well.
8. **More tests.**  Metamorphic tests (the same program with a statement reordered or a variable renamed must give the same result) and fuzzing of the
   hand-over paths: force typed code to hand over at every instruction of every test proc and compare.

## Coroutines

* **Hand-over at every instruction, for the callee side**: the forced hand-over test covers typed to boxed; the other direction (boxed to typed at a loop head) does
  not exist yet and is the same entry point as above.

## Replaced commands

Done at proc entry (decisions 19).  Open: a replacement made by a proc while it is itself running and using the built-in.

## Instructions typed code still hands over at

`dict for`, `lmap`, `unset`, `info exists` of a plain local, `array exists`, `append` and `lappend` on frame variables, `lsort` (a comparison proc could be
compiled to a native comparator), and `try`/`finally`.  `TBC_DEADOPS=1` lists them for your own procs.

## Not planned

* Anything that needs run-time feedback or recompilation (this is an ahead-of-time compiler for a stock Tcl).
* Tagged pointers or NaN boxing of `Tcl_Obj`: Tcl's object and reference-count rules are the contract.
* Anything that needs a modified Tcl, or private Tcl structures beyond what the build already uses, unless it sits behind a version check.
