# Stands in for libbench: `bench` runs the -pre script once, times the -body (run -iter times, best of three, nanoseconds per run) and runs the -post script; results are printed as
# "BENCH <file> <desc> <nanoseconds per run> <result>" with the value of the last run of the body, so that interpreted and compiled runs can be compared.
if {[info exists ::env(COMPILED)]} { load {} Realbench }
set ::benchfile [file tail [lindex $argv 0]]
proc bench {args} {
    array set o {-pre {} -body {} -desc {} -post {} -iter 1000}
    foreach {k v} $args { switch -glob -- $k { -pr* { set o(-pre) $v } -bo* { set o(-body) $v } -de* { set o(-desc) $v } -po* { set o(-post) $v } -it* { set o(-iter) $v } } }
    if {[catch { uplevel #0 $o(-pre) } err]} { puts "BENCH $::benchfile {$o(-desc)} ERROR pre: [string range $err 0 60]"; return }
    if {[info exists ::env(COUNT)]} { puts "BENCH $::benchfile {$o(-desc)} 0 [string range [string map {\n { }} $res] 0 40]"; catch { uplevel #0 $o(-post) }; return }
    # (as libbench does it: the body run -iter times by `time`, best of three, nanoseconds per run; the value of one more run is the result compared)
    if {[catch { uplevel #0 $o(-body) } res]} { puts "BENCH $::benchfile {$o(-desc)} ERROR body: [string range $res 0 60]"; catch { uplevel #0 $o(-post) }; return }
    set best 1e30
    for {set i 0} {$i < 3} {incr i} {
        set t [lindex [uplevel #0 [list time $o(-body) $o(-iter)]] 0]
        if {$t < $best} { set best $t }
    }
    catch { uplevel #0 $o(-post) }
    puts "BENCH $::benchfile {$o(-desc)} [expr {round($best * 1000)}] [string range [string map {\n { }} $res] 0 40]"
}
set ::BENCH(ITERS) 1
# COUNT=1: each body runs once and is not timed (for instruction counts under valgrind); SKIP=1: only the start-up, for the baseline of such a count
if {[info exists ::env(SKIP)]} exit
# libbench's helpers: temporary files in the directory the program runs in
proc bench_tmpfile {} { return [file join [pwd] tclbench[pid][incr ::BENCH(uniqid)].dat] }
proc bench_rm {args} { foreach f $args { catch { file delete $f } } }
set ::BENCH(uniqid) 0
source [lindex $argv 0]
