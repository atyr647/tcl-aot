# Stands in for libbench: `bench` runs the -pre script once, times the -body (best of 5 runs, microseconds) and runs the -post script; results are printed as
# "BENCH <file> <desc> <microseconds> <result>" with the value of the last run of the body, so that interpreted and compiled runs can be compared.
if {[info exists ::env(COMPILED)]} { load {} Realbench }
set ::benchfile [file tail [lindex $argv 0]]
proc bench {args} {
    array set o {-pre {} -body {} -desc {} -post {}}
    foreach {k v} $args { switch -glob -- $k { -pr* { set o(-pre) $v } -bo* { set o(-body) $v } -de* { set o(-desc) $v } -po* { set o(-post) $v } } }
    if {[catch { uplevel #0 $o(-pre) } err]} { puts "BENCH $::benchfile {$o(-desc)} ERROR pre: [string range $err 0 60]"; return }
    set best 1e30; set res {}
    for {set i 0} {$i < 5} {incr i} {
        set t0 [clock microseconds]
        if {[catch { uplevel #0 $o(-body) } res]} { puts "BENCH $::benchfile {$o(-desc)} ERROR body: [string range $res 0 60]"; catch { uplevel #0 $o(-post) }; return }
        set t [expr {[clock microseconds] - $t0}]
        if {$t < $best} { set best $t }
    }
    catch { uplevel #0 $o(-post) }
    puts "BENCH $::benchfile {$o(-desc)} $best [string range [string map {\n { }} $res] 0 40]"
}
set ::BENCH(ITERS) 1
# libbench's helpers: temporary files in the directory the program runs in
proc bench_tmpfile {} { return [file join [pwd] tclbench[pid][incr ::BENCH(uniqid)].dat] }
proc bench_rm {args} { foreach f $args { catch { file delete $f } } }
set ::BENCH(uniqid) 0
source [lindex $argv 0]
