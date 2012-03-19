#
# Broker peering simulation (part 3)
# Prototypes the full flow of status and tasks
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

switch -exact -- $what {
    client {
	# Request-reply client using REQ socket
	# To simulate load, clients issue a burst of requests and then
	# sleep for a random period.
	#
	tclzmq context context 1
	tclzmq socket client context REQ
	client connect "ipc://$self-localfe.ipc"
	tclzmq socket monitor context PUSH
	monitor connect "ipc://$self-monitor.ipc"

	proc process_client {} {
	    global task_id done
	    client readable {}
	    set reply [client s_recv]
	    if {$task_id ne $reply} {
		monitor s_send "E: CLIENT EXIT - reply '$reply' not equal to task-id '$task_id'"
		exit 1
	    }
	    monitor s_send $reply
	    set done 1
	}

	while {1} {
	    after [expr {int(rand()*5)*1000}]
	    set burst [expr {int(rand()*15)}]
	    while {$burst} {
		set task_id [format "%04X" [expr {int(rand()*0x10000)}]]

		#  Send request with random hex ID
		client s_send $task_id

		#  Wait max ten seconds for a reply, then complain
		client readable process_client
		after 10000 [list set done 0]

		vwait done
		if {!$done} {
		    monitor s_send "E: CLIENT EXIT - lost task '$task_id'"
		    exit 1
		}
	    }
	}

	client close
	control close
	context term
    }
    worker {
	#  Worker using REQ socket to do LRU routing
	#
	tclzmq context context 1
	tclzmq socket worker context REQ
	worker connect "ipc://$self-localbe.ipc"

	# Tell broker we're ready for work
	worker s_send $LRU_READY

	# Process messages as they arrive
	while {1} {
	    #  Workers are busy for 0/1 seconds
	    set msg [tclzmq zmsg_recv worker]
	    after [expr {int(rand()*2)*1000}]
	    tclzmq zmsg_send worker $msg
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

	# Bind state backend / publisher to endpoint
	tclzmq socket statebe context PUB
	statebe bind "ipc://$self-state.ipc"

	# Connect cloud backend to all peers
	tclzmq socket cloudbe context ROUTER
	cloudbe setsockopt IDENTITY $self

	foreach peer $peers {
	    puts "I: connecting to cloud frontend at '$peer'"
	    cloudbe connect "ipc://$peer-cloud.ipc"
	}

	# Connect statefe to all peers
	tclzmq socket statefe context SUB
	statefe setsockopt SUBSCRIBE ""
	foreach peer $peers {
	    puts "I: connecting to state backend at '$peer'"
	    statefe connect "ipc://$peer-state.ipc"
	}

	# Prepare local frontend and backend
	tclzmq socket localfe context ROUTER
	localfe bind "ipc://$self-localfe.ipc"

	tclzmq socket localbe context ROUTER
	localbe bind "ipc://$self-localbe.ipc"

	# Prepare monitor socket
	tclzmq socket monitor context PULL
	monitor bind "ipc://$self-monitor.ipc"

	# Start local workers
	for {set worker_nbr 0} {$worker_nbr < $NBR_WORKERS} {incr worker_nbr} {
	    puts "Starting worker $worker_nbr, output redirected to worker-$self-$worker_nbr.log"
	    exec $tclsh peering3.tcl worker $self {*}$peers > worker-$self-$worker_nbr.log 2>@1 &
	}

	# Start local clients
	for {set client_nbr 0} {$client_nbr < $NBR_CLIENTS} {incr client_nbr} {
	    puts "Starting client $client_nbr, output redirected to client-$self-$client_nbr.log"
	    exec $tclsh peering3.tcl client $self {*}$peers > client-$self-$client_nbr.log 2>@1 &
	}

	# Interesting part
	# -------------------------------------------------------------
	# Publish-subscribe flow
	# - Poll statefe and process capacity updates
	# - Each time capacity changes, broadcast new value
	# Request-reply flow
	# - Poll primary and process local/cloud replies
	# - While worker available, route localfe to local or cloud

	# Queue of available workers
	set local_capacity 0
	set cloud_capacity 0
	set workers {}

	proc route_to_cloud_or_local {msg} {
	    global peers
	    # Route reply to cloud if it's addressed to a broker
	    foreach peer $peers {
		if {$peer eq [lindex $msg 0]} {
		    tclzmq zmsg_send cloudfe $msg
		    return
		}
	    }
	    # Route reply to client if we still need to
            tclzmq zmsg_send localfe $msg
	}

	proc handle_localbe {} {
	    global workers
	    # Handle reply from local worker
	    set msg [tclzmq zmsg_recv localbe]
	    set address [tclzmq zmsg_unwrap msg]
	    lappend workers $address
	    # If it's READY, don't route the message any further
	    if {[lindex $msg 0] ne "READY"} {
		route_to_cloud_or_local $msg
	    }
	}

	proc handle_cloudbe {} {
	    # Or handle reply from peer broker
	    set msg [tclzmq zmsg_recv cloudbe]
	    # We don't use peer broker address for anything
	    tclzmq zmsg_unwrap msg
	    route_to_cloud_or_local $msg
	}

	proc handle_statefe {} {
	    global cloud_capacity
	    # Handle capacity updates
	    set cloud_capacity [statefe s_recv]
	}

	proc handle_monitor {} {
	    # Handle monitor message
	    puts [monitor s_recv]
	}

	while {1} {

	    localbe readable handle_localbe
	    cloudbe readable handle_cloudbe
	    statefe readable handle_statefe
	    monitor readable handle_monitor

	    # Now route as many clients requests as we can handle
	    # - If we have local capacity we poll both localfe and cloudfe
	    # - If we have cloud capacity only, we poll just localfe
	    # - Route any request locally if we can, else to cloud
	    #
        while (local_capacity + cloud_capacity) {
            zmq_pollitem_t secondary [] = {
                { localfe, 0, ZMQ_POLLIN, 0 },
                { cloudfe, 0, ZMQ_POLLIN, 0 }
            };
            if (local_capacity)
                rc = zmq_poll (secondary, 2, 0);
            else
                rc = zmq_poll (secondary, 1, 0);
            assert (rc >= 0);

            if (secondary [0].revents & ZMQ_POLLIN)
                msg = zmsg_recv (localfe);
            else
            if (secondary [1].revents & ZMQ_POLLIN)
                msg = zmsg_recv (cloudfe);
            else
                break;      //  No work, go back to primary

            if (local_capacity) {
                zframe_t *frame = (zframe_t *) zlist_pop (workers);
                zmsg_wrap (msg, frame);
                zmsg_send (&msg, localbe);
                local_capacity--;
            }
            else {
                //  Route to random broker peer
                int random_peer = randof (argc - 2) + 2;
                zmsg_pushmem (msg, argv [random_peer], strlen (argv [random_peer]));
                zmsg_send (&msg, cloudbe);
            }
        }
        if (local_capacity != previous) {
            //  We stick our own address onto the envelope
            zstr_sendm (statebe, self);
            //  Broadcast new capacity
            zstr_sendf (statebe, "%d", local_capacity);
        }
    }
    //  When we're done, clean up properly
    while (zlist_size (workers)) {
        zframe_t *frame = (zframe_t *) zlist_pop (workers);
        zframe_destroy (&frame);
    }
    zlist_destroy (&workers);
    zctx_destroy (&ctx);
    return EXIT_SUCCESS;
}
    }
}
