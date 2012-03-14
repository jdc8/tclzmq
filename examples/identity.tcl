#
# Demonstrate identities as used by the request-reply pattern.  Run this
# program by itself.  Note that the utility functions s_ are provided by
# zhelpers.h.  It gets boring for everyone to keep repeating this code.
#

package require tclzmq

tclzmq::context context 1

tclzmq::socket sink context ROUTER
sink bind "inproc://example"

# First allow 0MQ to set the identity
tclzmq::socket anonymous context REQ
anonymous connect "inproc://example"
anonymous s_send "ROUTER uses a generated UUID"
sink s_dump

# Then set the identity ourself
tclzmq::socket identified context REQ
identified setsockopt IDENTITY "Hello"
identified connect "inproc://example"
identified s_send "ROUTER socket uses REQ's socket identity"
sink s_dump

sink close
anonymous close
identified close
context term

