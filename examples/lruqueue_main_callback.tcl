#
# Least-recently used (LRU) queue device - main
#

if {[llength $argv] != 2} {
    puts "Usage: lruqueue_main.tcl <number_of_clients> <number_of_workers>"
    exit 1
}

lassign $argv NBR_CLIENTS NBR_WORKERS

package require tclzmq

tclzmq::context context 1

tclzmq::socket frontend context ROUTER
tclzmq::socket backend context ROUTER
frontend bind "ipc://frontend.ipc"
backend bind "ipc://backend.ipc"

# Logic of LRU loop
# - Poll backend always, frontend only if 1+ worker ready
# - If worker replies, queue worker as ready and forward reply
#   to client if necessary
# - If client requests, pop next worker and send request to it

# Queue of available workers
set client_nbr $NBR_CLIENTS
set worker_queue {}

set done 0

proc process_backend {fe be} {
    global done worker_queue client_nbr NBR_WORKERS
    # Queue worker address for LRU routing
    set worker_addr [$be s_recv]
    if {!([llength $worker_queue] < $NBR_WORKERS)} {
	error "available_workers < NBR_WORKERS"
    }
    lappend worker_queue $worker_addr

    # Second frame is empty
    set empty [$be s_recv]

    # Third frame is READY or else a client reply address
    set client_addr [$be s_recv]

    # If client reply, send rest back to frontend
    if {$client_addr ne "READY"} {
	set empty [$be s_recv]
	set reply [$be s_recv]

	$fe s_sendmore $client_addr
	$fe s_sendmore ""
	$fe s_send $reply
	incr client_nbr -1
	if {$client_nbr == 0} {
	    set ::done 1
	    break
	}
    }
}

proc process_frontend {fe be} {
    global done worker_queue client_nbr
    if {[llength $worker_queue]} {
	# Now get next client request, route to LRU worker
	# Client request is [address][empty][request]
	set client_addr [$fe s_recv]
	set empty [$fe s_recv]
	set request [$fe s_recv]

	$be s_sendmore [lindex $worker_queue 0]
	$be s_sendmore ""
	$be s_sendmore $client_addr
	$be s_sendmore ""
	$be s_send $request

	# Dequeue and drop the next worker address
	set worker_queue [lrange $worker_queue 1 end]
    }
}

frontend readable [list process_frontend ::frontend ::backend]
backend readable [list process_backend ::frontend ::backend]

vwait done

frontend close
backend close
context term
