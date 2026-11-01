#!/bin/bash
# Typed code must not hand over at integer operations whose operands are integers written other than canonically (0xFF, 010, 0b11): a checksum loop that
# masks with 0xFF stayed boxed at every operation and ran 1.2x faster than the interpreter instead of 4.7x.  TBC_DEADOPS=1 lists the instructions at which
# typed code hands over.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/t.tcl" <<'TCL'
proc tt_crc {nums tbl} {
    set crc 0xFFFFFFFF
    foreach n $nums {
        set crc [expr {([lindex $tbl [expr {($crc ^ $n) & 0xFF}]] ^ ($crc >> 8 & 0xFFFFFF)) & 0xFFFFFFFF}]
    }
    return [expr {$crc ^ 0xFFFFFFFF}]
}
proc tt_scan {data} {
    binary scan $data c* nums
    set s 0
    foreach n $nums { set s [expr {($s ^ $n) & 0xFF}] }
    return $s
}
TCL
out=$(TBC_DEADOPS=1 "$TCLSH" src/translate.tcl "$tmp/t.tcl" "$tmp/t.c" Typedtest 2>&1)
if echo "$out" | grep -q -E '^DEADOP (bit|invokeStk1 ::tcl::binary::scan :: ::tt_scan/B)'; then echo "typed: FAILED, typed code hands over at:"; echo "$out" | grep -E '^DEADOP (bit|invokeStk1 ::tcl::binary::scan :: ::tt_scan/B)'; exit 1; fi
echo "typed: no hand-over at integer operations on integers written as 0xFF, or at binary scan with a number format: ok"

# a key built from integers and literals that goes straight to an element of a native array is built as text in a buffer, not as a Tcl object (tbc_cat_*)
cat > "$tmp/k.tcl" <<'TCL'
proc tk_mat {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i + $j}]; incr a($i,$j) } }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $a($i,$i) }
    return $s
}
TCL
"$TCLSH" src/translate.tcl "$tmp/k.tcl" "$tmp/k.c" Keytest >"$tmp/k.log" 2>&1 || { echo "typed: translation failed"; tail -3 "$tmp/k.log"; exit 1; }
if grep -q "tbc_cat_init" "$tmp/k.c"; then echo "typed: FAILED, a(\$i,\$j) builds a Tcl object for the key"; exit 1; fi
echo "typed: a(\$i,\$j) keys are built as text, without objects: ok"

# string first / last / index / range have a path for one-byte characters (tbc_s_*), and a built-in that needs no frame is called through its C procedure (tbc_direct)
cat > "$tmp/s.tcl" <<'TCL'
proc ts_str {s i} { list [string first o $s] [string last o $s] [string index $s $i] [string range $s $i end] [join [split $s o] +] }
TCL
"$TCLSH" src/translate.tcl "$tmp/s.tcl" "$tmp/s.c" Strtest >"$tmp/s.log" 2>&1 || { echo "typed: translation failed"; tail -3 "$tmp/s.log"; exit 1; }
for f in tbc_s_first tbc_s_last tbc_s_index tbc_s_range tbc_direct; do
  grep -q "$f(" "$tmp/s.c" || { echo "typed: FAILED, the generated code of a string proc does not use $f"; exit 1; }
done
echo "typed: string first/last/index/range and join/split have their direct paths: ok"

# == and != against the empty string do not hand over (a number is never equal to it; any other value is when its string form is empty)
cat > "$tmp/e.tcl" <<'TCL'
proc te_loop {l} { set n 0; foreach v $l { if {$v == {}} { continue }; if {$v != ""} { incr n } }; return $n }
TCL
out=$(TBC_DEADOPS=1 "$TCLSH" src/translate.tcl "$tmp/e.tcl" "$tmp/e.c" Emptytest 2>&1)
if echo "$out" | grep -q -E '^DEADOP (eq|neq) '; then echo "typed: FAILED, == against the empty string hands over:"; echo "$out" | grep -E '^DEADOP (eq|neq) '; exit 1; fi
echo "typed: == and != against the empty string stay in typed code: ok"

