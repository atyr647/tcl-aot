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

**Decided by the user (2026-10-31): the edge stays as a named limit.**  A research pass found the only way to close it without a patch to Tcl's sources: replace the
proc command's `Command.nreProc` in memory with a wrapper that adjusts `numLevels` (verified in a prototype).  That writes to Tcl's own `Command` struct, which
conflicts with "never alter Tcl" (decision 1), so it is not done.  It is a stated limit of the system, not an open item: a proc entered from the interpreter at the
very last nesting level fails one level early, with the same message and code.

## 5. Coroutines, `yield`, `tailcall`

Compiled code runs on the C stack and a coroutine suspends by unwinding the interpreter's own stack, which cannot cross a C frame (Tcl answers a `yield`
below a C frame with "cannot yield: C stack busy").  A call that arrives while a coroutine is running is therefore evaluated by the interpreter (the
original body, in the already-built frame, with the stub's nesting level given back), so a `yield` anywhere below a compiled proc works, unless the proc
cannot yield at all.  The translator marks a proc *yield-safe* when everything it runs is known not to reach a `yield`: no `eval`, `uplevel`, `expr` on a
string, no command whose identity is unknown, only built-ins that run no script, and calls only to translated procs that are yield-safe.  Such a proc runs
compiled inside a coroutine, provided every proc it calls (directly or not) is still the compiled one: each entry lists their validity flags, which Tcl's
rename and delete traces clear, so a callee replaced by a proc that yields sends the caller back to the interpreter (`ty_mid` in the differential test, which
fails without the check).

`tailcall` is compiled (the boxed code stores the tailcall list in the frame and returns `TCL_RETURN`, as the bytecode does; the interpreter's frame pop
then schedules it).

Procs that yield themselves are compiled too (decision 20).

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

## 14. Calls from typed code

Calls between translated procs were slower than the interpreter (0.89x, 3000 instructions per call) in any single long call, because the flag that
guards a direct call is set when the callee is attached, and the callee is attached at its *first call* (decision 3): the first guard failed, typed code
handed over, and the rest of the caller ran boxed with ordinary calls.  A failed guard now takes the stub that makes the ordinary call with boxed
arguments, and typed code continues with the result when it has the kind the callee's typed code returns (otherwise it hands over as before).  The
same continuation applies when a callee falls back to its boxed code.  Instructions per call: 3036 to 48 (56x the interpreter).

Calls that leave trailing arguments out are direct calls too when the omitted defaults are numbers (0.89x to 57.6x).  A call to a translated proc that needs a
frame (arrays, `global`, `variable`) cannot be a direct call; if the callee is *caller-safe* the interpreter makes the call and typed code goes on.  Caller-safe
means: no `upvar` to a level other than 0 or #0, no `uplevel`, `eval`, `expr` of a dynamic string, `tailcall` or `{*}` call, only built-ins that stay in
their own frame, only callees that are caller-safe themselves.  Such a callee cannot reach the caller's variables, so they can stay in C variables.
Known limit: a variable trace handler of a variable the callee touches that itself reaches two frames up (`uplevel 2`) would see stale caller variables;
nothing else can.  A call to a tiny callee of this kind costs the interpreter's call plus the entry into compiled code (about 850 instructions) and measures
0.82x; its value is that the caller's loop stays typed.

## 15. Math functions

Calls of `tcl::mathfunc::*` (`sqrt`, `int`, `double`, `abs`, `round`, `floor`, `ceil`, `pow`, `sin`, ...) ended typed code, so any numeric loop using one ran
boxed after it: 1.2x the interpreter.  They are computed in C now, with the conversions and result checks of Tcl's own implementations (NaN, and `errno`
other than a range error with a zero or infinite result, make the step start again in the boxed code, which raises Tcl's error).  `floor` and `ceil` of an
integer above 2^53 differ between a C cast (rounds) and Tcl's bignum path (truncates), so those are left to Tcl; found by the differential test.  The
rest (`bool`, `entier`, `isqrt`, `rand`, `srand`) are ordinary calls of a built-in that runs in typed code; `max` and `min` are procs of the Tcl library
and stay as they were.  Loops: 332 M to 5.3 M instructions (62x) and 221 M to 3.1 M (70x).

A compiler can also get in the way: clang for wasm32 turned `asin` of an integer into an intrinsic and, knowing the argument was no NaN, folded the
`r == r` test away, so `asin(2)` came back as a NaN result instead of an error.  The wasm32 guest run of the differential test found it (30 calls).  The
results of the libm calls now go through a volatile object before they are tested (`tbc_opaque_dbl`).  The suite also passes with clang as the native compiler.

This is right only while the commands are Tcl's own.  A flag says so; it is cleared when one of them is renamed or deleted (command traces), when a
proc is defined under a name that contains `::tcl::mathfunc::`, and it starts out cleared if a namespace other than the global one already has a
`tcl::mathfunc` child with commands.  When it is clear, typed code hands over to boxed code at the call.  It is never set again in that process.

## 16. More of the instruction set in typed code

* The instructions the executor implements by calling a command that uses no variable (`string index/first/last/range/replace/trim*/match/toupper/...`,
  `regexp`, `lrange` and `lindex` with indices, `in`/`ni`) are done with boxed operands in typed code (the table is shared with boxed code).
  `eq`, `ne` and `string compare` do the comparison directly (two integers: a machine comparison), `**` calls the runtime's boxed operator, `concat`
  and the stack-copying `over` are taken.  A `string length` / `string first` loop: 0.88x to 1.40x.
* `foreach`: the lists are held as objects, the iteration state in two C variables; when typed code hands over, the interpreter's iteration object is rebuilt from
  them.  Loop variables are objects (or frame variables).  5.5x the interpreter on a loop summing 1000 elements.
* `catch`: `beginCatch` and `endCatch` change nothing in typed code.  A failure inside the body hands over to boxed code at that instruction, and the
  boxed code dispatches to the handler.  1.56x to 14.3x on a loop with a catch.
* `switch` with a jump table: an integer key is a C `switch` over the keys written as canonical integers (the key's text is the integer's canonical
  form, so no other key can match it); any other key is compared with the literal keys as the boxed code does.  1.36x to 33x.
* `incr` of a local that holds an object (a loop variable, a list element), `llength` of a number, `string map` and the concatenation of two lists.
* The hint file (`-hints`) matched bare proc names against the translator's fully qualified ones and so never took effect; the signatures it lists
  (`D`, `DD`, ...) were not generated.  Fixed; the differential test now enters those variants as well.

Census of the instructions at which typed code still gives up, over 694 procs from tcllib packages: before these changes 1603 sites (`invokeStk` 704,
`foreach_start` 205, `returnImm` 199, ...), now 1545 of which `foreach_start` and `jumpTable` are gone and `invokeStk` is 530: calls of `upvar` as a command (76),
`package` (36), `lsort` (27), `array names` (18), `rename` (16), `regsub` (16), `binary scan` (14), `uplevel` (13), `regexp`, file and channel commands.  `returnImm` is
`return -code`, which ends the proc anyway.

Not taken yet, and listed with `TBC_DEADOPS=1`: `dict for`, `lmap`, `unset`, `info exists` of a plain local, `array exists`, `append`/`lappend` on a frame
variable, `lsort`, commands that name variables (`array names`, `uplevel`, `upvar` as a command, `regexp` with variable names), and commands that are not
known to leave the caller's variables alone.

## 17. Local arrays held natively, and two fixes found on the way

An array that is a compiled local, is not an argument, and is touched only by element loads, stores, increments and `info exists` (nothing else names it in the
bytecode: no `unset`, `append`, `lappend`, `array exists`, `upvar`, ...) cannot be seen by anything else while typed code runs: the callees typed code calls
are caller-safe, and every command that could reach it by name is one at which typed code hands over anyway.  Typed code therefore keeps such an array (kind R)
in a table of its own: elements are `Tcl_Obj` values keyed by their text, in the order they were made.  When typed code hands over, the elements are written
into the frame in that order, so the hash table the boxed code goes on with is the one the interpreter would have built (the order `array names` lists them in
depends on it).  A read of an element that is not there, an increment of a value that is not an integer or that overflows, and any other failure hand over
the same way, so the boxed code raises the interpreter's error.  Such procs no longer need a frame, so a typed caller calls them directly.

Measured as instruction counts, interpreter / compiled: array sieve 2.1x to 4.5x, array histogram 5.2x to 7.4x, array Fibonacci 1.8x to 3.3x, a loop calling a
tiny proc that uses an array of its own 0.8x to 2.4x.  The matrix product over `$i,$j` keys moved from 1.7x to 1.8x only: its time is in building the key.

What bounds it: a proc call that needs a frame costs the interpreter's own call (frame, argument binding, the stub bytecode and its second dispatch, about 900
instructions more than the interpreter); the array in that benchmark was most of the rest.  With the array gone the call is direct.

