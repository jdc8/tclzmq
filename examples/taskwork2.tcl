#
# Task worker - design 2
#  Adds pub-sub flow to receive and respond to kill signal
#

package require tclzmq

tclzmq::context context 1

# Socket to receive messages on
tclzmq::socket receiver context PULL
receiver connect "tcp://localhost:5557"

# Socket to send messages to
tclzmq::socket sender context PUSH
sender connect "tcp://localhost:5558"

# Socket for control inpiy
tclzmq::socket controller context SUB
controller connect "tcp://localhost:5559"
controller setsockopt SUBSCRIBE ""

# Process tasks forever
while {1} {
    set string [receiver s_recv]
    # Simple progress indicator for the viewer
    puts -nonewline "$string."
    flush stdout
    # Do the work
    after $string
    # Send result to sink
    sender s_send "$string"
}

receiver close
sender close
context term
