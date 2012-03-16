if {[llength $argv] != 2} {
    puts "Usage: asyncsrv.tcl <number_of_clients> <number_of_workers>"
    exit 1
}

set tclsh [info nameofexecutable]
lassign $argv NBR_CLIENTS NBR_WORKERS

puts "Start server, output redirected to server.log"
exec $tclsh asyncsrv_server.tcl $NBR_WORKERS > server.log 2>@1 &

after 1000

for {set i 0} {$i < $NBR_CLIENTS} {incr i} {
    puts "Start client $i, output redirect to client$i.log"
    exec $tclsh asyncsrv_client.tcl > client$i.log 2>@1 &
}
