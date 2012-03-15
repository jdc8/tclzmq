#
# Custom routing Router to Papa (ROUTER to REP)
#

package require tclzmq

# We will do this all in one thread to emphasize the sequence
# of events…

tclzmq::context context 1

tclzmq::socket client context ROUTER
client bind "ipc://routing.ipc"

tclzmq::socket worker context REP
worker setsockopt IDENTITY "A"
worker connect "ipc://routing.ipc"

# Wait for the worker to connect so that when we send a message
# with routing envelope, it will actually match the worker…
after 1000

# Send papa address, address stack, empty part, and request
client s_sendmore "A"
client s_sendmore "address 3"
client s_sendmore "address 2"
client s_sendmore "address 1"
client s_sendmore ""
client s_send     "This is the workload"

# Worker should get just the workload
worker s_dump

# We don't play with envelopes in the worker
worker s_send "This is the reply"

# Now dump what we got off the ROUTER socket…
client s_dump

client close
worker close
context term

