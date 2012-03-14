#
# Publisher for durable subscriber
#

package require tclzmq

tclzmq::context context 1

# Subscriber tells us when it's ready here
tclzmq::socket sync context PULL
sync bind "tcp://*:5564"

# We send updates via this socket
tclzmq::socket publisher context PUB
publisher bind "tcp://*:5565"

# Wait for synchronization request
sync s_recv

# Now broadcast exactly 10 updates with pause
for {set update_nbr 0} {$update_nbr < 10} {incr update_nbr} {
    puts $update_nbr
    publisher s_send "Update $update_nbr"
    after 1000
}
publisher s_send "END"

sync close
publisher close
context term
