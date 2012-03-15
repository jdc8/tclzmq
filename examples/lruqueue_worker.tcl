#
# Least-recently used (LRU) queue device - worker
#

# Worker using REQ socket to do LRU routing
# Since s_send and s_recv can't handle 0MQ binary identities we
# set a printable text identity to allow routing.

package require tclzmq

tclzmq::context context 1

expr {srand([pid])}

tclzmq::socket worker context REQ
set id [format "%04X-%04X" [expr {int(rand()*0x10000)}] [expr {int(rand()*0x10000)}]]
worker setsockopt IDENTITY $id
worker connect "ipc://backend.ipc"

# Tell broker we're ready for work
worker s_send "READY"

while {1} {
    # Read and save all frames until we get an empty frame
    # In this example there is only 1 but it could be more
    set address [worker s_recv]
    set empty [worker s_recv]

    # Get request, send reply
    set request [worker s_recv]
    puts "Worker $id: $request"

    worker s_sendmore $address
    worker s_sendmore ""
    worker s_send "OK"
}

worker close
context term