Found by checking this against the interpreter:

* A proc with no frame variables that called a proc with effects (one that needs a frame) could, on a later failure, start the whole call over in the boxed code,
  and so repeat the callee's effects (a counter incremented twice).  Such procs now resume at the failing instruction, as procs with frame variables do.
  `tfx_eff` in the differential test.
* The boxed code's `info exists a(k)` looked the element up the way the interpreter does when a read trace has to run (make an entry, then remove it again).
  The interpreter takes a shortcut that makes no entry unless a trace is involved.  The entry made and removed again changes when the hash table grows and so the
  order in which `array names` lists the elements.  Fixed; `tr_exists_order` in the differential test, and a `fr_` family in the typed fuzzer (random programs
  over local arrays, including ones that fail halfway and write the table out, 64000 calls per seed, seeds 1 to 8 clean).

## 18. Handing over at every instruction

Typed code can leave typed mode at any instruction (an assumption fails, a tick is due, the instruction is not implemented).  The ways out were tested by the
programs that happen to fail there, which left most instruction/state combinations untested.  A module translated with `TBC_FORCE_DEOPT=1` now asks, at every
typed instruction, whether to hand over (`TBC_FORCE_RATE=n`: about one instruction in n, from a seeded generator), and the differential test and the typed fuzzer run
that way (`tests/run.sh`).  It found one bug at once: the loop variables of `foreach` were not written to the frame when typed code handed over inside or right
after the loop, because the liveness analysis took `foreach_step` for a definition that always happens, while at the end of the list the variables keep their
values (`foreach x $l {}; info exists x` answered no).  Fixed (`tf_after`, `tfe_after`).  18 combinations of rate and seed are clean on the differential test.

