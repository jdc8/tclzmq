set tclsh [info nameofexecutable]
puts "Start main"
exec $tclsh rtmama_main.tcl > main.log 2>@1 &
for {set i 0} {$i < 10} {incr i} {
    puts "Start worker $i"
    exec $tclsh rtmama_worker.tcl > worker$i.log 2>@1 &
}
