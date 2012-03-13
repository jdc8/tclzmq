#
# Simple request-reply broker
#

package require tclzmq

# Prepare our context and sockets
tclzmq::context context 1
tclzmq::socket frontend context ROUTER
tclzmq::socket backend context DEALER
frontend bind "tcp://*:5559"
backend bind "tcp://*:5560"

# Initialize poll set
set poll_set [list [list frontend [list POLLIN]] [list backend [list POLLIN]]]

# Switch messages between sockets
while {1} {
    set rpoll_set [tclzmq::poll $poll_set -1]
    foreach rpoll $rpoll_set {
	switch [lindex $rpoll 0] {
	    frontend {
		if {"POLLIN" in [lindex $rpoll 1]} {
		    while {1} {
			# Process all parts of the message
			tclzmq::message message
			frontend recv message
			set more [frontend getsockopt RCVMORE]
			backend send message [expr {$more?"SNDMORE":""}]
			message close
			if {!$more} {
			    break ; # Last message part
			}
		    }
		}
	    }
	    backend {
		if {"POLLIN" in [lindex $rpoll 1]} {
		    while {1} {
			# Process all parts of the message
			tclzmq::message message
			backend recv message
			set more [backend getsockopt RCVMORE]
			frontend send message [expr {$more?"SNDMORE":""}]
			message close
			if {!$more} {
			    break ; # Last message part
			}
		    }
		}
	    }
	}
    }
}

# We never get here but clean up anyhow
frontend close
backend close
context term
