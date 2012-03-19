#
# Broker peering simulation (part 2)
# Prototypes the request-reply flow
#

package require tclzmq

if {[llength $argv] < 2} {
    puts "Usage: peering2.tcl <main|client|worker> <self> <peer ...>"
    exit 1
}

set NBR_CLIENTS 10
set NBR_WORKERS 3
set LRU_READY   "READY" ; # Signals worker is ready

set peers [lassign $argv what self]
set tclsh [info nameofexecutable]
expr {srand([pid])}

proc zmsg_recv {socket} {
    set rt [list]
    lappend rt [$socket s_recv]
    while {[$socket getsockopt RCVMORE]} {
	lappend rt [$socket s_recv]
    }
    return $rt
}

proc zmsg_send {socket msgl} {
    foreach m [lrange $msgl 0 end-1] {
	$socket s_sendmore $m
    }
    $socket s_send [lindex $msgl end]
}

proc zmsg_unwrap {msglnm} {
    upvar $msglnm msgl
    set data ""
    if {[llength $msgl]} {
	set msgl [lassign $msgl data]
    }
    if {[llength $msgl] && [string length [lindex $msgl 0]] == 0} {
	set msgl [lassign $msgl empty]
    }
    return $data
}

proc zmsg_push {msgl data} {
    return [list $data {*}$msgl]
}

proc zmsg_wrap {msgl data} {
    return [list $data "" {*}$msgl]
}

switch -exact -- $what {
    client {
	# Request-reply client using REQ socket
	#
	tclzmq context context 1
	tclzmq socket client context REQ
	client connect "ipc://$self-localfe.ipc"

	while {1} {
	    # Send request, get reply
	    puts "Client: HELLO"
	    client s_send "HELLO"
	    set reply [client s_recv]
	    puts "Client: $reply"
	    after 1000
	}
	client close
	context term
    }
    worker {
	# Worker using REQ socket to do LRU routing
	#
	tclzmq context context 1
	tclzmq socket worker context REQ
	worker connect "ipc://$self-localbe.ipc"

	# Tell broker we're ready for work
	worker s_send $LRU_READY

	# Process messages as they arrive
	while {1} {
	    set msg [zmsg_recv worker]
	    puts "Worker: [lindex $msg end]"
	    lset msg end "OK"
	    zmsg_send worker $msg
	}

	worker close
	context term
    }
    main {
	puts "I: preparing broker at $self..."

	# Prepare our context and sockets
	tclzmq context context 1

	# Bind cloud frontend to endpoint
	tclzmq socket cloudfe context ROUTER
	cloudfe setsockopt IDENTITY $self
	cloudfe bind "ipc://$self-cloud.ipc"

	# Connect cloud backend to all peers
	tclzmq socket cloudbe context ROUTER
	cloudbe setsockopt IDENTITY $self

	foreach peer $peers {
	    puts "I: connecting to cloud frontend at '$peer'"
	    cloudbe connect "ipc://$peer-cloud.ipc"
	}
	# Prepare local frontend and backend
	tclzmq socket localfe context ROUTER
	localfe bind "ipc://$self-localfe.ipc"
	tclzmq socket localbe context ROUTER
	localbe bind "ipc://$self-localbe.ipc"

	# Get user to tell us when we can start…
	puts -nonewline "Press Enter when all brokers are started: "
	flush stdout
	gets stdin c

	# Start local workers
	for {set worker_nbr 0} {$worker_nbr < $NBR_WORKERS} {incr worker_nbr} {
	    puts "Starting worker $worker_nbr, output redirected to worker-$self-$worker_nbr.log"
	    exec $tclsh peering2.tcl worker $self {*}$peers > worker-$self-$worker_nbr.log 2>@1 &
	}

	# Start local clients
	for {set client_nbr 0} {$client_nbr < $NBR_CLIENTS} {incr client_nbr} {
	    puts "Starting client $client_nbr, output redirected to client-$self-$client_nbr.log"
	    exec $tclsh peering2.tcl client $self {*}$peers > client-$self-$client_nbr.log 2>@1 &
	}

	# Interesting part
	# -------------------------------------------------------------
	# Request-reply flow
	# - Poll backends and process local/cloud replies
	# - While worker available, route localfe to local or cloud

	# Queue of available workers
	set workers {}

	proc route_to_cloud {msg} {
	    global peers
	    # Route reply to cloud if it's addressed to a broker
	    foreach peer $peers {
		if {$peer eq [lindex $msg 0]} {
		    zmsg_send cloudfe $msg
		    return {}
		}
	    }
	    return $msg
	}

	proc handle_localbe {} {
	    global workers
	    # Handle reply from local worker
	    set msg [zmsg_recv localbe]
	    set address [zmsg_unwrap msg]
	    lappend workers $address
	    # If it's READY, don't route the message any further
	    if {[lindex $msg 0] ne "READY"} {
		set msg [route_to_cloud $msg]
		if {[llength $msg]} {
		    zmsg_send localfe $msg
		}
	    }
	}

	proc handle_cloudbe {} {
	    # Or handle reply from peer broker
	    set msg [zmsg_recv cloudbe]
	    # We don't use peer broker address for anything
	    zmsg_unwrap msg
	    set msg [route_to_cloud $msg]
	    if {[llength $msg]} {
		zmsg_send localfe $msg
	    }
	}

	proc handle_client {s reroutable} {
	    global peers workers
	    if {[llength $workers]} {
		set msg [zmsg_recv $s]
		# If reroutable, send to cloud 20% of the time
		# Here we'd normally use cloud status information
		#
		if {$reroutable && [llength $peers] && [expr {int(rand()*5)}] == 0} {
		    set peer [lindex $peers [expr {int(rand()*[llength $peers])}]]
		    set msg [zmsg_push $msg $peer]
		    zmsg_send cloudbe $msg
		} else {
		    set frame [lindex $workers 0]
		    set workers [lrange $workers 1 end]
		    set msg [zmsg_wrap $msg $frame]
		    zmsg_send localbe $msg
		}
	    }
	}

	proc handle_clients {} {
            # We'll do peer brokers first, to prevent starvation
	    if {[cloudfe getsockopt EVENTS] & 0x1} {
		handle_client cloudfe 0
	    }
	    if {[localfe getsockopt EVENTS] & 0x1} {
		handle_client localfe 1
	    }
	}

	localbe readable handle_localbe
	cloudbe readable handle_cloudbe
	localfe readable [list handle_clients]
	cloudfe readable [list handle_clients]

	vwait forever

	# When we're done, clean up properly
	localbe close
	localfe close
	cloudbe close
	cloudfe close
	context term
    }
}