A hand-over in the middle of a pure recursion enters the next body from the interpreter, so the recursion-limit edge is the one of decision 4 (one level early);
the forced run compares those checks with the tolerance used for the other procs.

## 19. Built-ins the analysis relied on can be replaced

Purity and caller-safety rest on facts about commands: `lreverse` runs no script and cannot touch the caller's variables, so typed code keeps the caller's
variables in C locals across a call of it.  A program can break that after the module is compiled: `rename lreverse x; proc lreverse {l} { uplevel 1 {set x 77} ... }`
made the compiled proc answer with a stale `x` where the interpreter answers 77 (found by looking for divergences by hand; the tests had never replaced a built-in).
Math functions had a guard for this (`tbc_mf_ok`); the other built-ins had none.

The translator lists, for every proc, the built-ins it relied on, with the namespace each is looked up from (and those of every proc it calls).  The module
registers them.  The check is Tcl's own: a cached command name stays valid only while the command's epoch, the namespace and the namespace's `cmdRefEpoch`
(and `resolverEpoch`) are unchanged.  At load the global built-in is pinned (reference held, epoch noted).  At each entry of a proc with such dependencies the
module compares the namespace's `nsId`, `cmdRefEpoch` and `resolverEpoch` and the pinned command's `cmdEpoch` and `CMD_IS_DELETED` with what was last verified;
a few compares, and nothing else, while nothing has changed.  When one differs the names are looked up again from the namespace (`Tcl_FindCommand`), and a
dependency that no longer gives the pinned command (or an import of it) is withdrawn for good; an entry with a withdrawn dependency runs the interpreter's
version.  Withdrawal is for good because the program may have put the original back and the epoch gives no way to tell a command that was replaced from one
that was replaced twice.  Covered, each with a check in `tb_*` / `tbal` / `tbim` that fails without the guard: rename, delete, `proc` in the global or a nested
namespace, `interp alias` into a nested namespace, `namespace import`, `interp hide`, and putting the original back.

