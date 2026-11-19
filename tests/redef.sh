#!/bin/sh
# Decision 78.  A typed caller keeps its variables in C locals across a call of a caller-safe or pure callee (the translator showed the callee cannot reach them).  A callee that is
# redefined at run time can: the caller must then hand over at the call (the boxed code makes it, with the variables in the frame), and typed code goes on when the compiled
# definition is back.  Checked by results against the interpreter and by what the counters of a -DTBC_COV module say (equal results alone would not show that the fast case stayed fast):
#  - intact: no hand-over at the call of a caller-safe callee, of a pure callee, of a callee two levels down;
#  - redefined to reach the caller's frame (uplevel 1, upvar 2, ...): results equal the interpreter's, the callers hand over;
#  - the same text defined again: the compiled code is used again (no hand-over per call), the callee being armed or attached again.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "redef: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc rd_leaf {} { array set a {k 1}; return $a(k) }
proc rd_outer {n} { set x 100; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [rd_leaf] }; return [list $x $s] }
proc rd_gleaf {} { array set a {k 1}; return $a(k) }   ;# (the same body as rd_leaf: two procs of one module with one body each have their own flag)
proc rd_gmid {} { set s [rd_gleaf]; return [expr {$s + 1}] }
proc rd_gouter {n} { set x 100; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [rd_gmid] }; return [list $x $s] }
proc rd_pleaf {a} { return [expr {$a + 1}] }
proc rd_pouter {n} { set x 100; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [rd_pleaf $i] }; return [list $x $s] }
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Redef >"$tmp/tr.log" 2>&1 || { echo "redef: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Redef $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "redef: build failed"; exit 1; }
cat > "$tmp/run.tcl" <<'TCL'
load {} Redef
source $::env(PROCS)
set src [read [open $::env(PROCS)]]
interp create ref
ref eval $src
set bad 0
proc check {what cond} { if {![uplevel 1 [list expr $cond]]} { puts "FAILED: $what"; incr ::bad } }
proc same {call} { set a [eval $call]; set b [ref eval $call]; check "$call: [list $a] against [list $b]" [expr {$a eq $b}] }
proc ho {p} { set d [tbc::hot -dict]; if {![dict exists $d $p]} { return -1 }; dict get $d $p handovers }
set pairs {{rd_outer ::rd_outer rd_leaf {}} {rd_gouter ::rd_gouter rd_gleaf {}} {rd_pouter ::rd_pouter rd_pleaf a}}
foreach c {{rd_outer 3} {rd_gouter 3} {rd_pouter 3}} { same $c }
foreach p {::rd_outer ::rd_gouter ::rd_pouter} { check "$p hands over while nothing is redefined ([ho $p])" {[ho $p] == 0} }
foreach {caller cp leaf arg} [concat {*}$pairs] {
    set call "$caller 3"
    foreach body {{uplevel 1 {set x 77}; return 1} {upvar 2 x v; set v 78; return 1} {uplevel 2 {set x 79}; return 1} {return [uplevel 1 {info vars}]}} {
        set def "proc $leaf {$arg} {$body}"
        set before [ho $cp]
        foreach i [list {} ref] {
            if {$i eq ""} { eval $def } else { ref eval $def }
        }
        set a [catch {eval $call} ma]; set b [catch {ref eval $call} mb]
        check "$caller after $leaf was redefined as {$body}: [list $a $ma] against [list $b $mb]" {$a == $b && $ma eq $mb}
        check "$caller handed over after the redefinition ([ho $cp] after $before)" {[ho $cp] > $before}
        # the same text as the module's, defined again
        set orig [dict get {rd_leaf {proc rd_leaf {} { array set a {k 1}; return $a(k) }} rd_gleaf {proc rd_gleaf {} { array set a {k 1}; return $a(k) }} rd_pleaf {proc rd_pleaf {a} { return [expr {$a + 1}] }}} $leaf]
        eval $orig; ref eval $orig
        eval $call
        set before [ho $cp]
        same $call
        check "$caller hands over with the compiled definition back ([ho $cp] after $before)" {[ho $cp] == $before}
    }
    # renamed away: the call fails as the interpreter's
    rename $leaf ${leaf}_o; ref eval [list rename $leaf ${leaf}_o]
    set a [catch {eval $call} ma]; set b [catch {ref eval $call} mb]
    check "$caller with $leaf renamed away: [list $a $ma] against [list $b $mb]" {$a == $b && $ma eq $mb}
    rename ${leaf}_o $leaf; ref eval [list rename ${leaf}_o $leaf]
    same $call
}
if {$bad} { exit 1 }
puts ok
TCL
out=$(PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "redef: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "redef: FAILED"; exit 1; }
echo "redef: a callee redefined to reach its caller's frame (uplevel, upvar 2) makes the typed caller hand over; the same text again is compiled again: ok"
