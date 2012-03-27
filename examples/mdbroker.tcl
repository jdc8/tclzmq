#
#  Majordomo Protocol broker
#  A minimal implementation of http://rfc.zeromq.org/spec:7 and spec:8
#

lappend auto_path .
package require MDBroker

set verbose 0
foreach {k v} $argv {
    if {$k eq "-v"} { set verbose 1 }
}

set broker [MDBroker new $verbose]
$broker bind "tcp://*:5555"

#  Get and process messages forever
while {1} {
    set poll_set [list [list [$broker socket] [list POLLIN]]]
    set rpoll_set [zmq poll $poll_set [expr {$::mdp::HEARTBEAT_INTERVAL * 1000}]]

    #  Process next input message, if any
    if {[llength $rpoll_set] && "POLLIN" in [lindex $rpoll_set 0 1]} {
	set msg [zmq zmsg_recv [$broker socket]]
	if {[$broker verbose]} {
	    puts "I: received message:"
	    puts [join [zmq zmsg_dump $msg] \n]
	}
	set sender [zmq zmsg_pop msg]
	set empty [zmq zmsg_pop msg]
	set header [zmq zmsg_pop msg]

	if {$header eq $::mdp::MDPC_CLIENT} {
	    $broker client_process $sender $msg
	} elseif {$header eq $::mdp::MDPW_WORKER} {
	    $broker worker_process $sender $msg
	} else {
	    puts "E: invalid message:"
	    puts [join [zmq zmsg_dump $msg] \n]
	}
    }
    #  Disconnect and delete any expired workers
    #  Send heartbeats to idle workers if needed
    if {[clock milliseconds] > [$broker heartbeat_at]} {
	$broker purge_workers
	$broker heartbeat_workers
    }
}

$broker destroy
