#
#  Durable subscriber
#

package require tclzmq

tclzmq::context context 1

# Connect our subscriber socket
tclzmq::socket subscriber context SUB
subscriber setsockopt IDENTITY "Hello"
subscriber setsockopt SUBSCRIBE ""
subscriber connect "tcp://localhost:5565"

# Synchronize with publisher
tclzmq::socket sync context PUSH
sync connect "tcp://localhost:5564"
sync s_send ""

# Get updates, exit when told to do so
while {1} {
    set string [subscriber s_recv]
    puts $string
    if {$string eq "END"} {
	break;
    }
}

sync close
subscriber close
context term