The first design of this guard (a flag per name, withdrawn when any command *ending* in that name existed in any namespace) was wrong in the other direction:
Tcl's own `::tcl::binary::format`, `::tcl::clock::format`, `::tcl::file::join`, `::tcl::file::split` and `::tcl::chan::puts` made it withdraw `format`, `join`,
`split` and `puts`, so procs that used them ran interpreted (found profiling eleven tcllib-style workloads: 172 of 183 calls of the sha1 proc ran interpreted).
Resolving from the proc's namespace, as above, fixes it: the same workloads run 6-11% fewer instructions, and the report check `tb_fmt`/`tb_spl` fails when they
fall back again.

What the check does not do: it is made when a compiled proc is entered, not while it runs.  The interpreter resolves a name at every call.  Two procs that rename
and redefine a built-in they use between two calls of it (`tb_self`, `tb_self2`: the second also has the new command write the caller's variable) give the
interpreter's results in the differential test; that is all that has been shown.  There is no argument that it holds for every shape of body, so it is not
claimed.

Checked: with the guard forced open the differential test fails; with it, the full `tests/run.sh` passes (differential 12951 calls, forced hand-over, fuzz typed
seeds 1-3 and boxed seeds 1-2, valgrind 12923 calls, 0 mismatches).

The first forced-hand-over fuzz run crashed.  The cause was in the test instrumentation: the coverage counters of a `-DTBC_COV` build (a fixed table of 8192 sites, no bound
check) overflowed once every instruction had a hand-over site, and wrote over `tbcOne`.  The table is larger now and the sites beyond it share the last slot.

## 20. Procs that yield

A coroutine is suspended by unwinding the interpreter's non-recursive stack, which cannot cross a C frame; Tcl answers a `yield` below one with "cannot yield: C
stack busy".  The boxed code of a proc is a function that can be entered at any instruction with the operand stack in an array, so it can suspend the way the
bytecode executor does it: at a `yield` it keeps the stack below the yielded value in a heap record, pushes a resume callback and Tcl's own
`TclNRCoroutineActivateCallback` on the interpreter's stack, and returns up to the interpreter's trampoline, which does the switch.  When the coroutine is
resumed the callback gets the record back and goes on in the boxed code at the next instruction with the resumer's value as the result of the `yield`.
A coroutine deleted while suspended rewinds: the callback releases the record and returns an error.  `yieldto` does the same after installing its tailcall.

* The proc must be entered by the interpreter, not by compiled code (a C frame of compiled code above it would prevent the switch), and everything else it runs
  must be yield-safe (decision 5); otherwise, inside a coroutine, the interpreter's version runs.
* A yield inside a `dict for` (the iteration state is in C variables) or inside a `{*}` expansion is refused (such procs stay interpreted).  Native arrays,
  lists and maps are not used in a proc that yields (they cannot be rebuilt from the frame).
* Typed code is entered again after a yield where it pays: the typed analysis keeps the state after each yield (`seed`), and the generic variant has a copy
  (`V_<proc>_RE`) that starts there.  It reads the locals that may have been assigned from the frame and checks them (an integer for an integer variable, no
  trace, no link, no array: the boxed code has run since the typed code handed over, so nothing can be assumed) and the stack slots; if anything is not as
  expected the boxed code goes on instead.  The copy is made only where a loop that contains no yield can be reached before the next one: the transition costs
  about 200 instructions, so a generator whose loop body is just the yield stays boxed.

Measured as instruction counts, interpreter / compiled: a generator that does nothing but yield 20000 times 1.03x (Tcl's own switch is about 4300 instructions
per yield and resume); one that computes in a loop of its own between yields 9x in total (20x without the start-up); one that computes in a helper proc 9x.

Found on the way, by the forced hand-over test: the table of boxed-code entry points was built the first time it was asked, in a function whose loop variable had
the name of its argument.  The first lookup of a translation therefore asked about the wrong instruction, and a hand-over at that instruction ran the `default`
of the entry switch: success with an empty result.  Fixed, the `default` is now an error, and the translator checks, after generating, that every entry the
generated code makes has a case.

## 21. Typed code on integers written as 0xFF, and on `binary scan` of numbers

Profiling eleven tcllib-style workloads (see decision 19) showed the checksum procs (sha1, md5, crc32) spending 33-48% of their instructions in the boxed
helpers for `&`, `^` and `>>`.  Two things kept typed code from running there.

* **Integer literals that are not written canonically** (`0xFF`, `0xFFFFFFFF`, `010`, `0b11`) were string literals to the translator, so an integer operation with one
  of them as an operand handed over to boxed code.  They are classified as strings for a reason (a `set x 0xFF` must keep its text), but an operand of an integer
  operation is only read.  `operandOf` now reads the value of such a literal (`string is wideinteger`, evaluated with `expr`, so octal and `0b` follow this Tcl).
  A literal outside 64 bits, or one that is a double, is still not an integer operand.  `tests/typed.sh` fails without this (a crc loop hands over at `bitand` and
  `bitxor`); the differential test has `tl_*` procs with hex, octal, binary, a leading space, out of range, and non-numbers.
  Measured on a crc loop over a list of 1000 ints: 0.51 s interpreted, 0.42 s compiled before, 0.11 s after (4.7x).
* **`binary scan $data <t>* var`** named a variable, so typed code (which has no frame) stopped there.  For one of `c s S i I` with an optional `u`, a count of `*`, a
  data operand that is an object or a literal, and a variable that is a local held as an object, the list is built in C (`tbc_bscan`: ScanNumber's byte order and sign
  extension, whole numbers only, no data gives the empty object, the same `Tcl_GetByteArrayFromObj` as the command) and stored like `set`; the result is 1.  Any
  other form runs the command as before.  The differential test covers every format and flag with data of 0..9 bytes, bytes of both signs, characters above 255,
  numbers, lists, an existing value in the variable, a variable that is an array, an array element, a variable format, and a call without the variable.
  `tcl::binary::scan` is also counted among the commands that stay in their own frame, so a proc that uses it can be called from typed code.
  What the inlined command does not do: count in `info cmdcount`, or run execution traces on `binary` (the same as the math functions in decision 15).

Measured on the tcllib procs, as instruction counts net of start-up, interpreter / compiled: sha1 544M / 317M (1.72x; 1.12x before), crc32 378M / 356M (1.06x),
md5 464M / 452M (1.03x), binary 1206M / 854M (1.41x; 0.99x as shipped before decision 19, 1.12x with only the guard relaxed; the share of this decision was not separated).

What is left in these three, and why it was not changed:
* **crc32** does not benefit.  tcllib sets `signbit` to 2^63, so `~$signbit>>7` is bignum arithmetic and typed code hands over at the first instruction of every call;
  the loop then runs boxed.  Typed code cannot do bignums.  What would help is entering typed code again from boxed code at a loop head (the machinery that resumes
  after a yield does this for coroutines).  Not built; see the roadmap.
* **md5** runs its transform in boxed code: `variable $token` and `upvar 0 $token state` name variables by a run-time string, and the state is an array.  It is as
  fast as the interpreter.
* The attribution of the rest is Tcl's own work: regexp/regsub 30-50% of the text workloads, object allocation 18-48%, with the thread-data lookup of a threaded Tcl build (`pthread_getspecific`) 10-28% of all instructions, and about 350 instructions to dispatch a command implemented in C.

Two defects of this change were found by the test stages that exist for this purpose, and fixed before it was released:
* The inlined `binary scan` writes its variable by name; the analysis that decides which locals a hand-over must write to the frame did not know that, so a
  hand-over right after the scan lost the list (`can't read "v": no such variable`).  Found by the forced hand-over stage (`tbs_sum_*`).  The instruction now counts as
  a use and a definition of the local, and keeps it from being held as a native array.
* `string is wideinteger` accepts integers beyond 64 bits.  A constant folded by Tcl's compiler (`9223372036854775807 + 2147483648`) was read as an int64 operand and
  gave a wrong answer.  Found by fuzz typed seed 3 with forced hand-over (`fz_11`).  The range is now checked; `tl_lit_fold` and `tl_lit_big2` fail without it.

Checked: the full `tests/run.sh` passes on this tree (differential 13460 calls in four modes, forced hand-over 6 configurations, fuzz typed seeds 1-3 and boxed seeds
1-2, valgrind 13431 calls, 0 mismatches).

## 22. What was measured for native aggregates, hash growth and lazy strings

Asked for: native doubles and strings, native aggregates passed between compiled procs, strings built lazily, incremental growth and presizing of the hash
tables the generated code owns.  Measured on this tree, as instruction counts (valgrind, start-up included, so small figures are inflated by it):

* **Doubles** are already native in typed code (kind D), through calls, math functions and `foreach`; nothing is boxed between operations.
* **Hash growth.**  A native counting map (`dict incr` on 100003 distinct keys, 400000 increments) runs 398.2M instructions with the map growing by doubling from 16
  entries, and 394.6M when it starts at the final size: 1.7% of the work net of start-up, which is the most that presizing from a compile-time hint could give, and
  it would cost 2 MB per map that never grows.  Not changed.  A single doubling at 65k entries re-inserts 65k entries (about 0.5M instructions), so there is no
  latency spike worth removing either.
* **Native aggregates between compiled procs.**  A proc that builds a 1000-element native vector and calls a helper with it 2000 times: 1257M interpreted, 180M
  compiled, against 44M when the helper's loop is written inline.  The call hands over to boxed code (a native vector cannot be an argument), so the helper gets
  a Tcl list and reads it with `lindex`.  Passing the vector by reference is the missing 4x, for loops that pass a vector repeatedly.  It was not built: the
  tcllib-style workloads (decision 19's profile) spend 0.7-8.5% of their instructions in generated code on the six text and data workloads, 12-18% on records and
  binary, and 18-43% on the three checksums; a vector passed by reference needs ownership rules (a callee that writes to it needs its own copy), and the
  estimated cost of proc calls in all eleven workloads is at most 6.3% (md5, 67000 proc entries at about 500 instructions each).  What was changed instead: `lindex` of a list object with an integer index reads the list's element
  array directly (what `Tcl_ListObjGetElements` does for a list) instead of calling it; the helper above went from 180M to 142M (21%).
* **Strings built lazily.**  Decision 10 measured typed strings: generated code is 0-7% of the string workloads, the rest is Tcl's own commands.  The profile of
  the eleven workloads agrees: generated code is 0.7-8.5% of the six text workloads, and the string-object work in them (2-23%) is done by Tcl's own functions,
  which lazy building in generated code would not remove.  Nothing was built.

Checked: the full `tests/run.sh` passes on this tree (differential 13460 calls in four modes, forced hand-over 6 configurations, fuzz typed seeds 1-3 and boxed seeds
1-2, valgrind 13431 calls, 0 mismatches).  The earlier commit of this change (f6dc853) was a work-in-progress snapshot made while that run was pending.

## 23. Boxed code enters typed code again at a loop head

When typed code hands over (a bignum operand, a value of the wrong kind), the rest of that call used to run boxed, however hot the loop that followed.  tcllib's
crc32 did this on every call (`signbit` is 2^63, so `~$signbit>>7` is bignum arithmetic): 1.06x the interpreter, against 4.7x for the same byte loop when typed.

Now the boxed code of a proc that has typed variants, at the head of an outermost loop that typed code knows the state at, calls the typed variant for boxed
arguments with a resume point (the instruction, and the operand stack, in thread-wide variables the variant reads and clears first thing).  The variant reads the locals
that may have been assigned from the frame and checks them as the entry after a yield does (decision 20): an integer for an integer variable, no trace, no link, no
array; a variable the typed code keeps in the frame must not be linked to a variable of this very frame; each stack slot is of its kind.  If anything does not fit,
the boxed code goes on instead.  If it fits, typed code runs to the end of the call.  Entering is attempted once per activation of the boxed code, and a variant that was entered
this way hands over to boxed code that does not try again (`tbc_noosr`, set at every hand-over from it), so a loop whose typed code keeps giving up costs two
transitions, not one per iteration.  The failure labels of that variant resume at the failing instruction (the call cannot be started over: the boxed code has run).

Design choice, measured.  The first version was a separate copy of the typed variant that starts at the loop heads (as for yield): +17-18% machine code and +19-29%
compile time on the benchmark procs and on tcllib's sha1 module.  Entering the shared variant costs +1.1% machine code and +4% compile time on the sha1 module
(+8.8% on the benchmark file, whose procs are a few lines each, so the fixed part per proc dominates).  Only outermost loop heads are entry points.

Results, instruction counts net of start-up, interpreter / compiled: crc32 378M / 154M (2.45x; 1.06x before).  The other ten workloads of decision 21's table are
unchanged (sha1 1.74x, md5 1.03x, base64 0.99x, json 0.98x, csv 0.96x, structlist 0.99x, textutil 1.04x, tokenizer 0.97x, records 1.05x, binary 1.41x).

Tests: `os_*` procs hand over before a loop (a bignum), in the middle of one, give up the entry, nest loops, `foreach`, `while` with `break`/`continue`, raise an error
in the loop, `catch` inside it, `return` from it, use doubles, and take their arguments as numbers or text; the differential test compares them with the interpreter.
`tests/osr.sh` fails unless each of them did enter typed code again (coverage counters), which equal results alone would not show.

Two defects found on the way, both fixed:
* The first version restarted the whole call when typed code failed after an entry (the failure chains of a proc without frame variables do that); the boxed code had
  already run, and the error info showed `tbc: restart in a resumed body`.  The variant now resumes at the failing instruction.
* The entry after a yield (decision 20) skipped the variables typed code keeps in the frame.  A proc that links a variable to one of its own (`upvar 0 y x`) after
  typed code has handed over, and then yields, returned a stale value for `y` when typed code was entered again: `ty_same` fails without the check.  The check is now
  made by both entries.

Checked: the full `tests/run.sh` passes on this tree (differential 13591 calls in four modes, forced hand-over 6 configurations, `tests/osr.sh`, `tests/typed.sh`, fuzz typed
seeds 1-3 and boxed seeds 1-2, valgrind 13552 calls, 0 mismatches).  The earlier commit of this change (80406ea) was a work-in-progress snapshot made while that run was
pending.

## 24. Two things that were measured or reasoned about and not built

* **Eliminating the overflow check of integer additions** (for example `incr i` in a counting loop).  Upper bound: every `__builtin_add_overflow` in the generated code of
  the benchmark file replaced by a plain add, timed with the same module: `int_loop` 16.2 ms to 15.6 ms, `arr_sieve` 70.2 ms to 68.0 ms, the others within noise.
  At most 0-4%; the analysis that proves a counter cannot overflow would be code that can be wrong for that gain.
* **Calling the C procedure of a pure built-in directly** (`string first`, `lrange`, ...) instead of through the interpreter's command dispatch (about 350 instructions
  per call).  It would cut the dispatch share (estimated 1.6-7% of the eleven workloads, up to 2x on a loop that does nothing but call such commands, `str_ops`
  1.45x).  It changes what a program can observe: `info cmdcount` would not count the call, execution traces and `interp limit command` would not see it, and the
  interpreter's checks between commands would be skipped, unless the call repeated each of them (which is most of the dispatch cost).  Not done.
