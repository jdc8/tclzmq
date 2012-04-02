#
#  Freelance server - Model 2
#  Does some work, replies OK, with message sequencing
#

package require zmq

if {[llength $argv] != 1} {
    puts "Usage: flserver3.tcl <endpoint> ?-v?"
    exit 1
}

set connect_endpoint [lindex $argv 0]
set bind_endpoint [regsub {tcp\://[^\:]+} $connect_endpoint "tcp://*"]
set verbose 0

zmq context context 1
zmq socket server context ROUTER
server setsockopt IDENTITY $connect_endpoint
server bind $bind_endpoint
puts "I: service is ready at $bind_endpoint"

while {1} {
    set request [zmq zmsg_recv server]
    if {$verbose} {
	puts "Request:"
	puts [join [zmq zmsg_dump $request] \n]
    }
    if {[llength $request] == 0} {
	break
    }

    set address [zmq zmsg_pop request]
    set control [zmq zmsg_pop request]
    set reply {}
    if {$control eq "PING"} {
	puts "PING"
	set reply [zmq zmsg_add $reply "PONG"]
    } else {
	puts "REQUEST $control"
	set reply [zmq zmsg_add $reply $control]
	set reply [zmq zmsg_add $reply "OK"]
	set reply [zmq zmsg_add $reply "payload"]
    }
    set reply [zmq zmsg_push $reply $address]
    if {$verbose} {
	puts "Reply:"
	puts [join [zmq zmsg_dump $reply] \n]
    }
    zmq zmsg_send server $reply
}

server close
context term
