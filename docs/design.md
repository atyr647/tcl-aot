# Design

tcl-aot translates the procs of a Tcl 8.6 program to C ahead of time and lets the unmodified program use the result.  This document describes how the
pieces fit together; `decisions.md` records why they are the way they are, with the measurements behind them.

## Pipeline

```
procs.tcl --translate.tcl--> module.c --cc + libtcl--> program shell
                                                        |
program.tcl ---- defines procs ---- tbc runtime attaches compiled bodies ---- calls run compiled code
```

1. `src/translate.tcl` runs in `tcl-aot-sh`, a tclsh built from the same Tcl 8.6.14 as the final program.  It sources the program's proc definitions
   (so code that builds procs while loading a package works), and for each proc obtains the bytecode with `tcl::unsupported::disassemble`.  Working
   from bytecode, not from source text, means the translator sees what the interpreter would execute: the compiler's constant folding, its inline
   expansion of `string`, `lindex`, `dict` and friends, its loop and exception ranges.
2. The translator builds the control-flow graph, computes the operand-stack depth at every instruction, infers types (below) and writes C.
3. The C file is compiled with Tcl's internal headers and linked, with the runtime in `include/`, against a static `libtcl8.6.a`.  The result is an
   ordinary Tcl shell (or any program embedding Tcl) with one more package: `<InitName>_Init`.
4. At run time the program starts the module (`load {} <InitName>` for a static package), then defines its procs and calls them as before.

## Attaching compiled code to a proc

A compiled body is not a new command.  The proc stays a proc: Tcl builds its call frame, binds the arguments (defaults, `args`, "wrong # args"
errors), and counts nesting levels.  `info body`, `info args`, `info level`, `info frame`, `rename`, traces and namespaces behave as they always did.

* The module wraps the C function behind `proc` (`Tcl_SetCommandInfo` on the same command, so a program that renames or traces `proc` is unaffected).
  After the original definition has run, the wrapper looks up the key `(namespace, canonical arguments, body text)` in the module's table.
* By default the attach is done at the proc's first call (`tbc::attach eager` or `TBC_EAGER=1` does it at definition).  A one-shot execution trace on
  the proc waits for that call; a proc that is never called costs nothing.
* At attach time the proc's bytecode (which Tcl has compiled by then) is compared by fingerprint (FNV over the instruction bytes, the literals, and the
  exact bits of double literals whose printed form does not parse back) with the bytecode the translator saw.  The compiler's output depends on state
  (commands redefined by a package, `string` hidden...), so equality is checked, not assumed.  A mismatch leaves the proc to the interpreter.
* The proc's `ByteCode` is then patched in place to three instructions, `push1 ::tbc::eN; invokeStk1 1; done`, flagged as precompiled so Tcl never
  recompiles it, with the location tables of the original body.  `::tbc::eN` runs in the proc's frame and calls the compiled function.
* Before each call the compile epoch is looked at; if it changed (something the compiler consults may have changed) the fingerprint is checked again and
  the proc is demoted to the interpreter if it no longer matches.  Calls made inside a coroutine (unless the proc cannot yield, decisions 5), and calls past a nesting cap, run the original body
  with the interpreter on its own stack.

## Typed and boxed code

Every translated proc has two forms.

**Boxed code** (`G_<proc>`) is a single function that can be entered at any instruction.  Locals live in the interpreter's call frame, the operand
stack in C variables holding `Tcl_Obj` references, and the reference-counting rules are the bytecode executor's.  Every instruction has an
implementation; most call the same Tcl functions the executor does (`TclPtrGetVarIdx`, `TclIncrObj`, `Tcl_ListObjIndex`, ...), and arithmetic has
inline fast paths for integers and doubles with a fall-through to the `::tcl::mathop` commands, so errors and bignums are Tcl's.

**Typed code** (`V_<proc>_<signature>`) exists for every argument-type signature (`I` int64, `D` double, `B` object) that is requested or reached by a
direct call.  A fixpoint over the control-flow graph gives every stack slot a kind and every local a representation:

| kind | meaning |
|---|---|
| `I`, `D` | machine integer, double, in a C variable (a literal slot also remembers its literal object) |
| `B` | `Tcl_Obj *` that the slot owns |
| `L` | a literal string, boxed on demand |
| `A`, `M` | a local list of integers / a local dict with integer values, held as a C vector / hash map (when it does not escape) |
| `F` | a variable that lives in the interpreter's frame (below) |
| `R` | a local array touched only by element loads, stores, increments and tests: a native table in element-creation order, written into the frame when typed code hands over (decisions 17) |
| `U` | not known yet (during the fixpoint) |

Typed code never changes anything observable before it knows it will not fall back.  When an assumption fails (integer overflow, an operand that is not
a number, a NaN result, a callee that was redefined, a trace on a variable, an instruction typed code does not implement) control goes to a `D` label:
the typed locals are written to the frame, the typed stack slots are boxed, and `G_<proc>` is entered at that instruction.  The rest of the call runs
boxed.  Failures after which state is still unchanged start the whole call over in boxed code; in a proc with frame variables they resume at the
failing instruction instead (the earlier steps had effects).

### Direct calls

A call by literal name to another translated proc whose callee is *pure* becomes a direct C call of the callee's typed variant for the argument kinds.
Pure means: the callee uses no variable by name, no `upvar`/`global`/`variable`, no array, and only built-in commands that cannot observe the caller's
frame, so it needs no frame of its own.  A flag per callee, cleared when the callee is renamed, deleted or redefined (traces that the module installs),
guards each call; a failed guard makes the call the ordinary way.  Results travel in the C return value; anything else (an error, a callee that had to
leave typed mode) is reported through `tbc_st` and handled at the call site.  Recursion depth is carried in a register argument and raises Tcl's
"too many nested evaluations" error at exactly the interpreter's limit.

### Variables in the frame

A variable that is the target of `upvar`, `namespace upvar`, `variable` or `global`, or the array of an element operation, has kind `F`: typed code keeps
it in the frame, where traces, commands that name variables, and the boxed code all see it.  Operations on it are fast paths that either complete
(links followed, no trace, the value present and of the expected type) or leave the frame untouched and continue in boxed code at that instruction.
An integer array index is formatted into a stack buffer and looked up without creating an object.  A proc with frame variables is not pure and so is
never called directly.

## Checks that keep the result equal to the interpreter's

* Fingerprints, as above.
* `tbc_check_build` refuses to load a module compiled against another Tcl patch level, or with different thread / allocator macros (the macros of Tcl's
  headers that allocate objects must match the libtcl in use; a mismatch leaks).
* Every error raised in compiled code is logged with the interpreter's own routine (`TclLogCommandInfo`) from the original bytecode, so error info and
  `errorLine` are equal.
* `tests/` runs several thousand calls with the interpreter alone and with the module and compares result, return code, error code and error info
  (`tests/differential.tcl`); `fuzz/` does the same with random programs.

## Files

| path | contents |
|---|---|
| `src/translate.tcl` | the translator |
| `src/opcodes.tcl` | stack effect of every 8.6.14 instruction |
| `src/cmdmap.tcl` | the command each instruction belongs to (by bisection: translation time must not be quadratic in the size of a proc) |
| `include/tbc_runtime.h` | object helpers, arithmetic, strings, lists, dicts, the typed-code protocol |
| `include/tbc_hook.h` | the registry, attaching, the entry command, `tbc::*`, variable fast paths |
| `tools/` | `env.sh`, the translator shell, the module shell, `build-module.sh` |
| `tests/`, `fuzz/`, `bench/`, `examples/` | as named |
