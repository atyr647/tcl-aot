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