# a proc that uses floating-point numbers keeps a loop over a list of numbers of either kind in typed code: its sums are tagged numbers (W), and the first addition does not
# hand over; a proc with no sign of floating-point numbers keeps its integer variables
cat > "$tmp/w.tcl" <<'TCL'
proc tw_sum {l} { set sum 0; set sumsq 0.0; foreach v $l { set sum [expr {$sum + $v}]; set sumsq [expr {$sumsq + $v * $v}] }; list $sum $sumsq }
proc tw_int {l} { set sum 0; foreach v $l { set sum [expr {$sum + $v}] }; return $sum }
TCL
out=$(env -u TBC_FORCE_WPOLICY TBC_DEADOPS=1 "$TCLSH" src/translate.tcl "$tmp/w.tcl" "$tmp/w.c" Wtest 2>&1)
if echo "$out" | grep -q -E '^DEADOP add .*tw_sum'; then echo "typed: FAILED, the sum of a list of numbers hands over:"; echo "$out" | grep -E '^DEADOP add'; exit 1; fi
echo "$out" | grep -E '::tw_sum/B ' | grep -q ' W ' || { echo "typed: FAILED, tw_sum has no tagged number variable:"; echo "$out" | grep tw_sum; exit 1; }
echo "$out" | grep -E '::tw_int/B ' | grep -q ' W' && { echo "typed: FAILED, an integer-only proc got tagged numbers:"; echo "$out" | grep tw_int; exit 1; }
echo "typed: sums of numbers of either kind stay in typed code as tagged numbers (floating-point procs only): ok"

# a tagged number is boxed only where an object is needed (here: the two values put in the returned list), not at every instruction of a loop (a boxing at the edge into each add and each
# store allocated two double objects per iteration and made such loops no faster than the interpreter)
n=$(awk '/^static .* V__3a_3atw_5fsum_B\(/ {f=1} f && /^}/ {f=0} f' "$tmp/w.c" | grep -v '^[DF][0-9a-f]*:' | grep -o '(sw[0-9]* ? tbc_newdbl' | wc -l)
[ "$n" = 2 ] || { echo "typed: FAILED, tw_sum boxes a tagged number $n times (2 expected, the two values it returns)"; exit 1; }
echo "typed: tagged numbers are not boxed inside a loop: ok"

# a proc with no sign of floating-point numbers that accumulates over data gets, besides its integer variants, one tagged-number variant (key suffix w) used once
# the proc has been seen to meet a double; procs with bit operations or without a loop get none
cat > "$tmp/a.tcl" <<'TCL'
proc ta_sum {l} { set sum 0; foreach v $l { set sum [expr {$sum + $v}] }; return $sum }
proc ta_bits {l} { set s 0; foreach v $l { set s [expr {$s ^ $v}] }; return $s }
proc ta_count {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i }; return $s }
TCL
out=$(env -u TBC_FORCE_WPOLICY TBC_DEADOPS=1 "$TCLSH" src/translate.tcl "$tmp/a.tcl" "$tmp/a.c" Adapttest 2>&1)
echo "$out" | grep -E '::ta_sum/Bw ' | grep -q ' W' || { echo "typed: FAILED, ta_sum has no adaptive tagged-number variant:"; echo "$out" | grep ta_sum; exit 1; }
echo "$out" | grep -E '::ta_sum/B ' | grep -q ' W' && { echo "typed: FAILED, the first variant of ta_sum is already tagged:"; echo "$out" | grep ta_sum; exit 1; }
echo "$out" | grep -E '::ta_(bits|count)/[A-Za-z]*w ' && { echo "typed: FAILED, a bit-operation or loop-free-of-data proc got an adaptive variant"; exit 1; }
grep -q "tbc_wp_" "$tmp/a.c" || { echo "typed: FAILED, no adaptive flag in the generated code"; exit 1; }
echo "typed: a proc that accumulates over data has an adaptive tagged-number variant; bit-operation and counting procs have none: ok"

