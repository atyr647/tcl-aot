# tcl-aot-merge.tcl OUT IN... : the capture files of several runs of one program as a single file, each definition once, in the order first seen.
# A capture file is a list of commands (`proc ...` and `namespace eval ns {}`), each complete in itself, one after another.
lassign $argv out
set seen [dict create]
set buf ""
set res {}
foreach file [lrange $argv 1 end] {
    set f [open $file r]; fconfigure $f -encoding utf-8
    set text [read $f]; close $f
    set buf ""
    foreach line [split $text \n] {
        append buf $line \n
        if {![info complete $buf]} continue
        if {[string trim $buf] ne "" && ![dict exists $seen $buf]} { dict set seen $buf 1; lappend res $buf }
        set buf ""
    }
    if {[string trim $buf] ne ""} { puts stderr "tcl-aot-merge: $file ends in the middle of a command"; exit 1 }
}
set f [open $out w]; fconfigure $f -encoding utf-8
foreach c $res { puts -nonewline $f $c }
close $f
puts "[llength $res] definitions from [expr {[llength $argv] - 1}] file(s)"
