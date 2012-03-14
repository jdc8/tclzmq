#  Custom routing Router to Dealer worker part

if {[llength $argv] != 1} {
    puts "Usage: rtdelaer_worker <identity>"
    exit 1
}

package require tclzmq

tclzmq::context context 1
tclzmq::socket worker context DEALER
worker setsockopt IDENTITY [lindex $argv 0]
worker connect "ipc://routing.ipc"

set total 0
while {1}  {
    # We receive one part, with the workload
    set request [worker s_recv]
    if {$request eq "END"} {
	puts "[lindex $argv 0] received: $total"
	break;
    }
    incr total
}

worker close
context term