# == and != (and the orderings) against a text literal, or between objects that need not be numbers, do not hand over at the comparison: typed code calls the generic compare
cat > "$tmp/c.tcl" <<'TCL'
proc tc_lit {x} { if {$x == "plain"} { return 1 }; if {$x != "left"} { return 2 }; return 3 }
proc tc_two {a b} { if {[lindex $a 0] == $a && [lindex $b 0] == $b} { return 1 }; return [expr {$a < $b}] }
TCL
out=$(TBC_DEADOPS=1 "$TCLSH" src/translate.tcl "$tmp/c.tcl" "$tmp/c.c" Cmptest 2>&1)
if echo "$out" | grep -q -E '^DEADOP (eq|neq|lt|le|gt|ge) '; then echo "typed: FAILED, a comparison of objects hands over:"; echo "$out" | grep -E '^DEADOP (eq|neq|lt|le|gt|ge) '; exit 1; fi
grep -q "tbc_cmpo(" "$tmp/c.c" || { echo "typed: FAILED, no generic comparison in the code of tc_lit"; exit 1; }
echo "typed: comparisons of objects and of text literals stay in typed code: ok"


# a native array reached by integer keys, or by `$i,$j` of two integers, is reached without building the key's text (tbc_r*_k, tbc_r*_k2), and a load from an array that only
# integers are stored in gives an unboxed integer
cat > "$tmp/d.tcl" <<'TCL'
proc td_sieve {n} { for {set i 0} {$i <= $n} {incr i} { set p($i) 1 }; set c 0; for {set i 2} {$i <= $n} {incr i} { if {$p($i)} { incr c } }; return $c }
proc td_mat {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i + $j}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { incr s $a($i,$j) } }; return $s }
TCL
"$TCLSH" src/translate.tcl "$tmp/d.tcl" "$tmp/d.c" Densetest >"$tmp/d.log" 2>&1 || { echo "typed: translation failed"; tail -3 "$tmp/d.log"; exit 1; }
for f in tbc_rseti_k tbc_rgetw_k tbc_rseti_k2 tbc_rgetw_k2; do
  grep -q "$f(" "$tmp/d.c" || { echo "typed: FAILED, the generated code of the array procs does not use $f"; exit 1; }
done
echo "typed: arrays by integer keys and by \$i,\$j are reached without key text, loads give unboxed integers: ok"

# an array that only doubles are stored in is held as doubles (tbc_rsetd*, tbc_rgetd*), one with integers and doubles in a proc that uses tagged numbers as numbers (loaded with tbc_rgetn*)
cat > "$tmp/dd.tcl" <<'TCL'
proc tdd_vec {n} { for {set i 0} {$i < $n} {incr i} { set x($i) [expr {$i * 0.5}] }; set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $x($i)}] }; return $s }
proc tdd_mix {n} { for {set i 0} {$i < $n} {incr i} { if {$i % 2} { set a($i) [expr {$i * 1.5}] } else { set a($i) $i } }; set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $a($i)}] }; return $s }
TCL
"$TCLSH" src/translate.tcl "$tmp/dd.tcl" "$tmp/dd.c" Dbltest >"$tmp/dd.log" 2>&1 || { echo "typed: translation failed"; tail -3 "$tmp/dd.log"; exit 1; }
for f in tbc_rsetd_k tbc_rgetd_k tbc_rgetn_k; do
  grep -q "$f(" "$tmp/dd.c" || { echo "typed: FAILED, the generated code of the array procs does not use $f"; exit 1; }
done
echo "typed: arrays of doubles and of tagged numbers are held unboxed: ok"
