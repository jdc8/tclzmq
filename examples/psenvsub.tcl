#
# Pubsub envelope subscriber
#

package require tclzmq

# Prepare our context and subscriber
tclzmq::context context 1
tclzmq::socket subscriber context SUB
subscriber connect "tcp://localhost:5563"
subscriber setsockopt SUBSCRIBE "B"

while {1} {
    # Read envelope with address
    set address [subscriber s_recv]
    # Read message contents
    set contents [subscriber s_recv]
    puts "\[$address\] $contents"
}

# We never get here but clean up anyhow
subscriber close
context term
