if {[llength $argv] != 1} {
    puts "Usage: rtmama.tcl <number_of_workers>"
    exit 1
}

set tclsh [info nameofexecutable]
set nbr_of_workers [lindex $argv 0]

puts "Start main"
exec $tclsh rtmama_main.tcl $nbr_of_workers > main.log 2>@1 &

for {set i 0} {$i < $nbr_of_workers} {incr i} {
    puts "Start worker $i"
    exec $tclsh rtmama_worker.tcl > worker$i.log 2>@1 &
}
