# Driver of tests/mfguard.sh (decision 86).  usage: shell mfguard.tcl SCENARIO WHEN [expect [expectho]]
#   WHEN: before | after | twice (the redefinition is made before the first call of the compiled procs, after it, or in between two rounds)
#   expect: a list of {proc ...} that must have no hand-over in the counters of the -DTBC_COV module (the results are compared with the interpreter's in every case); a name
#   without :: is in ::mf, one with :: is taken as it is.  expectho: procs that must have handed over (the check that a replaced function is noticed, not only that the result is right).
#   Every scenario can have an undo script (the table `undo`), run at the end: results are compared again after it.  The log ::tlog (execution traces) is compared too.
# The compiled procs live in ::mf (the file mfguard_procs.tcl made by the script); a second interpreter, `ref`, has the same definitions without the module.
lassign $argv scen when expect expectho
set pre {}
set defs {
  pre_sin       {namespace eval ::mf::tcl::mathfunc {}; proc ::mf::tcl::mathfunc::sin {x} { return "PRESN<$x>" }}
  pre_max_other {proc ::tcl::mathfunc::max {args} { return "PREMX<$args>" }}
  nsproc_floor  {namespace eval ::mf::tcl::mathfunc {}; proc ::mf::tcl::mathfunc::floor {x} { return "NSFL<$x>" }}
  nsproc_double {namespace eval ::mf::tcl::mathfunc {}; proc ::mf::tcl::mathfunc::double {x} { return "NSDB<$x>" }}
  nsproc_sin    {namespace eval ::mf::tcl::mathfunc {}; proc ::mf::tcl::mathfunc::sin {x} { return "NSSN<$x>" }}
  nsproc_max    {namespace eval ::mf::tcl::mathfunc {}; proc ::mf::tcl::mathfunc::max {args} { return "NSMX<$args>" }}
  glproc_floor  {proc ::tcl::mathfunc::floor {x} { return "GLFL<$x>" }}
  glproc_double {proc ::tcl::mathfunc::double {x} { return "GLDB<$x>" }}
  glproc_max    {proc ::tcl::mathfunc::max {args} { return "GLMX<$args>" }}
  glalias_floor {rename ::tcl::mathfunc::floor ::tcl::mathfunc::floor_o; interp alias {} ::tcl::mathfunc::floor {} myfl}
  glrename_floor {rename ::tcl::mathfunc::floor ::tcl::mathfunc::floor_o}
  gldelete_double {rename ::tcl::mathfunc::double {}}
  glrename_max  {rename ::tcl::mathfunc::max ::tcl::mathfunc::max_o}
  glrename_sin  {rename ::tcl::mathfunc::sin ::tcl::mathfunc::sin_o}
  nsalias_floor {namespace eval ::mf::tcl::mathfunc {}; interp alias {} ::mf::tcl::mathfunc::floor {} myfl}
  nsalias_double {namespace eval ::mf::tcl::mathfunc {}; interp alias {} ::mf::tcl::mathfunc::double {} mydb}
  nsalias_sin   {namespace eval ::mf::tcl::mathfunc {}; interp alias {} ::mf::tcl::mathfunc::sin {} mysn}
  nsalias_max   {namespace eval ::mf::tcl::mathfunc {}; interp alias {} ::mf::tcl::mathfunc::max {} mymx}
  nsimport_floor {namespace eval ::src {namespace export fl; proc fl {x} { return "IMP<$x>" }}; namespace eval ::mf::tcl::mathfunc {namespace import -force ::src::fl}; rename ::mf::tcl::mathfunc::fl ::mf::tcl::mathfunc::floor}
  nsimport_sin  {namespace eval ::src {namespace export sin; proc sin {x} { return "IMPSN<$x>" }}; namespace eval ::mf::tcl::mathfunc {namespace import -force ::src::sin}}
  glimport_floor {namespace eval ::src {namespace export floor; proc floor {x} { return "GIMP<$x>" }}; namespace eval ::tcl::mathfunc {namespace import -force ::src::floor}}
  path_floor    {namespace eval ::alt::tcl::mathfunc {}; proc ::alt::tcl::mathfunc::floor {x} { return "PATHFL<$x>" }; namespace eval ::mf {namespace path ::alt}}
  pathalias_floor {namespace eval ::alt2::tcl::mathfunc {}; interp alias {} ::alt2::tcl::mathfunc::floor {} myfl; namespace eval ::mf {namespace path ::alt2}}
  pathalias_sin {namespace eval ::alt3::tcl::mathfunc {}; interp alias {} ::alt3::tcl::mathfunc::sin {} mysn; namespace eval ::mf {namespace path ::alt3}}
  trace_floor   {trace add execution ::tcl::mathfunc::floor enter tlog}
  trace_sin     {trace add execution ::tcl::mathfunc::sin enter tlog}
  trace_double  {trace add execution ::tcl::mathfunc::double enter tlog}
  trace_max     {trace add execution ::tcl::mathfunc::max enter tlog}
  trace_hypot   {trace add execution ::tcl::mathfunc::hypot leave tlog}
  eng           {namespace eval ::eng {namespace export sin cos hypot; proc sin {x} {return [expr {sin($x) + 1.0e-9}]}; proc cos {x} {return [expr {cos($x) + 1.0e-9}]}; proc hypot {x y} {return [expr {hypot($x, $y) + 1.0e-9}]}; proc install {args} {foreach ns $args { namespace eval ${ns}::tcl::mathfunc { namespace import -force ::eng::sin ::eng::cos ::eng::hypot } }}}; ::eng::install ::mf}
  pre_eng       {namespace eval ::eng {namespace export sin cos hypot; proc sin {x} {return [expr {sin($x) + 1.0e-9}]}; proc cos {x} {return [expr {cos($x) + 1.0e-9}]}; proc hypot {x y} {return [expr {hypot($x, $y) + 1.0e-9}]}; proc install {args} {foreach ns $args { namespace eval ${ns}::tcl::mathfunc { namespace import -force ::eng::sin ::eng::cos ::eng::hypot } }}}; ::eng::install ::mf}
  other_eng     {namespace eval ::eng {namespace export sin cos hypot; proc sin {x} {return [expr {sin($x) + 1.0e-9}]}; proc cos {x} {return [expr {cos($x) + 1.0e-9}]}; proc hypot {x y} {return [expr {hypot($x, $y) + 1.0e-9}]}; proc install {args} {foreach ns $args { namespace eval ${ns}::tcl::mathfunc { namespace import -force ::eng::sin ::eng::cos ::eng::hypot } }}}; ::eng::install ::mf2}
  pre_other_eng {namespace eval ::eng {namespace export sin cos hypot; proc sin {x} {return [expr {sin($x) + 1.0e-9}]}; proc cos {x} {return [expr {cos($x) + 1.0e-9}]}; proc hypot {x y} {return [expr {hypot($x, $y) + 1.0e-9}]}; proc install {args} {foreach ns $args { namespace eval ${ns}::tcl::mathfunc { namespace import -force ::eng::sin ::eng::cos ::eng::hypot } }}}; ::eng::install ::mf2}
  none          {}
}
# what takes the scenario's change back (compared again afterwards)
set undo {
  nsalias_floor {rename ::mf::tcl::mathfunc::floor {}}
  nsalias_sin   {rename ::mf::tcl::mathfunc::sin {}}
  nsimport_sin  {namespace eval ::mf::tcl::mathfunc {namespace forget ::src::sin}}
  eng           {namespace eval ::mf::tcl::mathfunc {namespace forget ::eng::sin ::eng::cos ::eng::hypot}}
  path_floor    {namespace eval ::mf {namespace path {}}}
  pathalias_floor {namespace eval ::mf {namespace path {}}}
  trace_floor   {trace remove execution ::tcl::mathfunc::floor enter tlog}
  trace_sin     {trace remove execution ::tcl::mathfunc::sin enter tlog}
  trace_double  {trace remove execution ::tcl::mathfunc::double enter tlog}
  glimport_floor {rename ::tcl::mathfunc::floor {}; rename ::src::floor ::tcl::mathfunc::floor}
}
proc myfl {x} { return "FL<$x>" }
proc mydb {x} { return "DB<$x>" }
proc mysn {x} { return "SN<$x>" }
proc mymx {args} { return "MX<$args>" }
proc tlog {args} { lappend ::tlog $args }
set tlog {}
if {[string match pre_* $scen]} { uplevel #0 [dict get $defs $scen] }
load {} Mf
uplevel #0 [list source $::env(MF_PROCS)]
interp create ref
ref eval {proc myfl {x} { return "FL<$x>" }; proc mydb {x} { return "DB<$x>" }; proc mysn {x} { return "SN<$x>" }; proc mymx {args} { return "MX<$args>" }; proc tlog {args} { lappend ::tlog $args }; set tlog {}}
if {[string match pre_* $scen]} { ref eval [dict get $defs $scen] }
ref eval [read [open $::env(MF_PROCS)]]
proc both {script} { uplevel #0 $script; ref eval $script }
set bad 0
proc call {c} { set r [catch {uplevel #0 $c} v]; list $r $v }
proc rcall {c} { set r [catch {ref eval $c} v]; list $r $v }
set calls {{::mf::all 3} {::mf::all 2.5} {::mf::all -4} {::mf::loop 20} {::mf::fl 7} {::mf::db 7} {::mf::sn 1.5} {::mf::hy 1 2} {::mf::mx 5 6} {::mf::mx 9 6} {::mf::red 100.5} {::mf::red 0.1} {::mf::fl 1e300} {::mf2::sn 1.5} {::mf2::fl 7} {::mf::sn 3.8325829961488878}}
proc check {tag} {
    foreach c $::calls { set a [call $c]; set b [rcall $c]; if {$a ne $b} { puts "MISMATCH $::scen/$::when/$tag: $c: [list $a] against [list $b]"; incr ::bad } }
    set la [uplevel #0 {set ::tlog}]; set lb [ref eval {set ::tlog}]
    if {$la ne $lb} { puts "MISMATCH $::scen/$::when/$tag: execution trace log: [llength $la] entries against [llength $lb]"; incr ::bad }
}
if {$when eq "before"} { both [dict get $defs $scen] }
check first; check second
if {$when eq "after"} { both [dict get $defs $scen]; check afterdef; check afterdef2 }
if {$when eq "twice"} { check x; both [dict get $defs $scen]; check y; foreach c $::calls { call $c; rcall $c }; check z }
if {[dict exists $undo $scen]} { both [dict get $undo $scen]; check undone; check undone2 }
proc fullname {p} { expr {[string match ::* $p] ? $p : "::mf::$p"} }
set d [tbc::hot -dict]
foreach p $expect {
    set p [fullname $p]
    if {![dict exists $d $p]} { puts "FAILED: $p was never entered typed"; incr bad; continue }
    if {[dict get $d $p handovers] != 0} { puts "FAILED: $p handed over [dict get $d $p handovers] times: [tbc::hot -top 2]"; incr bad }
}
foreach p $expectho {
    set p [fullname $p]
    if {![dict exists $d $p] || [dict get $d $p handovers] == 0} { puts "FAILED: $p did not hand over, though the function it calls is replaced"; incr bad }
}
puts "$scen/$when: [expr {$bad ? "FAILED ($bad)" : "ok"}]"
exit [expr {$bad != 0}]
