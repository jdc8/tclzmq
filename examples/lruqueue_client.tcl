#
# Least-recently used (LRU) queue device - client
#

# Basic request-reply client using REQ socket
# Since s_send and s_recv can't handle 0MQ binary identities we
# set a printable text identity to allow routing.

package require tclzmq

tclzmq::context context 1

expr {srand([pid])}

tclzmq::socket client context REQ
set id [format "%04X-%04X" [expr {int(rand()*0x10000)}] [expr {int(rand()*0x10000)}]]
client setsockopt IDENTITY $id
client connect "ipc://frontend.ipc"

# Send request, get reply
client s_send "HELLO"
set reply [client s_recv]
puts "Client: $reply"

client close
context term

