#
#  Synchronized publisher
#

package require zmq

zmq context context 1

#  We wait for 10 subscribers
set SUBSCRIBERS_EXPECTED  10

# Socket to talk to clients
zmq socket publisher context PUB
publisher bind "tcp://*:5561"

# Socket to receive signals
zmq socket syncservice context REP
syncservice bind "tcp://*:5562"

# Get synchronization from subscribers
puts "Waiting for subscribers"
set subscribers 0
while {$subscribers < $SUBSCRIBERS_EXPECTED} {
    # - wait for synchronization request
    syncservice s_recv
    # - send synchronization reply
    syncservice s_send ""
    incr subscribers
}

# Now broadcast exactly 1M updates followed by END
puts "Broadcasting messages"
for {set update_nbr 0} {$update_nbr < 1000000} {incr update_nbr} {
    publisher s_send "Rhubarb"
}

publisher s_send "END"

publisher close
syncservice close
context term
