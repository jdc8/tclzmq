if {[llength $argv] != 2} {
    puts "Usage: lruqueue.tcl <number_of_clients> <number_of_workers>"
    exit 1
}

set tclsh [info nameofexecutable]
lassign $argv NBR_CLIENTS NBR_WORKERS

puts "Start main, output redirect to main.log"
exec $tclsh lruqueue_main.tcl $NBR_CLIENTS $NBR_WORKERS > main.log 2>@1 &

after 1000

for {set i 0} {$i < $NBR_WORKERS} {incr i} {
    puts "Start worker $i, output redirect to worker$i.log"
    exec $tclsh lruqueue_worker.tcl > worker$i.log 2>@1 &
}

after 1000

for {set i 0} {$i < $NBR_CLIENTS} {incr i} {
    puts "Start client $i, output redirect to client$i.log"
    exec $tclsh lruqueue_client.tcl > client$i.log 2>@1 &
}
