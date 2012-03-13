#
# Hello World client
# Connects REQ socket to tcp://localhost:5559
# Sends "Hello" to server, expects "World" back
#

package require tclzmq

tclzmq::context context 1

# Socket to talk to server
tclzmq::socket requester context REQ
requester connect "tcp://localhost:5559"

for {set request_nbr 0} {$request_nbr < 10} { incr request_nbr} {
    requester s_send "Hello"
    set string [requester s_recv]
    puts "Received reply $request_nbr \[$string\]"
}

requester close
context term
