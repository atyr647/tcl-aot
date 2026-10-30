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
