#
# Reading from multiple sockets
# This version uses a simple recv loop
#

package require tclzmq

# Prepare our context and sockets
tclzmq::context context 1

# Connect to task ventilator
tclzmq::socket receiver context PULL
receiver connect "tcp://localhost:5557"

# Connect to weather server
tclzmq::socket subscriber context SUB
subscriber connect "tcp://*:5556"
subscriber setsockopt SUBSCRIBE "10001"

# Socket to send messages to
tclzmq::socket sender context PUSH
sender connect "tcp://localhost:5558"

while {1} {
    # Process any waiting task
    for {set rc 0} {!$rc} {} {
	tclzmq::message task
	if {[set rc [receiver recv task NOBLOCK]] == 0} {
	    # Do the work
	    set string [task data]
	    puts "Process task: $string"
	    after $string
	    # Send result to sink
	    tclzmq::s_send sender "$string"
	}
	task close
    }
    # Process any waiting weather update
    for {set rc 0} {!$rc} {} {
	tclzmq::message msg
	if {[set rc [subscriber recv msg NOBLOCK]] == 0} {
	    puts "Weather update: [msg data]"
	}
	msg close
    }
    # No activity, sleep for 1 msec
    after 1
}

# We never get here but clean up anyhow
sender close
receiver close
subscriber close
context term
