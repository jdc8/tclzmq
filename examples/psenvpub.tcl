#
# Pubsub envelope publisher
# Note that the zhelpers.h file also provides s_sendmore
#

package require tclzmq

# Prepare our context and publisher
tclzmq::context context 1
tclzmq::socket publisher context PUB
publisher bind "tcp://*:5563"

while {1} {
    # Write two messages, each with an envelope and content
    publisher s_sendmore "A"
    publisher s_send "We don't want to see this"
    publisher s_sendmore "B"
    publisher s_send "We would like to see this"
    after 1000
}

# We never get here but clean up anyhow
publisher close
context term
