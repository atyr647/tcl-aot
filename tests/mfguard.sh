#!/bin/sh
# Decision 86.  The math functions typed code computes itself (floor, double, sin, hypot, max...) are right only while `tcl::mathfunc::<name>` is Tcl's own command.  The flag that says so
# was one flag for all of them, cleared for good by anything: a program that has its own `tcl::mathfunc::sin` in some namespace (the TclQuest engine has them in about two dozen), or a Tcl library
# whose `max` proc differs from Tcl's by a comment or by indentation (the N64's library is stripped), turned typed math off in the whole process, and every proc that called floor() or
# double() handed over to the boxed code at every call (red 99%, atan2 and hypot 100% on the N64).  Now each call site checks its own function, looked up from the namespace of the
# proc that calls it (a dependency of the module's guard), and the stock max and min are known by the fingerprint of their bytecode.  Checked:
#  - nothing is redefined, the library is Tcl's: no hand-over in procs that call floor, double, hypot, sin, max, min; results equal to the interpreter's;
#  - the library's comments and indentation stripped: the same, max and min included;
#  - a command named sin in another namespace (before the module loads): only the procs that call sin hand over; floor, double, hypot stay typed;
#  - a `max` that is not the stock one: only the procs that call max hand over;
#  - decision 86: a math function that is replaced for ONE namespace by `interp alias`, `namespace import`, `namespace path`, an execution trace on it, or by the engine's own pattern
#    (`::tq::math::install`: `namespace import -force ::tq::math::sin ...` into <ns>::tcl::mathfunc, before the module loads or after the procs have run) is looked up from the
#    namespace of each proc that calls it, as the interpreter does: the proc that calls it hands over and gets what the interpreter gets (results and trace logs equal), and a proc
#    of another namespace (or the same namespace calling another function) stays typed (counters);
#  - floor, double, sin and max redefined (by a proc in the caller's namespace or in ::tcl::mathfunc, renamed, deleted, replaced by an alias), before the first call, after it, and
#    between two rounds of calls: the results, errors included, are the interpreter's.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "mfguard: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/mfguard_procs.tcl" <<'TCL'
namespace eval ::mf {}
proc ::mf::fl {x} { return [expr {floor($x * 2.5) + 0.5}] }
proc ::mf::db {x} { return [expr {double($x) / 4}] }
proc ::mf::sn {x} { return [expr {sin($x) + 1.0}] }
proc ::mf::hy {x y} { return [expr {hypot($x, $y) * 2}] }
proc ::mf::mx {x y} { return [expr {max($x, $y) + min($x, 1)}] }
namespace eval ::mf2 {}
proc ::mf2::sn {x} { return [expr {sin($x) + 1.0}] }
proc ::mf2::fl {x} { return [expr {floor($x * 2.5) + 0.5}] }
proc ::mf::all {x} { return [list [fl $x] [db $x] [sn $x] [hy $x 3.0] [mx $x 2]] }
proc ::mf::loop {n} { set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + floor($i * 0.5) + double($i)}] }; return $s }
proc ::mf::red {x} {
    if {$x < 0.78539816339744830962 && $x > -0.78539816339744830962} { return [list 0 $x 0.0] }
    set fn [expr {floor($x * 6.36619772367581382433e-01 + 0.5)}]
    return [list [expr {int($fn)}] [expr {$x - $fn * 1.57079632673412561417e+00}]]
}
TCL
TBC_NOLITE=1 "$TCLSH" src/translate.tcl "$tmp/mfguard_procs.tcl" "$tmp/m.c" Mf >"$tmp/tr.log" 2>&1 || { tail -5 "$tmp/tr.log"; echo "mfguard: translation failed"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Mf $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || { echo "mfguard: build failed"; exit 1; }
# the library with every comment line and the indentation taken out of init.tcl (what the N64 build does to its scripts)
cp -R "$TCL_LIBRARY" "$tmp/lib" || exit 1
sed -e 's/^[[:space:]]*//' -e '/^#/d' "$TCL_LIBRARY/init.tcl" > "$tmp/lib/init.tcl"
cmp -s "$TCL_LIBRARY/init.tcl" "$tmp/lib/init.tcl" && { echo "mfguard: the stripped library is not different"; exit 1; }
export MF_PROCS="$tmp/mfguard_procs.tcl" TBC_NOLITE=1
status=0
run() {
  label=$1; shift
  out=$(env "$@" 2>&1)
  if [ $? -eq 0 ]; then echo "mfguard: $label: ok"; else printf '%s\n' "$out" | head -8; echo "mfguard: $label: FAILED"; status=1; fi
}
ALL="fl db sn hy mx all loop red"
run "stock library, nothing redefined: no hand-over" "$tmp/shell" tests/mfguard.tcl none before "$ALL"
run "library with comments and indentation stripped: no hand-over" TCL_LIBRARY="$tmp/lib" "$tmp/shell" tests/mfguard.tcl none before "$ALL"
run "another namespace has its own sin: floor, double, hypot, max stay typed" "$tmp/shell" tests/mfguard.tcl pre_sin before "fl db hy mx loop red"
run "a max that is not the stock one: floor, double, hypot, sin stay typed" "$tmp/shell" tests/mfguard.tcl pre_max_other before "fl db hy sn loop red"
# decision 86: the engine's pattern and the replacements the flags could not see
run "engine pattern, install after the procs ran: sin/cos/hypot are the engine's, sn and hy hand over, floor stays typed" "$tmp/shell" tests/mfguard.tcl eng after "fl db mx loop red" "sn hy"
run "engine pattern, install after the module loaded, before the first call" "$tmp/shell" tests/mfguard.tcl eng before "fl db mx loop red" "sn hy"
run "engine pattern, install before the module loads" "$tmp/shell" tests/mfguard.tcl pre_eng before "fl db mx loop red" "sn hy"
run "engine pattern in ::mf2 only, after the procs ran: ::mf procs stay typed (sin too), ::mf2::sn hands over" "$tmp/shell" tests/mfguard.tcl other_eng after "fl db sn hy mx loop red" "::mf2::sn"
run "engine pattern in ::mf2 only, before the module loads: ::mf procs stay typed (sin too), ::mf2::sn hands over, ::mf2::fl stays typed" "$tmp/shell" tests/mfguard.tcl pre_other_eng before "fl db sn hy mx loop red ::mf2::fl" "::mf2::sn"
for s in nsalias_floor nsalias_double nsalias_sin nsalias_max nsimport_floor nsimport_sin glimport_floor path_floor pathalias_floor pathalias_sin trace_floor trace_sin trace_double trace_max trace_hypot eng; do
  for w in before after twice; do
    run "$s ($w the first call): results and trace logs as the interpreter's" "$tmp/shell" tests/mfguard.tcl $s $w ""
  done
done
for s in nsproc_floor nsproc_double nsproc_sin nsproc_max glproc_floor glproc_double glproc_max glalias_floor glrename_floor gldelete_double glrename_max glrename_sin none; do
  for w in before after twice; do
    run "$s ($w the first call): results as the interpreter's" "$tmp/shell" tests/mfguard.tcl $s $w ""
  done
done
[ $status = 0 ] && echo "mfguard: ok"
exit $status
