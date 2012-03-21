#
# Demonstrate identities as used by the request-reply pattern.  Run this
# program by itself.
#

package require zmq

zmq context context 1

zmq socket sink context ROUTER
sink bind "inproc://example"

# First allow 0MQ to set the identity
zmq socket anonymous context REQ
anonymous connect "inproc://example"
anonymous s_send "ROUTER uses a generated UUID"
puts "--------------------------------------------------"
puts [join [sink s_dump] \n]

# Then set the identity ourself
zmq socket identified context REQ
identified setsockopt IDENTITY "Hello"
identified connect "inproc://example"
identified s_send "ROUTER socket uses REQ's socket identity"
puts "--------------------------------------------------"
puts [join [sink s_dump] \n]

sink close
anonymous close
identified close
context term

