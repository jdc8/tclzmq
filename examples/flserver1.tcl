#
#  Freelance server - Model 1
#  Trivial echo service
#

package require zmq

if {[llength $argv] != 1} {
    puts "Usage: flserver1 <endpoint>"
    exit 1
}

zmq context context 1
zmq socket server context REP
server bind [lindex $argv 0]

puts "I: echo service is ready at [lindex $argv 0]"
while {1} {
    set msg [zmq zmsg_recv server]
    if {[llength $msg] == 0} {
	break
    }
    zmq zmsg_send server $msg
}

server close
context term
