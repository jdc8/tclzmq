#
# Task worker
# Connects PULL socket to tcp://localhost:5557
# Collects workloads from ventilator via that socket
# Connects PUSH socket to tcp://localhost:5558
# Sends results to sink via that socket
#

package require tclzmq

tclzmq::context context 1

# Socket to receive messages on
tclzmq::socket receiver context PULL
receiver connect "tcp://localhost:5557"

# Socket to send messages to
tclzmq::socket sender context PUSH
sender connect "tcp://localhost:5558"

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
