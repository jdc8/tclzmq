#
# Custom routing Router to Mama (ROUTER to REQ) worker code
#
# While this example runs in a single process, that is just to make
# it easier to start and stop the example. Each thread has its own
# context and conceptually acts as a separate process.
#

package require tclzmq

tclzmq::context context 1

expr {srand([pid])}

tclzmq::socket worker context REQ

# We use a string identity for ease here
set id [format "%04X-%04X" [expr {int(rand()*0x10000)}] [expr {int(rand()*0x10000)}]]
worker setsockopt IDENTITY $id
worker connect "ipc://routing.ipc"

set total 0
while {1} {
    # Tell the router we're ready for work
    worker s_send "ready"

    # Get workload from router, until finished
    set workload [worker s_recv]
    if {$workload eq "END"} {
	puts "Processed: $total tasks"
	break
    }
    incr total

    # Do some random work
    after [expr {int(rand()*1000)}]
}

worker close
context term
