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
while {!$done} {
    if {[llength $worker_queue]} {
	set poll_set [list [list backend [list POLLIN]] [list frontend [list POLLIN]]]
    } else {
	set poll_set [list [list backend [list POLLIN]]]
    }
    set rpoll_set [tclzmq::poll $poll_set -1]
    foreach rpoll $rpoll_set {
	switch [lindex $rpoll 0] {
	    backend {
		# Queue worker address for LRU routing
		set worker_addr [backend s_recv]
		if {!([llength $worker_queue] < $NBR_WORKERS)} {
		    error "available_workers < NBR_WORKERS"
		}
		lappend worker_queue $worker_addr

		# Second frame is empty
		set empty [backend s_recv]

		# Third frame is READY or else a client reply address
		set client_addr [backend s_recv]

		# If client reply, send rest back to frontend
		if {$client_addr ne "READY"} {
		    set empty [backend s_recv]
		    set reply [backend s_recv]

		    frontend s_sendmore $client_addr
		    frontend s_sendmore ""
		    frontend s_send $reply
		    incr client_nbr -1
		    if {$client_nbr == 0} {
			set done 1
			break
		    }
		}
	    }
	    frontend {
		# Now get next client request, route to LRU worker
		# Client request is [address][empty][request]
		set client_addr [frontend s_recv]
		set empty [frontend s_recv]
		set request [frontend s_recv]

		backend s_sendmore [lindex $worker_queue 0]
		backend s_sendmore ""
		backend s_sendmore $client_addr
		backend s_sendmore ""
		backend s_send $request

		# Dequeue and drop the next worker address
		set worker_queue [lrange $worker_queue 1 end]
	    }
	}
    }
}

frontend close
backend close
context term
