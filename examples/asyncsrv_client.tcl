#
# Asynchronous client-to-server (DEALER to ROUTER)
#
# This is our client task
# It connects to the server, and then sends a request once per second
# It collects responses as they arrive, and it prints them out. We will
# run several client tasks in parallel, each with a different random ID.

package require tclzmq

tclzmq context context 1
tclzmq socket client context DEALER

# Set random identity to make tracing easier
set identity [format "%04X-%04X" [expr {int(rand()*0x10000)}] [expr {int(rand()*0x10000)}]]
client setsockopt IDENTITY $identity
client connect "tcp://localhost:5570"

proc receive {} {
    global identity
    puts "Client $identity received [client s_recv]"
}

proc request {} {
    global request_nbr identity
    incr request_nbr
    puts "Client $identity sent request \#$request_nbr"
    client s_send "request \#$request_nbr"
    after 1000 "request"
}

# Process responses
client readable receive

# Send a request every second
set request_nbr 0
after 1000 request

vwait forever

client close
context term


