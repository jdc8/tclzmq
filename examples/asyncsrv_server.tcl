#
# Asynchronous client-to-server (DEALER to ROUTER)
#
# This is our server task It uses the multithreaded server model to deal
# requests out to a pool of workers and route replies back to clients. One
# worker can handle one request at a time but one client can talk to multiple
# workers at once.

if {[llength $argv] != 1} {
    puts "Usage: asyncsrv.tcl <number_of_workers>"
    exit 1
}

set tclsh [info nameofexecutable]
lassign $argv NBR_WORKERS

package require tclzmq

tclzmq context context 1

# Frontend socket talks to clients over TCP
tclzmq socket frontend context ROUTER
frontend bind "tcp://*:5570"

# Backend socket talks to workers over inproc
tclzmq socket backend context DEALER
backend bind "ipc://backend"

#  Launch pool of worker threads, precise number is not critical
for {set thread_nbr 0} {$thread_nbr < $NBR_WORKERS} {incr thread_nbr} {
    exec $tclsh asyncsrv_worker.tcl > worker$thread_nbr.log 2>@1 &
}

#  Connect backend to frontend via a queue device
#  We could do this:
#      zmq_device (ZMQ_QUEUE, frontend, backend);
#  But doing it ourselves means we can debug this more easily

proc do_frontend {} {
    set address [frontend s_recv]
    set data [frontend s_recv]

    backend s_sendmore $address
    backend s_send $data
}

proc do_backend {} {
    set address [backend s_recv]
    set data [backend s_recv]

    frontend s_sendmore $address
    frontend s_send $data
}

backend readable do_backend
frontend readable do_frontend
vwait forever

frontend close
backend close
context term

