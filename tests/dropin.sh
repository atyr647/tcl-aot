#!/bin/sh
# The drop-in build (tools/tcl-aot): a program that is not changed in any way is run once to record its procs, a shell is built, and the same program run by that
# shell gives the same output and exit status as with the interpreter alone (TBC_OFF=1), with its procs compiled: the ones from its files, the ones it builds at run
# time, the ones of a run with other arguments (-also), and the ones in namespaces with variables.  A Tk program is run the same way when a static Tk is built.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "dropin: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app/lib"

cat > "$tmp/app/lib/geo.tcl" <<'TCL'
namespace eval geo {
    variable scale 2.5
    proc area {w h} { variable scale; set a 1.0; foreach f [list $w $h $scale] { set a [expr {$a * $f}] }; return $a }
    proc norm {l} { set s 0.0; foreach v $l { set s [expr {$s + $v * $v}] }; return [expr {sqrt($s)}] }
}
proc fib {n} { if {$n < 2} { return $n }; expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]} }
TCL
cat > "$tmp/app/app.tcl" <<'TCL'
# a program: its procs are in a file next to it, some are made at run time, one is only defined for some arguments
source [file join [file dirname [info script]] lib geo.tcl]
foreach k {3 5} {
    proc mul$k {n} [string map [list @K@ $k] {set s 0; for {set i 0} {$i < $n} {incr i} { incr s [expr {($i * @K@) % 1013}] }; return $s}]
}
proc hist {n} { for {set i 0} {$i < $n} {incr i} { incr h([expr {$i % 7}]) }; return [lsort -stride 2 [array get h]] }
if {"-extra" in $argv} {
    proc extra {n} { set s 0.0; for {set i 1} {$i <= $n} {incr i} { set s [expr {$s + 1.0 / $i}] }; return [format %.9f $s] }
    puts "extra [extra 20000]"
}
puts "area [geo::area 3 4] norm [geo::norm {3 4 12}] fib [fib 18] mul [mul3 5000] [mul5 5000] hist [hist 100]"
puts "argv $argv"
if {"-exit" in $argv} { exit 3 }
catch {
    if {[info commands ::tbc::attached] ne ""} { puts "ATTACHED [lsort [tbc::attached]]" }
}
TCL

out=$("$TBC_ROOT/tools/tcl-aot" build -notk -o "$tmp/out" -also "a -extra" "$tmp/app/app.tcl" a -exit 2>&1) || { printf '%s\n' "$out"; echo "dropin: FAILED, the build"; exit 1; }
for want in 'recording run 2' 'procs compiled'; do
  printf '%s\n' "$out" | grep -q "$want" || { printf '%s\n' "$out"; echo "dropin: FAILED, the build output has no '$want'"; exit 1; }
done

# the same program, unchanged: compiled shell against the interpreter alone, with the arguments of the recording runs and with others
for args in "a -exit" "a -extra" "b" "-extra -exit"; do
  # shellcheck disable=SC2086
  want=$(TBC_OFF=1 "$tmp/out/shell" "$tmp/app/app.tcl" $args 2>&1; echo "status $?")
  # shellcheck disable=SC2086
  got=$("$tmp/out/shell" "$tmp/app/app.tcl" $args 2>&1; echo "status $?")
  # (the line that names the attached procs exists only in the compiled run)
  want=$(printf '%s\n' "$want" | grep -v '^ATTACHED'); got=$(printf '%s\n' "$got" | grep -v '^ATTACHED')
  [ "$want" = "$got" ] || { echo "dropin: FAILED, output differs for '$args':"; printf '%s\n' "$want"; printf '%s\n' "$got"; exit 1; }
done
echo "dropin: the unchanged program gives the interpreter's output and exit status, for the recorded arguments and for others: ok"

# the procs are compiled: those of the file, the ones built at run time, and the one only a second recording run defined
att=$("$tmp/out/shell" "$tmp/app/app.tcl" a -extra 2>&1 | grep '^ATTACHED')
for p in ::geo::area ::geo::norm ::fib ::mul3 ::mul5 ::hist ::extra; do
  printf '%s\n' "$att" | grep -q -E "$p( |\$)" || { echo "dropin: FAILED, $p is not compiled: $att"; exit 1; }
done
echo "dropin: procs from a sourced file, built at run time, in a namespace, and defined only in the second recording run are compiled: ok"

# Tk: `package require Tk` in a program finds the static Tk of the shell (skipped when there is no static Tk or no display)
if [ "$TBC_TK" = 1 ]; then
  cat > "$tmp/app/tkapp.tcl" <<'TCL'
package require Tk
proc layout {n} { set w 0; for {set i 0} {$i < $n} {incr i} { incr w [expr {$i * 3 % 17}] }; return $w }
pack [label .l -text [layout 1000]]
update
puts "tk [winfo exists .l] [.l cget -text] [package require Tk]"
exit
TCL
  if "$TBC_ROOT/tools/tcl-aot" build -o "$tmp/outtk" "$tmp/app/tkapp.tcl" >"$tmp/tkbuild.log" 2>&1; then
    want=$(TBC_OFF=1 "$tmp/outtk/shell" "$tmp/app/tkapp.tcl" 2>&1); got=$("$tmp/outtk/shell" "$tmp/app/tkapp.tcl" 2>&1)
    case "$want" in
      "tk 1 "*) [ "$want" = "$got" ] && echo "dropin: a Tk program runs in the shell with its static Tk, with the interpreter's output: ok" || { echo "dropin: FAILED, Tk output differs: $want / $got"; exit 1; } ;;
      *"find package Tk"*) echo "dropin: FAILED, the shell does not provide Tk: $want"; exit 1 ;;
      *) echo "dropin: Tk program skipped (no window system: $(printf '%s' "$want" | head -1)): ok" ;;
    esac
  else
    tail -5 "$tmp/tkbuild.log"; echo "dropin: FAILED, the Tk build"; exit 1
  fi
else
  echo "dropin: no static Tk built (make tk), the Tk case is skipped: ok"
fi
